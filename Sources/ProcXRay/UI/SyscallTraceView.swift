import AppKit
import SwiftUI

/// Drives one syscall trace: the helper reads kdebug (or runs ktrace), a background loop reads and pairs its events.
@MainActor @Observable
final class SyscallTracer {
    enum Phase: Equatable { case idle, starting, running, stopping, stopped }
    private(set) var phase: Phase = .idle
    private(set) var records: [SyscallRecord] = []
    /// Kept apart so a filter or sort never has to look past them; they belong at the end of the trace.
    private(set) var pending: [SyscallRecord] = []
    private(set) var notes: [String] = []
    private(set) var events = 0
    /// Oldest records let go to stay under `cap`.
    private(set) var dropped = 0
    /// Bumped on every change to `records` or `context`, so views can key recomputation on one number.
    private(set) var revision = 0
    /// The traced pid and where its Mach messages go (MachPortNames), for the Activity view.
    private(set) var context = SyscallActivity.Context()
    /// Messages went to ports the last port listing didn't have: list again.
    private var unresolvedPorts = false
    /// Destination ports of the trace's messages. Ones a listing has already missed (kernel objects, the
    /// process's own ports) don't ask for another.
    private var seenPorts: Set<UInt32> = []
    private var listedPorts: Set<UInt32> = []
    private var listing: Set<UInt32> = []
    /// Counts traces, so a port listing for an earlier trace is dropped.
    private var generation = 0
    private var stopFlag: Shell.Cancel?
    /// Whether the current trace asked for stacks, and the names for their frames.
    private(set) var withStacks = false
    /// Some call has a caller: every one in a trace with stacks, static initializers (their function) in any.
    private(set) var hasCallers = false
    private(set) var symbols = StackSymbols()

    static let cap = 200_000

    var isActive: Bool { phase == .starting || phase == .running || phase == .stopping }

    /// A process started suspended for the trace: how to let it run once the trace is on, and how to end it if the
    /// trace can't start. A direct spawn signals it; one the helper started as root goes through the helper.
    struct Suspended: Sendable {
        let resume: @Sendable () -> Void
        let kill: @Sendable () -> Void
        /// A process of this user's (a direct spawn, a launchd job).
        static func local(_ pid: Int32) -> Suspended {
            Suspended(resume: { Launcher.resume(pid) }, kill: { _ = Darwin.kill(pid, SIGKILL) })
        }
    }

    /// `resume`: the process was started suspended (Launcher) and runs once the trace is on, or is killed if the
    /// trace can't start, so none of its work goes untraced.
    func start(pid: Int32, start: Date, stacks: Bool, resume: Suspended? = nil) {
        guard !isActive else { return }
        records = []; pending = []; notes = []; events = 0; dropped = 0; revision += 1
        context = SyscallActivity.Context(pid: pid)
        unresolvedPorts = false; seenPorts = []; listedPorts = []; listing = []
        generation += 1
        let gen = generation
        withStacks = stacks
        hasCallers = stacks
        symbols = StackSymbols()
        let symbols = symbols
        phase = .starting
        let flag = Shell.Cancel()
        stopFlag = flag
        // Holds the tracer until the trace ends; the view stops it when it goes away (onDisappear).
        Task.detached(priority: .userInitiated) { [self] in
            await Self.run(pid: pid, start: start, stacks: stacks, resume: resume, symbols: symbols, flag: flag, tracer: self)
        }
        Task.detached(priority: .utility) { [self] in await Self.namePorts(pid: pid, start: start, generation: gen, tracer: self) }
    }

    /// Lists the process's Mach ports when the trace starts, again every 30 s while messages go to ports that
    /// listing lacked (a new connection), and once more when the trace stops if any still do. Each listing is a
    /// helper port walk of every process (~3 s of lsmp with SIP on).
    private nonisolated static func namePorts(pid: Int32, start: Date, generation gen: Int, tracer: SyscallTracer) async {
        var last = Date.distantPast
        var noted = false
        while true {
            guard await tracer.generation == gen else { return }
            let active = await tracer.isActive
            if last != .distantPast {
                guard await tracer.unresolvedPorts else {
                    if !active { return }
                    try? await Task.sleep(for: .seconds(2)); continue
                }
                if active && Date().timeIntervalSince(last) < 30 { try? await Task.sleep(for: .seconds(2)); continue }
            }
            guard Native.isSame(pid, start: start) else { return }
            last = Date()
            await tracer.beginListing(generation: gen)
            switch MachPortNames.resolve(pid: pid) {
            case .success(let r): await tracer.addPorts(r.ports, names: r.names, kinds: r.kinds, generation: gen)
            case .failure(let e):
                if !noted { noted = true; await tracer.note("Message destinations unknown: \(e.message)", generation: gen) }
                return
            }
            if !active { return }
        }
    }

