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
    @State private var selection = Set<UInt64>()
    @State private var filter = ""
    @AppStorage("threads.busyOnly") private var busyOnly = false
    @AppStorage("threads.kernelIdle") private var showIdle = false
    @State private var details: ThreadDetails?
    @State private var capturing = false
    @State private var captureTask: Task<Void, Never>?

    /// kernel_task (pid 0): read as root only, no main thread, and `sample` can't attach to it.
    private var isKernel: Bool { proc.pid == 0 }

    /// kernel_task's per-CPU idle threads ("idle #0" …) hold every idle CPU's time, and with it the interrupts
    /// taken while idle, so they'd top a CPU sort; hidden, and left out of the totals, unless asked for.
    private static func isIdle(_ r: Row) -> Bool { r.t.name.hasPrefix("idle #") }

    /// The rows the totals and the table count: all but kernel_task's idle threads when they're hidden.
    private var counted: [Row] { isKernel && !showIdle ? rows.filter { !Self.isIdle($0) } : rows }

    private var shown: [Row] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        let byID = details?.byID ?? [:]
        return counted.map { r in
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
        // The table sorts by a column; within a tie, the thread with more CPU time comes first.
        .sorted { $0.timeKey > $1.timeKey }
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
            if !exited && !isKernel { capture() }
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
                rows = Self.rows(snap, prev: prev, kernel: pid == 0)
                prev = snap; last = snap; viaHelper = helped; failed = false
            } else {
                failed = rows.isEmpty
            }
            // 0: the list isn't refreshing (another app is in front, and it's set to stop then).
            try? await Task.sleep(for: .seconds(store.interval > 0 ? max(store.interval, 0.5) : 10))
        }
    }

    private static func rows(_ s: ThreadSnapshot, prev: ThreadSnapshot?, kernel: Bool) -> [Row] {
        let before = Dictionary((prev?.threads ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let wall = prev.map { Double(s.at &- $0.at) } ?? 0
        // The task's thread list starts with the thread the process was created with; kernel_task has no main thread.
        let main = kernel ? nil : s.threads.first?.id
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
        let rows = counted
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
                    if isKernel {
                        Toggle("Idle threads", isOn: $showIdle).toggleStyle(.checkbox).font(.caption)
                            .help("Show the per-CPU idle threads (idle #0 …). They hold all idle CPU time, interrupts taken while idle included, and are left out of the totals while hidden.")
                    } else {
                        Button(details == nil ? "Capture stacks" : "Recapture stacks") { capture() }
                            .disabled(capturing || exited)
                            .help("Take one sample of every thread's stack (sample <pid> 0 1, which suspends the process for an instant) and read dispatch queues and QoS (taskinfo, as root).")
                    }
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
        let live = (store.interval > 0 ? "Every \(store.interval.formatted()) s · " : "Every 10 s · ") + (viaHelper ? "as root via helper" : "as \(NSUserName())")
            + (isKernel ? " · kernel threads have no user-space stacks to sample" : "")
        guard let d = details, d.hasStacks || d.hasQoS else { return live }
        return live + " · stacks at " + d.at.formatted(date: .omitted, time: .standard)
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted").font(.largeTitle).foregroundStyle(.tertiary)
            if exited {
                Text(InspectorView.exitedNote).foregroundStyle(.secondary)
            } else if failed {
                Text(isKernel && !store.helperState.isRunning
                     ? "Kernel threads are only readable as root. Install the helper (Settings ▸ Helper) to read them."
                     : store.helperState.isRunning
                     ? "The threads of \(proc.name) couldn't be read."
                     : "The threads of a process owned by \(proc.user) aren't readable. Install the helper (Settings ▸ Helper) to read them.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var table: some View {
        DataTable(rows: shown, columns: columns, initialSort: ("cpu", false), autosave: "threads", live: true,
                  selection: $selection, exportName: "\(proc.name) threads")
    }

    private var columns: [DataColumn<Row>] {
        let secondary: (Row) -> NSColor? = { _ in .secondaryLabelColor }
        let noDetail = details == nil ? "From the stack capture." : "No stack for this thread in the last capture."
        func number<N: Comparable>(_ id: String, _ title: String, _ width: CGFloat, help: String? = nil,
                                   color: ((Row) -> NSColor?)? = nil, tooltip: ((Row) -> String?)? = nil,
                                   _ value: @escaping (Row) -> N?, _ format: @escaping (N) -> String) -> DataColumn<Row> {
            var c = DataColumn<Row>.number(id, title, width: width, help: help, color: color, value: value, format: format)
            // A dash rather than a blank where a counter couldn't be read.
            c.text = { value($0).map(format) ?? "—" }
            c.tooltip = tooltip
            return c
        }
        func text(_ id: String, _ title: String, _ width: CGFloat, color: ((Row) -> NSColor?)? = nil,
                  tooltip: ((Row) -> String?)? = nil, _ value: @escaping (Row) -> String) -> DataColumn<Row> {
            var c = DataColumn<Row>.text(id, title, width: width, color: color, value)
            c.tooltip = tooltip
            return c
        }
        var kind = text("kind", "Kind", 110, color: { $0.kind == .gcdIdle || $0.kind == .gcdNotRun ? .secondaryLabelColor : nil },
                        tooltip: { $0.kind?.help ?? noDetail }) { $0.kind?.text ?? "" }
        kind.less = { $0.kindKey < $1.kindKey }
        var qos = text("qos", "QoS", 96, color: { $0.detail?.darwinBG == true ? .systemOrange : nil }, tooltip: { Self.qosHelp($0.detail) }) { r in
            r.detail?.effectiveQoS ?? (r.detail?.requestedQoS == nil && r.detail?.schedMode != nil ? "unspecified" : "")
        }
        qos.less = { $0.qosKey < $1.qosKey }
        return [
            number("id", "ID", 72, color: secondary, { $0.id }, { String($0) }),
            text("name", "Name", 180, color: { $0.t.name.isEmpty ? .secondaryLabelColor : nil }) { $0.shownName.isEmpty ? "—" : $0.shownName },
            kind,
            number("cpu", "CPU %", 64, color: { ($0.cpu ?? 0) > 0 ? nil : .secondaryLabelColor }, { $0.cpu }, Fmt.pct),
            number("cpuTime", "CPU time", 80, { $0.t.cpuNanos }, { Fmt.secs($0) }),
            number("userTime", "User time", 70, color: secondary, { $0.t.userNanos }, { Fmt.secs($0) }),
            number("systemTime", "System time", 70, color: secondary, { $0.t.systemNanos }, { Fmt.secs($0) }),
            number("pCore", "P-core share", 60, tooltip: { Self.coresHelp($0.t) }, { $0.t.perfShare }, { "\(Fmt.pct($0)) %" }),
            number("ipc", "Instr/cycle", 44, tooltip: { Self.coresHelp($0.t) }, { $0.t.ipc }, { $0.formatted(.number.precision(.fractionLength(2))) }),
            number("power", "Power", 64, help: "CPU energy over the last interval, from the kernel's per-thread counters.",
                   color: { ($0.power ?? 0) > 0 ? nil : .secondaryLabelColor }, { $0.power }, Self.mW),
            number("energy", "Energy", 64, tooltip: { Self.coresHelp($0.t) }, { $0.t.energyNJ }, Self.joules),
            text("wait", "Waiting in", 260) { Self.waitText($0.detail) },
            text("queue", "Queue", 140, color: secondary) { $0.detail?.queue ?? "" },
            qos,
            text("state", "State", 64, color: { NSColor(Self.stateColor($0.t.runState)) }) { $0.t.stateText },
            number("priority", "Priority", 56, help: "Current priority. Higher runs first; 31 is the default, 46–47 is user-interactive work.",
                   { $0.t.curPriority }, { String($0) }),
            number("basePriority", "Base priority", 56, color: { $0.t.basePriority == $0.t.curPriority ? .secondaryLabelColor : nil },
                   { $0.t.basePriority }, { String($0) }),
            number("maxPriority", "Max priority", 56, color: secondary, { $0.t.maxPriority }, { String($0) }),
            text("policy", "Policy", 76, color: { $0.t.policy == 1 ? .secondaryLabelColor : nil },
                 tooltip: { $0.t.policy == 1 ? "Timesharing: the usual policy." : "Fixed-priority policy, as real-time threads (audio, for example) use." }) { $0.t.policyText },
        ]
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
}
