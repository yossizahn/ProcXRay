import AppKit
import SwiftUI

/// Every thread of one process, read again each refresh interval: CPU over the last interval, CPU time,
/// state and scheduling. Read directly for the user's own processes and through the helper for the rest.
/// Stacks (one `sample`), dispatch queues and QoS (`taskinfo`) are a snapshot, captured when the pane opens
/// and again on request.
struct ThreadsView: View {
    @Environment(Store.self) var store
    let proc: ProcInfo
    var exited = false

    struct Row: Identifiable {
        let t: ThreadSample
        /// Share of one core over the last interval; nil for a thread first seen this read.
        let cpu: Double?
        let isMain: Bool
        /// Milliwatts over the last interval, from the energy counters; nil without them or a previous read.
        let power: Double?
        /// From the last stack / QoS capture; nil for a thread that didn't exist then.
        var detail: ThreadDetail? = nil
        var kind: ThreadKind? = nil
        var id: UInt64 { t.id }
        var shownName: String { t.name.isEmpty ? (isMain ? "main thread" : "") : t.name }
        // Sort keys.
        var cpuKey: Double { cpu ?? -1 }
        var timeKey: UInt64 { t.cpuNanos }
        var userKey: UInt64 { t.userNanos }
        var systemKey: UInt64 { t.systemNanos }
        var priorityKey: Int32 { t.curPriority }
        var basePriorityKey: Int32 { t.basePriority }
        var maxPriorityKey: Int32 { t.maxPriority }
        var stateKey: String { t.stateText }
        var policyKey: String { t.policyText }
        var queueKey: String { detail?.queue ?? "" }
        var qosKey: Int { ThreadsView.qosRank[detail?.effectiveQoS ?? ""] ?? -1 }
        var waitKey: String { detail?.leaf?.symbol ?? "" }
        var kindKey: Int { kind?.rawValue ?? Int.max }
        var perfKey: Double { t.perfShare ?? -1 }
        var ipcKey: Double { t.ipc ?? -1 }
        var powerKey: Double { power ?? -1 }
        var energyKey: UInt64 { t.energyNJ ?? 0 }
    }
    static let qosRank = ["Maintenance": 0, "Background": 1, "Utility": 2, "Default": 3, "User initiated": 4, "User interactive": 5]

    @State private var rows: [Row] = []
    @State private var last: ThreadSnapshot?
    @State private var viaHelper = false
    @State private var failed = false
    @State private var sort = [KeyPathComparator(\Row.cpuKey, order: .reverse), KeyPathComparator(\Row.timeKey, order: .reverse)]
    @State private var selection = Set<UInt64>()
    @State private var filter = ""
    @AppStorage("threads.busyOnly") private var busyOnly = false
    @State private var details: ThreadDetails?
    @State private var capturing = false
    @State private var captureTask: Task<Void, Never>?