    private func beginListing(generation gen: Int) {
        guard gen == generation else { return }
        listing = seenPorts
        unresolvedPorts = false
    }

    private func addPorts(_ ports: [UInt32: Int32], names: [Int32: String], kinds: [UInt32: String], generation gen: Int) {
        guard gen == generation else { return }
        context.ports.merge(ports) { _, new in new }
        context.processNames.merge(names) { _, new in new }
        context.portKinds.merge(kinds) { _, new in new }
        listedPorts.formUnion(listing)
        revision += 1
    }

    private func note(_ text: String, generation gen: Int) {
        guard gen == generation, !notes.contains(text) else { return }
        notes.append(text)
    }

    func stop() {
        guard phase == .starting || phase == .running else { return }
        phase = .stopping
        stopFlag?.cancel()
    }

    func clear() {
        guard !isActive else { return }
        records = []; pending = []; notes = []; events = 0; dropped = 0; revision += 1
        phase = .idle
    }

    private nonisolated static func run(pid: Int32, start: Date, stacks: Bool, resume: Suspended?, symbols: StackSymbols,
                                        flag: Shell.Cancel, tracer: SyscallTracer) async {
        let s = HelperTraceSession()
        defer { s.close() }
        let format: SyscallTraceConfig.Format
        switch s.start(pid: pid, stacks: stacks) {
        case .success(let f): format = f
        case .failure(let e):
            if let resume, Native.isSame(pid, start: start) { resume.kill() }
            await tracer.finish([], note: e.message + (resume != nil ? " The launched process was ended before it ran." : ""))
            return
        }
        resume?.resume()
        await tracer.setPhase(.running)
        // A launched process is traced from its first instruction: its lowest thread id is its main thread.
        var mainThread: UInt64?
        var dec = SyscallDecoder(stacks: stacks && format == .kdebug)
        var fds = FdLabeler()
        var threads = ThreadLabeler()
        var stopSent = false
        var endNote: String?
        let deadlineAfterStop: TimeInterval = 6
        var stopTime: Date?
        while true {
            if !stopSent {
                var why: String?
                if flag.isCancelled { why = "" }
                else if !Native.isSame(pid, start: start) { why = "The process exited." }
                if let why {
                    s.stop()
                    stopSent = true
                    stopTime = Date()
                    if !why.isEmpty { endNote = why }
                }
            }
            guard let (data, running, notes, regions) = s.read() else {
                endNote = "Lost the connection to the helper."
                break
            }
            let (evs, bad) = format == .kdebug ? (KdebugEvent.decodeRaw(data), 0) : KdebugEvent.decode(data)
            symbols.add(regions)
            var recs = dec.feed(evs)
            symbols.addLoadedImages(recs)
            if resume != nil, let low = recs.lazy.map(\.thread).min() { mainThread = min(mainThread ?? low, low) }
            fds.label(&recs) { s.describeFds($0) }
            let names = threads.label(&recs) { s.threads($0) }
            for i in recs.indices where !recs[i].stack.isEmpty { recs[i].caller = symbols.caller(recs[i].stack) }
            var n = notes.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            if bad > 0 { n.append("\(bad) unreadable trace lines skipped.") }
            if !recs.isEmpty || !n.isEmpty || !evs.isEmpty {
                await tracer.append(recs, events: evs.count, notes: n, names: names,
                                    threads: Self.threadNames(threads.threadNames, dec.threadNames, main: mainThread))
            }
            if !running { break }
            if let t = stopTime, Date().timeIntervalSince(t) > deadlineAfterStop { endNote = endNote ?? "The trace did not stop in time."; break }
            // A full read means more is waiting: read again right away.
            if data.count < SyscallTraceConfig.maxRead / 2 { try? await Task.sleep(for: .milliseconds(250)) }
        }
        var last = dec.flush()
        fds.label(&last) { s.describeFds($0) }
        let names = threads.label(&last) { s.threads($0) }
        for i in last.indices where !last[i].stack.isEmpty { last[i].caller = symbols.caller(last[i].stack) }
        if !last.isEmpty {
            await tracer.append(last, events: 0, notes: [], names: names,
                                threads: Self.threadNames(threads.threadNames, dec.threadNames, main: mainThread))
        }
        await tracer.finish(dec.pending(), note: endNote)
    }

