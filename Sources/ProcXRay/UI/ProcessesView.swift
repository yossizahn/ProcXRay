import AppKit
import SwiftUI

@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]
    static func icon(for p: ProcInfo) -> NSImage? {
        guard let key = p.bundlePath ?? p.path else { return nil }
        if let i = cache[key] { return i }
        let i = NSWorkspace.shared.icon(forFile: key)
        i.size = NSSize(width: 16, height: 16)
        cache[key] = i
        return i
    }
}

struct ProcessesView: View {
    @Environment(Store.self) var store
    @Environment(\.openWindow) private var openWindow
    @AppStorage("grouping") private var grouping: Grouping = .smart
    @AppStorage(InspectorPaneKey.name) private var showPane = false
    @State private var search = ""
    @State private var selection: ProcNode.ID?
    @State private var sort = [KeyPathComparator(\ProcNode.pidKey)]
    @State private var pendingSignal: (ProcInfo, Int32, String)?
    @State private var signalError: String?

    // This body must not read per-refresh data (store.procs, nodes): then it would re-render every tick,
    // and each re-render pushes SwiftUI's environment through every cell view of the outline. The outline
    // observes the store itself. The selected process is looked up only when an action runs.
    /// A process row, or a Smart-tree unit row, which stands for its app's own process.
    private var selectedPid: pid_t? { selection.flatMap(SmartTree.pid(forRow:)) }
    private var hasProcessSelected: Bool { selectedPid != nil }
    private func inspectSelected() {
        if let pid = selectedPid, let p = store.procs[pid] { inspect(p) }
    }

    private func inspect(_ p: ProcInfo) { openWindow(id: ProcessWindow.id, value: ProcessRef(p)) }