    private var shown: [Row] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        let byID = details?.byID ?? [:]
        return rows.map { r in
            var r = r; r.detail = byID[r.id]
            // The stack wins: when the main thread has exited (dispatch_main does that), the first listed one isn't it.
            r.kind = details?.kind(r.id) ?? (r.isMain ? .main : nil)
            return r
        }.filter { r in
            (!busyOnly || (r.cpu ?? 0) > 0)
                && (f.isEmpty || r.shownName.localizedCaseInsensitiveContains(f) || String(r.id).contains(f)
                    || (r.detail?.queue?.localizedCaseInsensitiveContains(f) ?? false)
                    || (r.kind?.text.localizedCaseInsensitiveContains(f) ?? false)
                    || (r.detail?.stack.contains { $0.symbol.localizedCaseInsensitiveContains(f) } ?? false))
        }
        .sorted(using: sort)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if rows.isEmpty {
                placeholder
            } else {
                // A stored fraction, so the divider stays put as the selection comes and goes.
                SplitPane(id: "threads", defaultFraction: 0.55, showsBottom: selection.count == 1) {
                    table
                } bottom: {
                    if let id = selection.first { stackPane(id) }
                }
            }
        }
        .task(id: "\(proc.key)|\(exited)|\(store.helperState.isRunning)") { await poll() }
        .task(id: "\(proc.key)|\(store.helperState.isRunning)") {
            // Once per process when the pane opens; later captures are on request.
            details = nil
            if !exited { capture() }
        }
        .onDisappear { captureTask?.cancel() }
    }

    /// One `sample` (stacks and queue names; root via the helper, or as the user) and, with the helper,
    /// `taskinfo` (QoS, sched mode, I/O tier). Both checked against the pid's start time afterwards.
    private func capture() {
        captureTask?.cancel()
        capturing = true
        let pid = proc.pid, start = proc.start, helper = store.helperState.isRunning
        let cancel = Shell.Cancel()
        captureTask = Task {
            let got = await withTaskCancellationHandler {
                await Task.detached { () -> ThreadDetails? in
                    Shell.Cancel.$current.withValue(cancel) {
                        guard Native.isSame(pid, start: start) else { return nil }
                        var d = ThreadDetails()
                        // Both at once: taskinfo doesn't suspend the target, and the two take ~0.3 s and ~0.15 s.
                        var ti: String?
                        let group = DispatchGroup()
                        if helper {
                            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                                ti = HelperClient.shared.run(.taskinfo, pid: pid, timeout: 15)
                            }
                        }
                        // Listed before sampling: which threads existed, and whether they had run user code.
                        if let s = ThreadReader.read(pid) ?? (helper ? HelperClient.shared.threads(pid) : nil) {
                            d.listedUserNanos = Dictionary(s.threads.map { ($0.id, $0.userNanos) }, uniquingKeysWith: { a, _ in a })
                        }
                        let stacks: String
                        if helper { stacks = HelperClient.shared.run(.stacks, pid: pid, timeout: 20) ?? "" }
                        else if let (path, args) = HelperTool.stacks.argv(pid: pid) { stacks = Shell.run(path, args, timeout: HelperTool.stacks.timeout) }
                        else { stacks = "" }
                        group.wait()
                        guard Native.isSame(pid, start: start) else { return nil }
                        if stacks.contains("Call graph:") { d.mergeSample(stacks) }
                        else {
                            let why = stacks.split(separator: "\n").first.map(String.init) ?? "no output"
                            d.notes.append("No stacks: \(why)" + (helper ? "" : " Install the privileged helper to sample other processes."))
                        }
                        if let ti, ti.contains("threads:") { d.mergeTaskinfo(ti) }
                        else if !helper { d.notes.append("QoS needs the privileged helper (taskinfo runs as root only).") }
                        return d
                    }
                }.value
            } onCancel: { cancel.cancel() }
            guard !Task.isCancelled else { return }
            if let got { details = got }
            capturing = false
        }
    }

    // MARK: reading

    private func poll() async {
        // An exit: keep the last read and read no more (the pid may be reused). A new process: start over.
        guard !exited else { return }
        let pid = proc.pid, start = proc.start
        let helper = store.helperState.isRunning
        var prev: ThreadSnapshot? = nil
        rows = []; last = nil; failed = false
        while !Task.isCancelled {
            let got = await Task.detached { () -> (ThreadSnapshot, Bool)? in
                var r: (ThreadSnapshot, Bool)?
                if let s = ThreadReader.read(pid) { r = (s, false) }
                else if helper, let s = HelperClient.shared.threads(pid) { r = (s, true) }
                // Checked after the read: a reused pid's threads must not be shown as this process's.
                return Native.isSame(pid, start: start) ? r : nil
            }.value
            guard !Task.isCancelled else { return }
            if let (snap, helped) = got {
                rows = Self.rows(snap, prev: prev)
                prev = snap; last = snap; viaHelper = helped; failed = false
            } else {
                failed = rows.isEmpty
            }
            try? await Task.sleep(for: .seconds(max(store.interval, 0.5)))
        }
    }

    private static func rows(_ s: ThreadSnapshot, prev: ThreadSnapshot?) -> [Row] {
        let before = Dictionary((prev?.threads ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let wall = prev.map { Double(s.at &- $0.at) } ?? 0
        // The task's thread list starts with the thread the process was created with.
        let main = s.threads.first?.id
        return s.threads.map { t in
            var cpu: Double?, power: Double?
            if wall > 0, let b = before[t.id] {
                cpu = Double(t.cpuNanos >= b.cpuNanos ? t.cpuNanos - b.cpuNanos : 0) / wall * 100
                // nJ per ns = W; × 1000 for mW.
                if let e = t.energyNJ, let e0 = b.energyNJ { power = Double(e >= e0 ? e - e0 : 0) / wall * 1000 }
            }
            return Row(t: t, cpu: cpu, isMain: t.id == main, power: power)
        }
    }

    // MARK: views

    private var header: some View {
        let busy = rows.filter { ($0.cpu ?? 0) > 0 }.count
        let total = rows.compactMap(\.cpu).reduce(0, +)
        return HStack(spacing: 8) {
            StatTile(title: "Threads", value: Fmt.count(rows.count), sub: "\(busy) used CPU")
            StatTile(title: "CPU", value: rows.contains { $0.cpu != nil } ? "\(Fmt.pct(total)) %" : "—", sub: "sum of threads")
            if rows.contains(where: { $0.power != nil }) {
                StatTile(title: "Power", value: Self.mW(rows.compactMap(\.power).reduce(0, +)), sub: "sum of threads")
                    .help("CPU energy of all threads over the last interval, from the kernel's per-thread energy counters (PROC_PIDTHREADCOUNTS). CPU cores only: no GPU, memory or display.")
            }
            if let wq = last?.workqueue {
                StatTile(title: "Workqueue", value: Fmt.count(wq.total), sub: "\(wq.running) running · \(wq.blocked) blocked")
                    .help("Threads in the process's GCD pool (PROC_PIDWORKQUEUEINFO): all of them, those running work items, and those blocked in one.")
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 8) {
                    if capturing { ProgressView().controlSize(.small) }
                    Button(details == nil ? "Capture stacks" : "Recapture stacks") { capture() }
                        .disabled(capturing || exited)
                        .help("Take one sample of every thread's stack (sample <pid> 0 1, which suspends the process for an instant) and read dispatch queues and QoS (taskinfo, as root).")
                    Toggle("Only threads using CPU", isOn: $busyOnly).toggleStyle(.checkbox).font(.caption)
                    TextField("filter name or ID", text: $filter).textFieldStyle(.roundedBorder).frame(width: 160)
                }
                Text(sourceNote).font(.caption).foregroundStyle(.secondary)
                if let notes = details?.notes, !notes.isEmpty {
                    Text(notes.joined(separator: " ")).font(.caption).foregroundStyle(.orange).lineLimit(1).truncationHelp(notes.joined(separator: "\n"))
                }
            }
        }
        .padding(8)
    }

    private var sourceNote: String {
        if exited { return "Exited: the last read is shown." }
        if rows.isEmpty { return "" }
        let live = "Every \(store.interval.formatted()) s · " + (viaHelper ? "as root via helper" : "as \(NSUserName())")
        guard let d = details, d.hasStacks || d.hasQoS else { return live }
        return live + " · stacks at " + d.at.formatted(date: .omitted, time: .standard)
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted").font(.largeTitle).foregroundStyle(.tertiary)
            if exited {
                Text(InspectorView.exitedNote).foregroundStyle(.secondary)
            } else if failed {
                Text(store.helperState.isRunning
                     ? "The threads of \(proc.name) couldn't be read."
                     : "The threads of a process owned by \(proc.user) aren't readable. Install the privileged helper (sidebar) to read them.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var table: some View {
        Table(shown, selection: $selection, sortOrder: $sort) {
          // A table builder block takes at most 10 columns.
          Group {
            TableColumn("ID", value: \Row.id) { r in Text(String(r.id)).monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 50, ideal: 72, max: 110)
            TableColumn("Name", value: \Row.shownName) { r in
                Text(r.shownName.isEmpty ? "—" : r.shownName)
                    .foregroundStyle(r.t.name.isEmpty ? .secondary : .primary)
                    .italic(r.t.name.isEmpty && r.isMain)
                    .truncationHelp(r.shownName)
            }
            .width(min: 90, ideal: 180)
            TableColumn("Kind", value: \Row.kindKey) { r in
                Text(r.kind?.text ?? "").foregroundStyle(r.kind == .gcdIdle || r.kind == .gcdNotRun ? .secondary : .primary)
                    .help(r.kind?.help ?? (details == nil ? "From the stack capture." : "No stack for this thread in the last capture."))
            }
            .width(min: 50, ideal: 110, max: 150)
            TableColumn("CPU %", value: \Row.cpuKey) { r in
                Text(r.cpu.map(Fmt.pct) ?? "—").monospacedDigit()
                    .foregroundStyle((r.cpu ?? 0) > 0 ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 64, max: 90)
            TableColumn("CPU time", value: \Row.timeKey) { r in
                Text(Fmt.secs(r.t.cpuNanos)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80, max: 110)
            TableColumn("User time", value: \Row.userKey) { r in
                Text(Fmt.secs(r.t.userNanos)).monospacedDigit().foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 70, max: 110)
            TableColumn("System time", value: \Row.systemKey) { r in
                Text(Fmt.secs(r.t.systemNanos)).monospacedDigit().foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 70, max: 110)
          }
          Group {
            TableColumn("P-core share", value: \Row.perfKey) { r in
                Text(r.t.perfShare.map { "\(Fmt.pct($0)) %" } ?? "—").monospacedDigit()
                    .foregroundStyle(r.t.perfShare == nil ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(Self.coresHelp(r.t))
            }
            .width(min: 50, ideal: 60, max: 90)
            TableColumn("Instr/cycle", value: \Row.ipcKey) { r in
                Text(r.t.ipc.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "—").monospacedDigit()
                    .foregroundStyle(r.t.ipc == nil ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(Self.coresHelp(r.t))
            }
            .width(min: 36, ideal: 44, max: 70)
            TableColumn("Power", value: \Row.powerKey) { r in
                Text(r.power.map(Self.mW) ?? "—").monospacedDigit()
                    .foregroundStyle((r.power ?? 0) > 0 ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help("CPU energy over the last interval, from the kernel's per-thread counters.")
            }
            .width(min: 50, ideal: 64, max: 90)
            TableColumn("Energy", value: \Row.energyKey) { r in
                Text(r.t.energyNJ.map(Self.joules) ?? "—").monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(Self.coresHelp(r.t))
            }
            .width(min: 50, ideal: 64, max: 90)
            TableColumn("Waiting in", value: \Row.waitKey) { r in
                let w = Self.waitText(r.detail)
                Text(w.isEmpty ? "—" : w).foregroundStyle(w.isEmpty ? .secondary : .primary).truncationHelp(w)
            }
            .width(min: 100, ideal: 260)
            TableColumn("Queue", value: \Row.queueKey) { r in
                Text(r.detail?.queue ?? "").foregroundStyle(.secondary).truncationHelp(r.detail?.queue ?? "")
            }
            .width(min: 50, ideal: 140)
            TableColumn("QoS", value: \Row.qosKey) { r in
                Text(r.detail?.effectiveQoS ?? (r.detail?.requestedQoS == nil && r.detail?.schedMode != nil ? "unspecified" : ""))
                    .foregroundStyle(r.detail?.darwinBG == true ? .orange : .primary)
                    .help(Self.qosHelp(r.detail))
            }
            .width(min: 60, ideal: 96, max: 130)
            TableColumn("State", value: \Row.stateKey) { r in
                Text(r.t.stateText).foregroundStyle(Self.stateColor(r.t.runState))
            }
            .width(min: 50, ideal: 64, max: 110)
          }
          Group {
            TableColumn("Priority", value: \Row.priorityKey) { r in
                Text("\(r.t.curPriority)").monospacedDigit()
                    .help("Current priority. Higher runs first; 31 is the default, 46–47 is user-interactive work.")
            }
            .width(min: 44, ideal: 56, max: 90)
            TableColumn("Base priority", value: \Row.basePriorityKey) { r in
                Text("\(r.t.basePriority)").monospacedDigit().foregroundStyle(r.t.basePriority == r.t.curPriority ? .secondary : .primary)
            }
            .width(min: 44, ideal: 56, max: 90)
            TableColumn("Max priority", value: \Row.maxPriorityKey) { r in
                Text("\(r.t.maxPriority)").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 44, ideal: 56, max: 90)
            TableColumn("Policy", value: \Row.policyKey) { r in
                Text(r.t.policyText).foregroundStyle(r.t.policy == 1 ? .secondary : .primary)
                    .help(r.t.policy == 1 ? "Timesharing: the usual policy." : "Fixed-priority policy, as real-time threads (audio, for example) use.")
            }
            .width(min: 60, ideal: 76, max: 110)
          }
        }
        .font(.system(size: 11))
        .contextMenu(forSelectionType: UInt64.self) { ids in
            Button("Copy") { copy(ids) }
        }
        .onCopyCommand { [ids = selection] in [NSItemProvider(object: text(for: ids) as NSString)] }
    }

    /// "mach_msg2_trap ← __CFRunLoopServiceMachPort": the innermost frame, and the innermost one outside the
    /// syscall and pthread wrappers when that is a different frame.
    static func waitText(_ d: ThreadDetail?) -> String {
        guard let leaf = d?.leaf else { return "" }
        guard let c = d?.caller, c != leaf else { return leaf.symbol }
        return "\(leaf.symbol) ← \(c.symbol)"
    }

    static func mW(_ v: Double) -> String {
        v >= 1000 ? "\((v / 1000).formatted(.number.precision(.fractionLength(2)))) W" : "\(v.formatted(.number.precision(.fractionLength(v < 10 ? 1 : 0)))) mW"
    }

    static func joules(_ nJ: UInt64) -> String {
        let j = Double(nJ) / 1e9
        return j >= 1 ? "\(j.formatted(.number.precision(.fractionLength(1)))) J" : "\((j * 1000).formatted(.number.precision(.fractionLength(1)))) mJ"
    }

    /// Per core type, over the thread's life: time, instructions per cycle and energy.
    static func coresHelp(_ t: ThreadSample) -> String {
        guard let cores = t.cores else { return "The kernel didn't return core counters for this thread." }
        let names = ["Performance cores", "Efficiency cores"]
        var lines = ["Over the thread's life (PROC_PIDTHREADCOUNTS):"]
        for (i, c) in cores.enumerated() {
            let ipc = c.cycles > 0 ? (Double(c.instructions) / Double(c.cycles)).formatted(.number.precision(.fractionLength(2))) : "—"
            lines.append("\(i < names.count ? names[i] : "Perf level \(i)"): \(Fmt.secs(c.nanos)), IPC \(ipc), \(joules(c.energyNJ))")
        }
        return lines.joined(separator: "\n")
    }

    static func qosHelp(_ d: ThreadDetail?) -> String {
        guard let d, d.schedMode != nil else { return "QoS comes from taskinfo, which needs the privileged helper." }
        var lines = ["Effective: \(d.effectiveQoS ?? "unspecified")", "Requested: \(d.requestedQoS ?? "unspecified")"]
        if let p = d.promotionQoS, p != d.effectiveQoS { lines.append("Promoted to: \(p)") }
        if let m = d.schedMode { lines.append("Scheduling: \(m)") }
        if let io = d.ioTier { lines.append("I/O tier: \(io)") }
        if d.darwinBG == true { lines.append("Darwin background: throttled CPU and I/O") }
        return lines.joined(separator: "\n")
    }

    /// The selected thread's stack from the last capture, innermost frame first (as a debugger shows it).
    @ViewBuilder private func stackPane(_ id: UInt64) -> some View {
        let d = details?.byID[id]
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Stack of thread \(String(id))").font(.caption.weight(.semibold))
                if let q = d?.queue { Text("· queue \(q)").font(.caption).foregroundStyle(.secondary) }
                if let at = details?.at, d?.stack.isEmpty == false {
                    Text("· sampled \(at.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            Divider()
            if let frames = d?.stack, !frames.isEmpty {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                        ForEach(Array(frames.reversed().enumerated()), id: \.offset) { i, f in
                            GridRow {
                                Text("\(i)").foregroundStyle(.tertiary).monospacedDigit().gridColumnAlignment(.trailing)
                                Text(f.library ?? "").foregroundStyle(.secondary).lineLimit(1)
                                Text(f.symbol).lineLimit(1).truncationHelp(f.symbol)
                                    .foregroundStyle(f.library.map(ThreadDetail.plumbing.contains) == true ? .secondary : .primary)
                            }
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(details.map { $0.noStackReason(id) } ?? "Capturing…")
                    .font(.caption).foregroundStyle(.secondary).padding(8)
                Spacer(minLength: 0)
            }
        }
    }

    private static func stateColor(_ s: Int32) -> Color {
        switch s {
        case 1: .green
        case 3: .secondary
        default: .orange   // stopped, uninterruptible, halted
        }
    }

    private func text(for ids: Set<UInt64>) -> String {
        shown.filter { ids.contains($0.id) }.map { r in
            [String(r.id), r.shownName, r.kind?.text ?? "", r.cpu.map(Fmt.pct) ?? "—", Fmt.secs(r.t.cpuNanos),
             r.t.perfShare.map(Fmt.pct) ?? "—", r.t.ipc.map { String(format: "%.2f", $0) } ?? "—",
             r.power.map(Self.mW) ?? "—", r.t.energyNJ.map(Self.joules) ?? "—", Self.waitText(r.detail),
             r.detail?.queue ?? "", r.detail?.effectiveQoS ?? "", r.t.stateText, "\(r.t.curPriority)", r.t.policyText].joined(separator: "\t")
        }.joined(separator: "\n")
    }

    private func copy(_ ids: Set<UInt64>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(for: ids), forType: .string)
    }
}