    private func setPhase(_ p: Phase) { if phase == .starting { phase = p } }

    /// The helper's names (with "main thread") under the trace's own: a name set during the trace is newer.
    /// `main`: the main thread when the trace itself knows it (a launched process: its first thread), for a process
    /// that exited before the helper could be asked.
    nonisolated static func threadNames(_ looked: [UInt64: String], _ traced: [UInt64: String], main: UInt64? = nil) -> [UInt64: String] {
        var out = looked
        for (t, n) in traced {
            out[t] = looked[t].map { $0.hasPrefix("main thread") ? "main thread, " + n : n } ?? n
        }
        if let main, !(out[main]?.hasPrefix("main thread") ?? false) {
            out[main] = "main thread" + (out[main].map { ", " + $0 } ?? "")
        }
        return out
    }

    private func append(_ recs: [SyscallRecord], events n: Int, notes n2: [String], names: [Int32: String] = [:],
                        threads: [UInt64: String] = [:]) {
        if context.threadNames != threads, !threads.isEmpty { context.threadNames = threads; revision += 1 }
        events += n
        for note in n2 where !notes.contains(note) {
            notes.append(note)
            // Seen live: "ktrace: cannot access trace system: in use by ktrace[61040]", then exit status 77.
            if note.contains("cannot access trace system") {
                notes.append("The kernel allows one trace at a time: stop the other one (another trace here, Instruments or fs_usage) and trace again.")
            }
        }
        guard !recs.isEmpty else { return }
        context.processNames.merge(names) { old, _ in old }
        for r in recs where r.name == "mach_msg2_trap" {
            // Replies go over send-once rights the send uses up: no listing finds them. Nor is one needed for a send
            // that woke its receiver or that the kernel answered.
            guard let a = r.args, let (port, once) = SyscallActivity.Context.messagePort(a), port != 0,
                  context.unnamed(port, sendOnce: once, call: r), seenPorts.insert(port).inserted else { continue }
            if !listedPorts.contains(port) { unresolvedPorts = true }
        }
        if !hasCallers, recs.contains(where: { !$0.caller.isEmpty }) { hasCallers = true }
        records.append(contentsOf: recs)
        if records.count > Self.cap {
            // Drop in slabs of 10%, not one by one: removeFirst is O(n).
            let cut = records.count - Self.cap + Self.cap / 10
            records.removeFirst(cut)
            dropped += cut
        }
        revision += 1
    }

    private func finish(_ inFlight: [SyscallRecord], note: String?) {
        pending = inFlight
        if let note, !notes.contains(note) { notes.append(note) }
        phase = .stopped
        revision += 1
    }
}

/// The process a trace view traces.
struct TraceTarget: Hashable, Sendable {
    let pid: Int32
    let start: Date
    let name: String
}

struct SyscallTraceView: View {
    @Environment(Store.self) var store
    let target: TraceTarget
    let exited: Bool
    @State private var tracer: SyscallTracer

    init(proc: ProcInfo, exited: Bool) {
        self.init(target: TraceTarget(pid: proc.pid, start: proc.start, name: proc.name), exited: exited)
    }

    /// `tracer`: one the caller already started (the Launch window), else a new idle one.
    init(target: TraceTarget, exited: Bool, tracer: SyscallTracer? = nil) {
        self.target = target
        self.exited = exited
        _tracer = State(initialValue: tracer ?? SyscallTracer())
    }
    @AppStorage("syscallTrace.mode") private var mode = "Activity"
    @AppStorage("syscallTrace.stacks") private var stacks = false
    @AppStorage("syscallTrace.argNames") private var argNames = true
    @State private var filter = ""
    @State private var errorsOnly = false
    /// The one thread every view follows, nil for all of them.
    @State private var thread: UInt64?
    /// Each thread's calls in the whole trace, by thread id: the Thread menu's choices.
    @State private var threadCounts: [(tid: UInt64, calls: Int)] = []
    @State private var sort = [KeyPathComparator(\SyscallRecord.time, order: .reverse)]
    @State private var shown: [SyscallRecord] = []
    @State private var activities: [SyscallActivity] = []
    @State private var lanes = SyscallLanes()
    @State private var laneSelected: SyscallRecord?
    @State private var summary: [SyscallSummaryRow] = []
    @State private var summarySort = [KeyPathComparator(\SyscallSummaryRow.totalNanos, order: .reverse)]
    @State private var selection: Set<SyscallRecord.ID> = []
    @State private var summarySelection: Set<SyscallSummaryRow.ID> = []
    @State private var activitySelection: Set<ActivityRowID> = []

