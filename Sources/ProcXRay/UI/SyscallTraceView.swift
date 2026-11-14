import AppKit
import SwiftUI

/// Drives one syscall trace: the helper runs ktrace, a background loop reads and pairs its events.
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
    /// Bumped on every change to `records`, so views can key recomputation on one number.
    private(set) var revision = 0
    private var stopFlag: Shell.Cancel?

    static let cap = 200_000

    var isActive: Bool { phase == .starting || phase == .running || phase == .stopping }

    func start(pid: Int32, start: Date) {
        guard !isActive else { return }
        records = []; pending = []; notes = []; events = 0; dropped = 0; revision += 1
        phase = .starting
        let flag = Shell.Cancel()
        stopFlag = flag
        // Holds the tracer until the trace ends; the view stops it when it goes away (onDisappear).
        Task.detached(priority: .userInitiated) { [self] in
            await Self.run(pid: pid, start: start, flag: flag, tracer: self)
        }
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

    private nonisolated static func run(pid: Int32, start: Date, flag: Shell.Cancel, tracer: SyscallTracer) async {
        let s = HelperTraceSession()
        defer { s.close() }
        if let err = s.start(pid: pid) {
            await tracer.finish([], note: err)
            return
        }
        await tracer.setPhase(.running)
        var dec = SyscallDecoder()
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
            guard let (data, running, notes) = s.read() else {
                endNote = "Lost the connection to the helper."
                break
            }
            let (evs, bad) = KdebugEvent.decode(data)
            let recs = dec.feed(evs)
            var n = notes.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            if bad > 0 { n.append("\(bad) unreadable trace lines skipped.") }
            if !recs.isEmpty || !n.isEmpty || !evs.isEmpty {
                await tracer.append(recs, events: evs.count, notes: n)
            }
            if !running { break }
            if let t = stopTime, Date().timeIntervalSince(t) > deadlineAfterStop { endNote = endNote ?? "ktrace did not stop in time."; break }
            // A full read means more is waiting: read again right away.
            if data.count < SyscallTraceConfig.maxRead / 2 { try? await Task.sleep(for: .milliseconds(250)) }
        }
        await tracer.finish(dec.pending(), note: endNote)
    }

    private func setPhase(_ p: Phase) { if phase == .starting { phase = p } }

    private func append(_ recs: [SyscallRecord], events n: Int, notes n2: [String]) {
        events += n
        for note in n2 where !notes.contains(note) {
            notes.append(note)
            // Seen live: "ktrace: cannot access trace system: in use by ktrace[61040]", then exit status 77.
            if note.contains("cannot access trace system") {
                notes.append("The kernel allows one trace at a time: stop the other one (another trace here, Instruments or fs_usage) and trace again.")
            }
        }
        guard !recs.isEmpty else { return }
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

struct SyscallTraceView: View {
    @Environment(Store.self) var store
    let proc: ProcInfo
    let exited: Bool
    @State private var tracer = SyscallTracer()
    @AppStorage("syscallTrace.mode") private var mode = "Calls"
    @State private var filter = ""
    @State private var errorsOnly = false
    @State private var sort = [KeyPathComparator(\SyscallRecord.time, order: .reverse)]
    @State private var shown: [SyscallRecord] = []
    @State private var summary: [SyscallSummaryRow] = []
    @State private var summarySort = [KeyPathComparator(\SyscallSummaryRow.totalNanos, order: .reverse)]
    @State private var selection: Set<SyscallRecord.ID> = []

    private var disabledReason: String? {
        if exited { return InspectorView.exitedNote }
        if !store.helperState.isRunning { return "Tracing syscalls needs root: install the privileged helper (sidebar)." }
        return nil
    }

    private var key: String {
        "\(tracer.revision)\u{0}\(filter)\u{0}\(errorsOnly)\u{0}\(mode)\u{0}\(sort.first.map { "\($0.keyPath)\($0.order == .forward)" } ?? "")"
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
            } else if mode == "Summary" {
                summaryTable
            } else {
                callsTable
            }
        }
        .task(id: key) { await recompute() }
        .onDisappear { tracer.stop() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if tracer.isActive {
                Button { tracer.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .disabled(tracer.phase == .stopping)
            } else {
                Button { tracer.start(pid: proc.pid, start: proc.start) } label: {
                    Label(tracer.phase == .idle ? "Trace" : "Trace again", systemImage: "record.circle")
                }
                .disabled(disabledReason != nil)
                .help(disabledReason ?? "Trace this process's BSD syscalls and Mach traps (ktrace, as root via the helper)")
            }
            if tracer.phase == .starting || tracer.phase == .stopping { ProgressView().controlSize(.small) }
            Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Picker("", selection: $mode) {
                Text("Calls").tag("Calls")
                Text("Summary").tag("Summary")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Toggle("Errors only", isOn: $errorsOnly).toggleStyle(.checkbox).font(.caption)
            TextField("filter", text: $filter).textFieldStyle(.roundedBorder).frame(width: 160)
            Button("Clear") { tracer.clear(); selection = [] }.disabled(tracer.isActive || tracer.phase == .idle)
        }
        .padding(6)
    }

    private var status: String {
        let n = tracer.records.count + tracer.pending.count
        let calls = "\(n.formatted()) call\(n == 1 ? "" : "s")"
        let dropped = tracer.dropped > 0 ? " · oldest \(tracer.dropped.formatted()) let go" : ""
        let showing = shown.count != tracer.records.count + tracer.pending.count && mode == "Calls" ? " · \(shown.count.formatted()) shown" : ""
        switch tracer.phase {
        case .idle: return "ktrace trace -p \(proc.pid) -f \(SyscallTraceConfig.filter)"
        case .starting: return "Starting ktrace…"
        case .running: return "Tracing · \(calls)\(showing)\(dropped)"
        case .stopping: return "Stopping · \(calls)"
        case .stopped: return "Stopped · \(calls)\(showing)\(dropped)"
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg").font(.largeTitle).foregroundStyle(.tertiary)
            Text("Every syscall and Mach trap this process makes, with arguments, results, errors, durations and file paths.")
                .multilineTextAlignment(.center)
            Text(disabledReason ?? "Uses the kernel's kdebug trace (as Instruments' System Call Trace does). One trace at a time per machine: it can't run while Instruments or fs_usage is recording.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(30).frame(maxWidth: 520).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var callsTable: some View {
        Table(shown, selection: $selection, sortOrder: $sort) {
            TableColumn("Time", value: \.time) { r in
                Text(r.start.map(Self.seconds) ?? "before").monospacedDigit()
            }
            .width(min: 70, ideal: 84, max: 110)
            TableColumn("Thread", value: \.thread) { r in Text(String(r.thread)).monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 50, ideal: 70, max: 100)
            TableColumn("Syscall", value: \.name) { r in
                Text(r.name).foregroundStyle(r.mach ? Color.purple : Color.primary)
            }
            .width(min: 90, ideal: 150)
            TableColumn("Arguments") { r in Text(r.argsText).foregroundStyle(.secondary).help(r.argsText) }
                .width(min: 100, ideal: 240)
            TableColumn("Result") { r in
                Text(r.resultText)
                    .foregroundStyle(r.failed ? Color.red : (r.state == .inProgress ? Color.orange : Color.primary))
                    .help(r.resultText)
            }
            .width(min: 60, ideal: 140)
            TableColumn("Duration", value: \.durationKey) { r in
                Text(r.duration.map(Self.duration) ?? "—").monospacedDigit()
            }
            .width(min: 60, ideal: 76, max: 110)
            TableColumn("Path") { r in
                HStack(spacing: 4) {
                    Text(r.pathText).help(r.pathText)
                    // The first existing one: a rename's source is usually gone, its destination isn't.
                    if let path = r.paths.lazy.compactMap(Reveal.path(in:)).first { Spacer(minLength: 0); RevealButton(path: path) }
                }
            }
                .width(min: 80, ideal: 260)
        }
        .font(.system(size: 11, design: .monospaced))
        .contextMenu(forSelectionType: SyscallRecord.ID.self) { ids in
            Button("Copy") { copy(ids) }
        }
        .onCopyCommand { [ids = selection] in
            [NSItemProvider(object: text(for: ids) as NSString)]
        }
    }

    private var summaryTable: some View {
        Table(summary, sortOrder: $summarySort) {
            TableColumn("Syscall", value: \.name) { s in Text(s.name) }.width(min: 120, ideal: 200)
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
        .onChange(of: summarySort) { summary.sort(using: summarySort) }
    }

    /// Filter and sort off the main thread; while tracing, at most ~3 times a second.
    private func recompute() async {
        if tracer.phase == .running { try? await Task.sleep(for: .milliseconds(300)) }
        guard !Task.isCancelled else { return }
        let all = tracer.records + tracer.pending
        let filter = filter, errorsOnly = errorsOnly, sort = sort, summaryMode = mode == "Summary", summarySort = summarySort
        let result = await Task.detached(priority: .userInitiated) { () -> ([SyscallRecord], [SyscallSummaryRow]) in
            let rows = all.filter { r in
                (!errorsOnly || r.failed) &&
                (filter.isEmpty || r.name.localizedCaseInsensitiveContains(filter) || r.pathText.localizedCaseInsensitiveContains(filter)
                 || r.resultText.localizedCaseInsensitiveContains(filter) || r.argsText.localizedCaseInsensitiveContains(filter))
            }
            if summaryMode { return ([], SyscallSummaryRow.build(rows).sorted(using: summarySort)) }
            return (rows.sorted(using: sort), [])
        }.value
        guard !Task.isCancelled else { return }
        if summaryMode { summary = result.1 } else { shown = result.0 }
    }

    private func copy(_ ids: Set<SyscallRecord.ID>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(for: ids), forType: .string)
    }

    /// strace-style lines: `+1.234567 [tid] name(args) = result <duration> path`.
    private func text(for ids: Set<SyscallRecord.ID>) -> String {
        shown.filter { ids.contains($0.id) }.map { r in
            let t = r.start.map(Self.seconds) ?? "before"
            let d = r.duration.map { " <\(Self.duration($0))>" } ?? ""
            let p = r.paths.isEmpty ? "" : "  \(r.pathText)"
            return "\(t) [\(r.thread)] \(r.name)(\(r.argsText)) = \(r.resultText)\(d)\(p)"
        }.joined(separator: "\n")
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
