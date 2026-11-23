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
    /// The Calls table's order; the rows are sorted by it off the main thread (recompute).
    @State private var sort = DataSort(column: "time", ascending: false)
    @State private var shown: [SyscallRecord] = []
    @State private var activities: [SyscallActivity] = []
    @State private var summary: [SyscallSummaryRow] = []
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
        "\(tracer.phase)\u{0}\(filter)\u{0}\(errorsOnly)\u{0}\(mode)\u{0}\(sort.column)\(sort.ascending)"
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
                                    filtered: !filter.isEmpty || errorsOnly, selection: $activitySelection)
                if let r = selectedActivityStackRecord { Divider(); stackPane(r) }
            } else if mode == "Summary" {
                summaryTable
            } else {
                callsTable
                if let r = selectedStackRecord { Divider(); stackPane(r) }
            }
        }
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
            if tracer.isActive {
                Button { tracer.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .disabled(tracer.phase == .stopping)
            } else {
                Button { tracer.start(pid: target.pid, start: target.start, stacks: stacks) } label: {
                    Label(tracer.phase == .idle ? "Trace" : "Trace again", systemImage: "record.circle")
                }
                .disabled(disabledReason != nil)
                .help(disabledReason ?? "Trace this process's BSD syscalls and Mach traps (kdebug, as root via the helper)")
                Toggle("Stacks", isOn: $stacks).toggleStyle(.checkbox).font(.caption)
                    .help("Record the user stack of every call (kperf), to see which code made it. The traced process runs up to a third slower.")
            }
            if tracer.phase == .starting || tracer.phase == .stopping { ProgressView().controlSize(.small) }
            Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationHelp(status)
            Spacer()
            Picker("", selection: $mode) {
                Text("Activity").tag("Activity")
                Text("Calls").tag("Calls")
                Text("Summary").tag("Summary")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if mode == "Calls" {
                Toggle("Names", isOn: $argNames).toggleStyle(.checkbox).font(.caption)
                .help("Show argument names (as xnu declares them) with the values")
            }
            Toggle("Errors only", isOn: $errorsOnly).toggleStyle(.checkbox).font(.caption)
            TextField("filter", text: $filter).textFieldStyle(.roundedBorder).frame(width: 160)
            Menu {
                Button("Copy All") { Pasteboard.copy(exportText()) }
                Button("Save as Text…") { save() }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .disabled(tracer.phase == .idle)
            .help("Copy or save the \(mode) view as text, everything the filter shows")
            Button("Clear") { tracer.clear(); selection = []; summarySelection = []; activitySelection = [] }
                .disabled(tracer.isActive || tracer.phase == .idle)
        }
        .padding(6)
    }

    private var status: String {
        let n = tracer.records.count + tracer.pending.count
        let calls = "\(n.formatted()) call\(n == 1 ? "" : "s")"
        let dropped = tracer.dropped > 0 ? " · oldest \(tracer.dropped.formatted()) let go" : ""
        let showing = shown.count != tracer.records.count + tracer.pending.count && mode == "Calls" ? " · \(shown.count.formatted()) shown" : ""
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
            Text(mode == "Activity" ? "Follow what the process does with files, connections and Mach messages, and where it waits. Expand an activity to inspect its syscalls." : "Every syscall and Mach trap this process makes, with arguments, results, errors, durations and file paths.")
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

    /// The man page's entry and Reveal in Finder, which were buttons in the cells, are in the row's menu.
    private var callsTable: some View {
        let context = tracer.context, argNames = argNames, symbols = tracer.symbols
        return DataTable(rows: shown, columns: Self.callsColumns(context: context, argNames: argNames), initialSort: ("time", false),
                         autosave: "syscallCalls", live: true, sort: $sort, hiddenColumns: showCaller ? [] : ["caller"],
                         copyText: { rows in
                             rows.map { r in Self.line(r, argNames: argNames, context: context) + symbols.frames(r.stack).map { "\n    " + $0.text }.joined() }
                                 .joined(separator: "\n")
                         },
                         selection: $selection,
                         menu: { rows in
                             var items: [DataMenuItem] = []
                             let pages = Set(rows.compactMap { ManPage.page(for: $0.name) })
                             if pages.count == 1, let page = pages.first {
                                 items.append(DataMenuItem(title: "\(page.title) Man Page") { ManPage.open(page) })
                             }
                             // The first existing one: a rename's source is usually gone, its destination isn't.
                             if rows.count == 1, let path = rows[0].paths.lazy.compactMap(Reveal.path(in:)).first {
                                 items.append(DataMenuItem(title: "Reveal in Finder") { Reveal.reveal([path]) })
                             }
                             return items
                         },
                         exportName: "\(target.name) syscalls")
    }

    /// The Calls table's columns; `less` is also what recompute sorts by, off the main thread.
    nonisolated static func callsColumns(context: SyscallActivity.Context, argNames: Bool) -> [DataColumn<SyscallRecord>] {
        let names = context.threadNames
        func col(_ id: String, _ title: String, _ width: CGFloat, color: ((SyscallRecord) -> NSColor?)? = nil,
                 tooltip: ((SyscallRecord) -> String?)? = nil, _ text: @escaping (SyscallRecord) -> String) -> DataColumn<SyscallRecord> {
            DataColumn(id: id, title: title, width: width, mono: true, text: text, color: color, tooltip: tooltip,
                       less: { text($0).localizedStandardCompare(text($1)) == .orderedAscending })
        }
        let secondary: (SyscallRecord) -> NSColor? = { _ in .secondaryLabelColor }
        var time = col("time", "Time", 84) { $0.start.map(Self.seconds) ?? "before" }
        time.less = { $0.time < $1.time }
        var thread = col("thread", "Thread", 110, color: secondary) { Self.thread($0.thread, names) }
        thread.less = { $0.thread < $1.thread }
        var duration = col("duration", "Duration", 76) { $0.duration.map(Self.duration) ?? "—" }
        duration.less = { $0.durationKey < $1.durationKey }
        return [
            time,
            thread,
            // Purple: Mach traps; teal: dyld's library calls, from its trace events rather than the kernel.
            col("name", "Syscall", 150, color: { $0.mach ? .systemPurple : $0.isLibraryCall ? .systemTeal : nil },
                tooltip: { $0.isLibraryCall ? $0.name + " (a dyld call, from dyld's trace events)" : nil }) { $0.name },
            col("args", "Arguments", 240, color: secondary) { argNames ? $0.namedArgsText : $0.argsText },
            col("result", "Result", 200, color: { $0.failed ? .systemRed : $0.state == .inProgress ? .systemOrange : nil }) { Self.result($0, context) },
            duration,
            col("caller", "Caller", 220, color: secondary) { $0.caller },
            col("path", "Path", 260) { $0.pathText },
        ]
    }

    /// `rows` in the order the Calls table asked for; equal rows keep their order (the trace's).
    nonisolated static func ordered(_ rows: [SyscallRecord], by sort: DataSort, context: SyscallActivity.Context, argNames: Bool) -> [SyscallRecord] {
        guard let c = callsColumns(context: context, argNames: argNames).first(where: { $0.id == sort.column }) else { return rows }
        return rows.enumerated().sorted { a, b in
            if c.less(a.element, b.element) { return sort.ascending }
            if c.less(b.element, a.element) { return !sort.ascending }
            return a.offset < b.offset
        }.map(\.element)
    }

    private var summaryTable: some View {
        DataTable(rows: summary, columns: [
            .text("name", "Syscall", width: 200, mono: true) { $0.name },
            .number("calls", "Calls", width: 70, value: { $0.calls }, format: { $0.formatted() }),
            .number("errors", "Errors", width: 60, color: { _ in .systemRed }, value: { $0.errors == 0 ? nil : $0.errors }, format: { $0.formatted() }),
            .number("total", "Total time", width: 90, value: { $0.totalNanos }, format: Self.duration),
            .number("average", "Average", width: 90, value: { $0.avgNanos }, format: Self.duration),
            .number("longest", "Longest", width: 90, value: { $0.maxNanos }, format: Self.duration),
        ], initialSort: ("total", false), autosave: "syscallSummary", live: true, selection: $summarySelection,
                  menu: { rows in
                      guard rows.count == 1, let page = ManPage.page(for: rows[0].name) else { return [] }
                      return [DataMenuItem(title: "\(page.title) Man Page") { ManPage.open(page) }]
                  },
                  exportName: "\(target.name) syscall summary")
    }

    /// Filter and sort off the main thread; while tracing, at most ~3 times a second.
    private func recompute() async {
        guard !Task.isCancelled else { return }
        let all = tracer.records + tracer.pending
        let filter = filter, errorsOnly = errorsOnly, context = tracer.context, sort = sort, summaryMode = mode == "Summary", argNames = argNames
        if mode == "Activity" {
            let groups = await Task.detached(priority: .userInitiated) {
                SyscallActivity.build(all, filter: filter, errorsOnly: errorsOnly, context: context)
            }.value
            if !Task.isCancelled { activities = groups }
            return
        }
        let result = await Task.detached(priority: .userInitiated) { () -> ([SyscallRecord], [SyscallSummaryRow]) in
            let rows = all.filter { r in
                (!errorsOnly || r.failed) &&
                (filter.isEmpty || r.name.localizedCaseInsensitiveContains(filter) || r.pathText.localizedCaseInsensitiveContains(filter)
                 || Self.result(r, context).localizedCaseInsensitiveContains(filter) || r.argsText.localizedCaseInsensitiveContains(filter)
                 || r.caller.localizedCaseInsensitiveContains(filter)
                 || (context.threadNames[r.thread]?.localizedCaseInsensitiveContains(filter) ?? false))
            }
            // The summary's table sorts itself (it is short); this order is the export's.
            if summaryMode { return ([], SyscallSummaryRow.build(rows).sorted { $0.totalNanos > $1.totalNanos }) }
            return (Self.ordered(rows, by: sort, context: context, argNames: argNames), [])
        }.value
        guard !Task.isCancelled else { return }
        if summaryMode { summary = result.1 } else { shown = result.0 }
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