    private var showCaller: Bool { tracer.withStacks || tracer.hasCallers }

    private var disabledReason: String? {
        if exited { return InspectorView.exitedNote }
        if !store.helperState.isRunning { return "Tracing syscalls needs root: install the helper (Settings ▸ Helper)." }
        return nil
    }

    private var key: String {
        "\(tracer.phase)\u{0}\(filter)\u{0}\(errorsOnly)\u{0}\(thread.map(String.init) ?? "")\u{0}\(mode)\u{0}\(sort.first.map { "\($0.keyPath)\($0.order == .forward)" } ?? "")"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !tracer.notes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(tracer.notes, id: \.self) { Text($0) }
                }
                .font(.caption).foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.bottom, 4)
            }
            Divider()
            if tracer.phase == .idle {
                placeholder
            } else if mode == "Activity" {
                SyscallActivityView(groups: activities, threadNames: tracer.context.threadNames,
                                    filtered: !filter.isEmpty || errorsOnly || thread != nil, selection: $activitySelection,
                                    followed: thread, follow: { thread = $0 })
                if let r = selectedActivityStackRecord { Divider(); stackPane(r) }
            } else if mode == "Summary" {
                summaryTable
            } else if mode == "Lanes" {
                SyscallLanesPane(lanes: lanes, context: tracer.context, followed: thread, follow: { thread = $0 },
                                 selected: $laneSelected)
                if let r = laneSelected, !r.stack.isEmpty { Divider(); stackPane(r) }
            } else {
                callsTable
                if let r = selectedStackRecord { Divider(); stackPane(r) }
            }
        }
        // Filled and pinned to the top: an empty Activity view (as the trace starts) doesn't fill the height,
        // and the pane would otherwise sit centered until the first calls arrive.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: key) {
            var lastRevision = -1
            repeat {
                if lastRevision != tracer.revision {
                    lastRevision = tracer.revision
                    await recompute()
                }
                guard tracer.isActive else { break }
                try? await Task.sleep(for: .milliseconds(300))
            } while !Task.isCancelled
        }
        .onDisappear { tracer.stop() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            // The controls left of the status keep their width as the trace starts and stops, so nothing after
            // them shifts: the button sits in a slot sized to its widest label, Stacks stays (disabled while
            // tracing, as it applies at the start), and the spinner's place is kept when it's not shown.
            ZStack(alignment: .leading) {
                Button {} label: { Label("Trace again", systemImage: "record.circle") }
                    .hidden().accessibilityHidden(true)
                if tracer.isActive {
                    Button { tracer.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .disabled(tracer.phase == .stopping)
                } else {
                    Button { tracer.start(pid: target.pid, start: target.start, stacks: stacks) } label: {
                        Label(tracer.phase == .idle ? "Trace" : "Trace again", systemImage: "record.circle")
                    }
                    .disabled(disabledReason != nil)
                    .help(disabledReason ?? "Trace this process's BSD syscalls and Mach traps (kdebug, as root via the helper)")
                }
            }
            .fixedSize()   // in a narrow window only the status gives way, not these
            Toggle("Stacks", isOn: $stacks).toggleStyle(.checkbox).font(.caption).fixedSize()
                .disabled(tracer.isActive)
                .help("Record the user stack of every call (kperf), to see which code made it. The traced process runs up to a third slower.")
            ProgressView().controlSize(.small)
                .opacity(tracer.phase == .starting || tracer.phase == .stopping ? 1 : 0)
            // First to give way when the window is narrow, so no control wraps and the header keeps its height.
            Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationHelp(status)
                .layoutPriority(-1)
            Spacer()
            Picker("", selection: $mode) {
                Text("Activity").tag("Activity")
                Text("Calls").tag("Calls")
                Text("Lanes").tag("Lanes").help("Each thread's calls side by side on one time line")
                Text("Summary").tag("Summary")
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
            if mode == "Calls" {
                Toggle("Names", isOn: $argNames).toggleStyle(.checkbox).font(.caption).fixedSize()
                .help("Show argument names (as xnu declares them) with the values")
            }
            threadMenu
            Toggle("Errors only", isOn: $errorsOnly).toggleStyle(.checkbox).font(.caption).fixedSize()
            TextField("filter", text: $filter).textFieldStyle(.roundedBorder).frame(minWidth: 60, maxWidth: 160)
                .layoutPriority(-2)   // narrows before the status disappears
            Menu {
                Button("Copy All") { Pasteboard.copy(exportText()) }
                Button("Save as Text…") { save() }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .disabled(tracer.phase == .idle)
            .help("Copy or save the \(mode) view as text, everything the filter shows")
            Button { tracer.clear(); thread = nil; laneSelected = nil; selection = []; summarySelection = []; activitySelection = [] } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Clear")
            .help("Clear the trace")
            .disabled(tracer.isActive || tracer.phase == .idle)
        }
        .padding(6)
    }

    /// All threads, or one: every view (Activity, Calls, Summary) then shows only that thread's calls, in order.
    /// The button says only which (names can be long and the header is full); the items name each thread.
    private var threadMenu: some View {
        Menu {
            Picker("", selection: $thread) {
                Text("All threads").tag(UInt64?.none)
                Divider()
                ForEach(threadChoices, id: \.tid) { c in
                    Text(threadChoiceTitle(c.tid, c.calls)).tag(Optional(c.tid))
                }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            Text(threadMenuTitle)
        }
        .menuStyle(.borderlessButton).font(.caption).fixedSize()
        .disabled(tracer.phase == .idle)
        .help("Follow one thread: every view shows only its calls")
    }

    private func threadChoiceTitle(_ tid: UInt64, _ calls: Int) -> String {
        let n: String = calls.formatted()
        return Self.thread(tid, tracer.context.threadNames) + " · " + n + (calls == 1 ? " call" : " calls")
    }

    private var threadMenuTitle: String {
        guard let thread else { return "All threads" }
        let main = tracer.context.threadNames[thread]?.hasPrefix("main thread") ?? false
        return main ? "Main thread" : "Thread " + String(thread)
    }

    /// The trace's threads, and the followed one even when this trace has no calls on it (a trace run again).
    private var threadChoices: [(tid: UInt64, calls: Int)] {
        guard let thread, !threadCounts.contains(where: { $0.tid == thread }) else { return threadCounts }
        return (threadCounts + [(thread, 0)]).sorted { $0.tid < $1.tid }
    }

    nonisolated static func callsByThread(_ records: [SyscallRecord]) -> [(tid: UInt64, calls: Int)] {
        var n: [UInt64: Int] = [:]
        for r in records { n[r.thread, default: 0] += 1 }
        return n.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    private var status: String {
        let n = tracer.records.count + tracer.pending.count
        let calls = "\(n.formatted()) call\(n == 1 ? "" : "s")"
        let dropped = tracer.dropped > 0 ? " · oldest \(tracer.dropped.formatted()) let go" : ""
        let showing = shown.count != tracer.records.count + tracer.pending.count && (mode == "Calls" || mode == "Lanes") ? " · \(shown.count.formatted()) shown" : ""
        switch tracer.phase {
        case .idle: return "kdebug \(SyscallTraceConfig.filter) for pid \(target.pid)"
        case .starting: return "Starting the trace…"
        case .running: return "Tracing · \(calls)\(showing)\(dropped)"
        case .stopping: return "Stopping · \(calls)"
        case .stopped: return "Stopped · \(calls)\(showing)\(dropped)"
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg").font(.largeTitle).foregroundStyle(.tertiary)
            Text(placeholderText)
                .multilineTextAlignment(.center)
            Text(disabledReason ?? "Uses the kernel's kdebug trace (as Instruments' System Call Trace does). One trace at a time per machine: it can't run while Instruments or fs_usage is recording.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            EmptyRunButton(title: "Trace", systemImage: "record.circle", disabledReason: disabledReason,
                           help: "Trace this process's BSD syscalls and Mach traps (kdebug, as root via the helper)") {
                tracer.start(pid: target.pid, start: target.start, stacks: stacks)
            }
            .padding(.top, 6)
        }
        .padding(30).frame(maxWidth: 520).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholderText: String {
        switch mode {
        case "Activity": "Follow what the process does with files, connections and Mach messages, and where it waits. Expand an activity to inspect its syscalls."
        case "Lanes": "Each thread's calls side by side on one time line: when each thread works, when it waits, and what it calls."
        default: "Every syscall and Mach trap this process makes, with arguments, results, errors, durations and file paths."
        }
    }

    private var callsTable: some View {
        Table(shown, selection: $selection, sortOrder: $sort) {
            TableColumn("Time", value: \.time) { r in
                Text(r.start.map(Self.seconds) ?? "before").monospacedDigit()
            }
            .width(min: 70, ideal: 84, max: 110)
            TableColumn("Thread", value: \.thread) { r in
                let t = Self.thread(r.thread, tracer.context.threadNames)
                Text(t).monospacedDigit().foregroundStyle(.secondary).truncationHelp(t)
            }
                .width(min: 50, ideal: 110, max: 260)
            TableColumn("Syscall", value: \.name) { r in
                HStack(spacing: 4) {
                    // Purple: Mach traps; teal: dyld's library calls, from its trace events rather than the kernel.
                    Text(r.name).foregroundStyle(r.mach ? Color.purple : r.isLibraryCall ? Color.teal : Color.primary)
                        .truncationHelp(r.isLibraryCall ? r.name + " (a dyld call, from dyld's trace events)" : r.name)
                    Spacer(minLength: 0)
                    ManPageButton(name: r.name)
                }
            }
            .width(min: 90, ideal: 150)
            TableColumn("Arguments") { r in
                let t = argNames ? r.namedArgsText : r.argsText
                Text(t).foregroundStyle(.secondary).truncationHelp(t)
            }
                .width(min: 100, ideal: 240)
            TableColumn("Result") { r in
                let t = Self.result(r, tracer.context)
                Text(t)
                    .foregroundStyle(r.failed ? Color.red : (r.state == .inProgress ? Color.orange : Color.primary))
                    .truncationHelp(t)
            }
            .width(min: 60, ideal: 200)
            TableColumn("Duration", value: \.durationKey) { r in
                Text(r.duration.map(Self.duration) ?? "—").monospacedDigit()
            }
            .width(min: 60, ideal: 76, max: 110)
            TableColumn("Caller") { r in Text(r.caller).foregroundStyle(.secondary).truncationHelp(r.caller) }
                .width(min: showCaller ? 80 : 0, ideal: showCaller ? 220 : 0, max: showCaller ? .infinity : 0)
            TableColumn("Path") { r in
                HStack(spacing: 4) {
                    Text(r.pathText).truncationHelp(r.pathText)
                    // The first existing one: a rename's source is usually gone, its destination isn't.
                    if let path = r.paths.lazy.compactMap(Reveal.path(in:)).first { Spacer(minLength: 0); RevealButton(path: path) }
                }
            }
                .width(min: 80, ideal: 260)
        }
        .font(.system(size: 11, design: .monospaced))
        .contextMenu(forSelectionType: SyscallRecord.ID.self) { ids in
            Button("Copy") { copy(ids) }
            let rows = shown.filter { ids.contains($0.id) }
            let pages = Set(rows.compactMap { ManPage.page(for: $0.name) })
            if pages.count == 1, let page = pages.first {
                Button("\(page.title) Man Page") { ManPage.open(page) }
            }
            let tids = Set(rows.map(\.thread))
            if thread != nil {
                Button("Show All Threads") { thread = nil }
            } else if tids.count == 1, let t = tids.first {
                Button("Follow Thread " + Self.thread(t, tracer.context.threadNames)) { thread = t }
            }
        }
        .onCopyCommand { [ids = selection] in
            [NSItemProvider(object: text(for: ids) as NSString)]
        }
    }

    private var summaryTable: some View {
        Table(summary, selection: $summarySelection, sortOrder: $summarySort) {
            TableColumn("Syscall", value: \.name) { s in
                HStack(spacing: 4) {
                    Text(s.name).truncationHelp(s.name)
                    Spacer(minLength: 0)
                    ManPageButton(name: s.name)
                }
            }
            .width(min: 120, ideal: 200)
            TableColumn("Calls", value: \.calls) { s in Text(s.calls.formatted()).monospacedDigit() }.width(min: 50, ideal: 70)
            TableColumn("Errors", value: \.errors) { s in
                Text(s.errors == 0 ? "" : s.errors.formatted()).monospacedDigit().foregroundStyle(.red)
            }
            .width(min: 50, ideal: 60)
            TableColumn("Total time", value: \.totalNanos) { s in Text(Self.duration(s.totalNanos)).monospacedDigit() }.width(min: 70, ideal: 90)
            TableColumn("Average", value: \.avgNanos) { s in Text(Self.duration(s.avgNanos)).monospacedDigit() }.width(min: 70, ideal: 90)
            TableColumn("Longest", value: \.maxNanos) { s in Text(Self.duration(s.maxNanos)).monospacedDigit() }.width(min: 70, ideal: 90)
        }
        .font(.system(size: 11, design: .monospaced))
        .contextMenu(forSelectionType: SyscallSummaryRow.ID.self) { ids in
            Button("Copy") { Pasteboard.copy(summaryText(ids)) }
            if ids.count == 1, let name = ids.first, let page = ManPage.page(for: name) {
                Button("\(page.title) Man Page") { ManPage.open(page) }
            }
        }
        .onCopyCommand { [ids = summarySelection] in
            [NSItemProvider(object: summaryText(ids) as NSString)]
        }
        .onChange(of: summarySort) { summary.sort(using: summarySort) }
    }

    /// Filter and sort off the main thread; while tracing, at most ~3 times a second.
    private func recompute() async {
        guard !Task.isCancelled else { return }
        let all = tracer.records + tracer.pending
        let filter = filter, errorsOnly = errorsOnly, thread = thread, context = tracer.context, sort = sort, summaryMode = mode == "Summary", summarySort = summarySort
        let lanesMode = mode == "Lanes"
        if mode == "Activity" {
            let (groups, counts) = await Task.detached(priority: .userInitiated) {
                (SyscallActivity.build(all, filter: filter, errorsOnly: errorsOnly, thread: thread, context: context), Self.callsByThread(all))
            }.value
            if !Task.isCancelled { activities = groups; threadCounts = counts }
            return
        }
        let result = await Task.detached(priority: .userInitiated) { () -> Recomputed in
            var out = Recomputed()
            out.counts = Self.callsByThread(all)
            let rows = all.filter { r in
                (thread == nil || r.thread == thread) && (!errorsOnly || r.failed) &&
                (filter.isEmpty || r.name.localizedCaseInsensitiveContains(filter) || r.pathText.localizedCaseInsensitiveContains(filter)
                 || Self.result(r, context).localizedCaseInsensitiveContains(filter) || r.argsText.localizedCaseInsensitiveContains(filter)
                 || r.caller.localizedCaseInsensitiveContains(filter)
                 || (context.threadNames[r.thread]?.localizedCaseInsensitiveContains(filter) ?? false))
            }
            if summaryMode {
                out.summary = SyscallSummaryRow.build(rows).sorted(using: summarySort)
            } else if lanesMode {
                out.lanes = SyscallLanes.build(rows, threadNames: context.threadNames)
                out.shown = rows
            } else {
                out.shown = rows.sorted(using: sort)
            }
            return out
        }.value
        guard !Task.isCancelled else { return }
        threadCounts = result.counts
        if summaryMode { summary = result.summary } else { shown = result.shown }
        if let l = result.lanes { lanes = l }
    }

    private struct Recomputed: Sendable {
        var shown: [SyscallRecord] = []
        var summary: [SyscallSummaryRow] = []
        var counts: [(tid: UInt64, calls: Int)] = []
        var lanes: SyscallLanes?
    }

    /// The one selected call, when it has a stack.
    /// One call selected in Activity (a row under an activity or a thread), with a stack: shown under the outline
    /// as in Calls.
    private var selectedActivityStackRecord: SyscallRecord? {
        guard activitySelection.count == 1, case .call(let gid, _, let id) = activitySelection.first,
              let g = activities.first(where: { $0.id == gid }), let r = g.calls.first(where: { $0.id == id }),
              !r.stack.isEmpty else { return nil }
        return r
    }

    private var selectedStackRecord: SyscallRecord? {
        guard selection.count == 1, let id = selection.first, let r = shown.first(where: { $0.id == id }), !r.stack.isEmpty else { return nil }
        return r
    }

    private func stackPane(_ r: SyscallRecord) -> some View {
        let frames = tracer.symbols.frames(r.stack)
        return ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(frames.enumerated()), id: \.offset) { i, f in
                    HStack(spacing: 8) {
                        Text("\(i)").foregroundStyle(.tertiary).frame(width: 22, alignment: .trailing)
                        Text(f.symbol ?? (f.image.isEmpty ? "???" : "\(f.image) + 0x\(String(f.offset, radix: 16))"))
                            .foregroundStyle(f.image == "libsystem_kernel.dylib" ? .secondary : .primary)
                        // String(): Text's own interpolation would localize the number ("6,652").
                        if f.symbol != nil { Text("+ " + String(f.offset)).foregroundStyle(.secondary) }
                        if !f.image.isEmpty && f.symbol != nil { Text("(\(f.image))").foregroundStyle(.secondary) }
                        Spacer(minLength: 0)
                        Text("0x" + String(f.address, radix: 16)).foregroundStyle(.tertiary)
                    }
                    .lineLimit(1)
                }
            }
            .padding(6)
            .textSelection(.enabled)
        }
        .font(.system(size: 11, design: .monospaced))
        .frame(height: min(CGFloat(frames.count) * 16 + 14, 200))
    }

    private func copy(_ ids: Set<SyscallRecord.ID>) { Pasteboard.copy(text(for: ids)) }

    private func text(for ids: Set<SyscallRecord.ID>?) -> String {
        shown.filter { ids?.contains($0.id) ?? true }.map { r in
            Self.line(r, argNames: argNames, context: tracer.context) + tracer.symbols.frames(r.stack).map { "\n    " + $0.text }.joined()
        }.joined(separator: "\n")
    }

    /// strace-style: `+1.234567 [tid] name(args) = result <duration> path`, and the caller when stacks were on.
    nonisolated static func line(_ r: SyscallRecord, argNames: Bool = true, context: SyscallActivity.Context? = nil) -> String {
        let t = r.start.map(seconds) ?? "before"
        let d = r.duration.map { " <\(duration($0))>" } ?? ""
        let p = r.paths.isEmpty ? "" : "  \(r.pathText)"
        let c = r.caller.isEmpty ? "" : "  ← \(r.caller)"
        let th = context.map { thread(r.thread, $0.threadNames) } ?? String(r.thread)
        let res = context.map { result(r, $0) } ?? r.resultText
        return "\(t) [\(th)] \(r.name)(\(argNames ? r.namedArgsText : r.argsText)) = \(res)\(d)\(p)\(c)"
    }

    /// "92032 com.apple.NSEventThread", or the id alone for an unnamed thread.
    nonisolated static func thread(_ tid: UInt64, _ names: [UInt64: String]) -> String {
        names[tid].map { String(tid) + " " + $0 } ?? String(tid)
    }

    /// The result, with where a Mach message went: "KERN_SUCCESS → task_info (kernel)", "… → cfprefsd (164)".
    nonisolated static func result(_ r: SyscallRecord, _ context: SyscallActivity.Context) -> String {
        context.messageTarget(r).map { r.resultText + "  → " + $0 } ?? r.resultText
    }

    /// Tab-separated with a header row, in the table's order.
    private func summaryText(_ ids: Set<SyscallSummaryRow.ID>?) -> String {
        let rows = summary.filter { ids?.contains($0.id) ?? true }.map { s in
            [s.name, String(s.calls), String(s.errors), Self.duration(s.totalNanos), Self.duration(s.avgNanos), Self.duration(s.maxNanos)]
                .joined(separator: "\t")
        }
        return (["Syscall\tCalls\tErrors\tTotal time\tAverage\tLongest"] + rows).joined(separator: "\n")
    }

    /// Everything the current mode shows (after the filter).
    private func exportText() -> String {
        switch mode {
        case "Activity": SyscallActivityView.text(activities, names: tracer.context.threadNames)
        case "Summary": summaryText(nil)
        case "Lanes": lanes.text(context: tracer.context)
        default: text(for: nil)
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [mode == "Summary" ? .tabSeparatedText : .plainText]
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        panel.nameFieldStringValue = "\(target.name) \(mode) \(f.string(from: Date())).\(mode == "Summary" ? "tsv" : "txt")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? exportText().write(to: url, atomically: true, encoding: .utf8)
    }

    nonisolated static func seconds(_ ns: UInt64) -> String { String(format: "+%.6f", Double(ns) / 1e9) }
    nonisolated static func duration(_ ns: UInt64) -> String {
        switch ns {
        case ..<1_000: return "\(ns) ns"
        case ..<1_000_000: return String(format: "%.1f µs", Double(ns) / 1e3)
        case ..<1_000_000_000: return String(format: "%.2f ms", Double(ns) / 1e6)
        default: return String(format: "%.2f s", Double(ns) / 1e9)
        }
    }
}
