import AppKit
import SwiftUI

/// Every thread of one process, read again each refresh interval: CPU over the last interval, CPU time,
/// state and scheduling. Read directly for the user's own processes and through the helper for the rest.
struct ThreadsView: View {
    @Environment(Store.self) var store
    let proc: ProcInfo
    var exited = false

    struct Row: Identifiable, Hashable {
        let t: ThreadSample
        /// Share of one core over the last interval; nil for a thread first seen this read.
        let cpu: Double?
        let isMain: Bool
        var id: UInt64 { t.id }
        var shownName: String { t.name.isEmpty ? (isMain ? "main thread" : "") : t.name }
        // Sort keys.
        var cpuKey: Double { cpu ?? -1 }
        var timeKey: UInt64 { t.cpuNanos }
        var userKey: UInt64 { t.userNanos }
        var systemKey: UInt64 { t.systemNanos }
        var priorityKey: Int32 { t.curPriority }
        var stateKey: String { t.stateText }
        var policyKey: String { t.policyText }
    }

    @State private var rows: [Row] = []
    @State private var last: ThreadSnapshot?
    @State private var viaHelper = false
    @State private var failed = false
    @State private var sort = [KeyPathComparator(\Row.cpuKey, order: .reverse), KeyPathComparator(\Row.timeKey, order: .reverse)]
    @State private var selection = Set<UInt64>()
    @State private var filter = ""
    @AppStorage("threads.busyOnly") private var busyOnly = false

    private var shown: [Row] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        return rows.filter { r in
            (!busyOnly || (r.cpu ?? 0) > 0)
                && (f.isEmpty || r.shownName.localizedCaseInsensitiveContains(f) || String(r.id).contains(f))
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
                table
            }
        }
        .task(id: "\(proc.key)|\(exited)|\(store.helperState.isRunning)") { await poll() }
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
        let before = Dictionary((prev?.threads ?? []).map { ($0.id, $0.cpuNanos) }, uniquingKeysWith: { a, _ in a })
        let wall = prev.map { Double(s.at &- $0.at) } ?? 0
        // The task's thread list starts with the thread the process was created with.
        let main = s.threads.first?.id
        return s.threads.map { t in
            var cpu: Double?
            if wall > 0, let b = before[t.id] { cpu = Double(t.cpuNanos >= b ? t.cpuNanos - b : 0) / wall * 100 }
            return Row(t: t, cpu: cpu, isMain: t.id == main)
        }
    }

    // MARK: views

    private var header: some View {
        let busy = rows.filter { ($0.cpu ?? 0) > 0 }.count
        let total = rows.compactMap(\.cpu).reduce(0, +)
        return HStack(spacing: 8) {
            StatTile(title: "Threads", value: Fmt.count(rows.count), sub: "\(busy) used CPU")
            StatTile(title: "CPU", value: rows.contains { $0.cpu != nil } ? "\(Fmt.pct(total)) %" : "—", sub: "sum of threads")
            if let wq = last?.workqueue {
                StatTile(title: "Workqueue", value: Fmt.count(wq.total), sub: "\(wq.running) running · \(wq.blocked) blocked")
                    .help("Threads in the process's GCD pool (PROC_PIDWORKQUEUEINFO): all of them, those running work items, and those blocked in one.")
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 8) {
                    Toggle("Only threads using CPU", isOn: $busyOnly).toggleStyle(.checkbox).font(.caption)
                    TextField("filter name or ID", text: $filter).textFieldStyle(.roundedBorder).frame(width: 160)
                }
                Text(sourceNote).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
    }

    private var sourceNote: String {
        if exited { return "Exited: the last read is shown." }
        if rows.isEmpty { return "" }
        return "Every \(store.interval.formatted()) s · " + (viaHelper ? "as root via helper" : "as \(NSUserName())")
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
            TableColumn("ID", value: \.id) { r in Text(String(r.id)).monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 50, ideal: 72, max: 110)
            TableColumn("Name", value: \.shownName) { r in
                Text(r.shownName.isEmpty ? "—" : r.shownName)
                    .foregroundStyle(r.t.name.isEmpty ? .secondary : .primary)
                    .italic(r.t.name.isEmpty && r.isMain)
                    .truncationHelp(r.shownName)
            }
            .width(min: 100, ideal: 220)
            TableColumn("CPU %", value: \.cpuKey) { r in
                Text(r.cpu.map(Fmt.pct) ?? "—").monospacedDigit()
                    .foregroundStyle((r.cpu ?? 0) > 0 ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 64, max: 90)
            TableColumn("CPU time", value: \.timeKey) { r in
                Text(Fmt.secs(r.t.cpuNanos)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80, max: 110)
            TableColumn("User", value: \.userKey) { r in
                Text(Fmt.secs(r.t.userNanos)).monospacedDigit().foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 56, ideal: 72, max: 100)
            TableColumn("System", value: \.systemKey) { r in
                Text(Fmt.secs(r.t.systemNanos)).monospacedDigit().foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 56, ideal: 72, max: 100)
            TableColumn("State", value: \.stateKey) { r in
                Text(r.t.stateText).foregroundStyle(Self.stateColor(r.t.runState))
            }
            .width(min: 50, ideal: 64, max: 110)
            TableColumn("Priority", value: \.priorityKey) { r in
                Text(r.t.curPriority == r.t.basePriority ? "\(r.t.curPriority)" : "\(r.t.curPriority) (base \(r.t.basePriority))")
                    .monospacedDigit()
                    .help("Current \(r.t.curPriority), base \(r.t.basePriority), max \(r.t.maxPriority). Higher runs first; 31 is the default, 46–47 is user-interactive work.")
            }
            .width(min: 44, ideal: 56, max: 110)
            TableColumn("Policy", value: \.policyKey) { r in
                Text(r.t.policyText).foregroundStyle(r.t.policy == 1 ? .secondary : .primary)
                    .help(r.t.policy == 1 ? "Timesharing: the usual policy." : "Fixed-priority policy, as real-time threads (audio, for example) use.")
            }
            .width(min: 60, ideal: 76, max: 110)
        }
        .font(.system(size: 11))
        .contextMenu(forSelectionType: UInt64.self) { ids in
            Button("Copy") { copy(ids) }
        }
        .onCopyCommand { [ids = selection] in [NSItemProvider(object: text(for: ids) as NSString)] }
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
            [String(r.id), r.shownName, r.cpu.map(Fmt.pct) ?? "—", Fmt.secs(r.t.cpuNanos), r.t.stateText,
             "\(r.t.curPriority)", r.t.policyText].joined(separator: "\t")
        }.joined(separator: "\n")
    }

    private func copy(_ ids: Set<UInt64>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(for: ids), forType: .string)
    }
}