    var body: some View {
        SplitPane(id: "processes", defaultFraction: 0.6, showsBottom: showPane) {
            ProcessOutline(store: store, grouping: grouping, filter: search,
                           selection: $selection, sort: $sort,
                           onOpen: { p in inspect(p) },
                           onSignal: { p, sig, label in
                               // Resume is harmless: send it at once. The rest are confirmed first.
                               if sig == SIGCONT { send(sig, label, to: p) } else { pendingSignal = (p, sig, label) }
                           })
                // A grouping switch re-parents nearly every row; start from a fresh outline (all expanded).
                .id(grouping)
        } bottom: {
            SelectedProcessPane(selection: selection, grouping: grouping, filter: search, sort: sort)
        }
        .focusedSceneValue(\.inspectProcess, hasProcessSelected ? { inspectSelected() } : nil)
        .searchable(text: $search, placement: .toolbar, prompt: "name, pid, path, team, bundle, label…")
        .toolbar {
            ToolbarItemGroup {
                Button { inspectSelected() } label: { Label("Inspect", systemImage: "info.circle") }
                    .help("Inspect the selected process in its own window (⌘I)")
                    .disabled(!hasProcessSelected)
                Toggle(isOn: $showPane) { Label("Inspector Pane", systemImage: "rectangle.bottomhalf.inset.filled") }
                    .help(showPane ? "Hide the inspector pane (⌥⌘I)" : "Show the selected process in a pane below the list (⌥⌘I)")
                Menu {
                    Picker("Group", selection: $grouping) {
                        ForEach(Grouping.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(grouping.label, systemImage: "list.bullet.indent").labelStyle(.titleAndIcon)
                }
                .fixedSize()
                Button { store.paused.toggle() } label: {
                    Label(store.paused ? "Resume" : "Pause", systemImage: store.paused ? "play.fill" : "pause.fill")
                }
                Button { store.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        }
        .navigationTitle("Processes")
        .confirmationDialog(pendingSignal.map { "Send \($0.2) to \($0.0.name) (pid \($0.0.pid))?" } ?? "",
                            isPresented: Binding(get: { pendingSignal != nil }, set: { if !$0 { pendingSignal = nil } })) {
            Button(pendingSignal?.2 ?? "Send", role: .destructive) {
                if let (p, sig, label) = pendingSignal { send(sig, label, to: p) }
                pendingSignal = nil
            }
        }
        .signalFailureAlert($signalError)
    }

    private func send(_ sig: Int32, _ label: String, to p: ProcInfo) {
        if let err = store.send(sig, to: p) {
            // Next turn of the run loop: the confirmation dialog is still being dismissed here.
            let msg = "Couldn't send \(label) to \(p.name) (pid \(p.pid)).\n\n\(err)"
            DispatchQueue.main.async { signalError = msg }
        }
        store.refresh()
    }
}

extension View {
    /// Says why a signal wasn't sent; a beep alone left people guessing whether anything happened.
    func signalFailureAlert(_ message: Binding<String?>) -> some View {
        alert("Signal not sent", isPresented: Binding(get: { message.wrappedValue != nil },
                                                     set: { if !$0 { message.wrappedValue = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}

/// The optional pane under the process list. It reads per-refresh data itself, so a tick re-renders
/// only this pane, not ProcessesView (see the note there).
struct SelectedProcessPane: View {
    @Environment(Store.self) var store
    let selection: ProcNode.ID?
    var grouping: Grouping
    var filter: String
    var sort: [KeyPathComparator<ProcNode>]

    var body: some View {
        if let id = selection, let pid = SmartTree.pid(forRow: id), let p = store.procs[pid] {
            InspectorView(proc: p)
        // Reading store.procs makes the summary follow each refresh.
        } else if let id = selection, id < 0, SmartTree.pid(forRow: id) == nil, !store.procs.isEmpty,
                  let n = Self.find(id, in: store.nodes(grouping: grouping, filter: filter, sort: sort)) {
            GroupSummaryView(node: n)
        } else {
            Text(selection.map { $0 < 0 ? "Group row — select a process inside it." : "This process has exited." }
                 ?? "Select a process")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    static func find(_ id: Int, in nodes: [ProcNode]) -> ProcNode? {
        for n in nodes {
            if n.id == id { return n }
            if let c = n.children, let hit = find(id, in: c) { return hit }
        }
        return nil
    }
}

/// What a category or group row holds: counts, totals, and its heaviest processes.
struct GroupSummaryView: View {
    let node: ProcNode

    private var members: [ProcInfo] {
        var out: [ProcInfo] = []
        func walk(_ n: ProcNode) { if let p = n.proc { out.append(p) }; n.children?.forEach(walk) }
        walk(node)
        return out
    }

    var body: some View {
        let ms = members
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(node.title).font(.title3.bold())
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    row("Processes", node.shownCount == node.totalCount ? "\(node.totalCount)"
                                                                        : "\(node.shownCount) of \(node.totalCount) (search)")
                    if node.kind == .category, node.unitCount != node.shownCount { row("Top-level rows", "\(node.unitCount)") }
                    row("CPU", "\(Fmt.pct(node.cpuKey)) %")
                    row("Memory", Fmt.bytes(node.memKey))
                    row("Disk I/O", Fmt.bytes(node.diskKey < 0 ? nil : UInt64(node.diskKey)))
                }
                HStack(alignment: .top, spacing: 24) {
                    top("Top by CPU", ms.sorted { ($0.cpuPercent ?? 0) > ($1.cpuPercent ?? 0) }) { "\(Fmt.pct($0.cpuPercent)) %" }
                    top("Top by memory", ms.sorted { ($0.footprint ?? 0) > ($1.footprint ?? 0) }) { Fmt.bytes($0.footprint) }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(verbatim: v).monospacedDigit().textSelection(.enabled)
        }
    }

    private func top(_ title: String, _ ps: [ProcInfo], _ value: @escaping (ProcInfo) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                ForEach(ps.prefix(5), id: \.key) { p in
                    GridRow {
                        Text(verbatim: p.name).lineLimit(1)
                        Text(verbatim: "\(p.pid)").foregroundStyle(.secondary).monospacedDigit()
                        Text(verbatim: value(p)).monospacedDigit().gridColumnAlignment(.trailing)
                    }
                }
            }
        }
    }
}

/// Identifies one process instance for a property window: a pid alone could be reused by a later process.
struct ProcessRef: Codable, Hashable {
    var pid: pid_t
    var start: TimeInterval
    init(_ p: ProcInfo) { pid = p.pid; start = p.start.timeIntervalSince1970 }
}

/// Property sheet for one process, opened by double-clicking (or Return on) a row.
struct ProcessWindow: View {
    static let id = "process"
    @Environment(Store.self) var store
    let ref: ProcessRef
    @State private var lastSeen: ProcInfo?
    @State private var lastSign: SignInfo?

    var body: some View {
        let live = store.procs[ref.pid].flatMap { $0.start.timeIntervalSince1970 == ref.start ? $0 : nil }
        Group {
            if let p = live ?? lastSeen {
                VStack(spacing: 0) {
                    if live == nil {
                        Text("This process has exited. Showing its last known state.")
                            .font(.callout).frame(maxWidth: .infinity).padding(6)
                            .background(.orange.opacity(0.2))
                    }
                    InspectorView(proc: p, exited: live == nil, lastSign: lastSign)
                }
                .navigationTitle(Text(verbatim: "\(p.name) (\(p.pid))"))
            } else {
                Text(verbatim: "pid \(ref.pid) is not running").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: live, initial: true) { _, p in if let p { lastSeen = p } }
        // The store forgets a process's signature once it exits; keep the last one this window saw.
        .onChange(of: live.map { "\($0.codeKey)|\(store.signInfo(for: $0) != nil)" }, initial: true) { _, _ in
            if let p = live, let s = store.signInfo(for: p) { lastSign = s }
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}
