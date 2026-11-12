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
    @AppStorage(ColumnPrefs.key) private var shownColumns = ColumnPrefs.defaultShown
    @State private var search = ""
    @AppStorage("processes.chips") private var savedChips = ""
    private var chips: Set<FilterChip> { FilterChip.parse(savedChips) }
    @State private var selection: ProcNode.ID?
    @AppStorage("processes.sort") private var savedSort = "pid,asc"
    private var sort: Binding<ColumnSort> {
        Binding(get: {
            let parts = savedSort.split(separator: ",")
            guard parts.count == 2, Column.all.contains(where: { $0.id == parts[0] }) else { return .pid }
            return ColumnSort(id: String(parts[0]), ascending: parts[1] == "asc")
        }, set: { savedSort = "\($0.id),\($0.ascending ? "asc" : "desc")" })
    }
    @State private var pendingSignal: (ProcInfo, Int32, String)?
    @State private var signalError: String?
    /// The pane's history. Kept here so hiding the pane doesn't lose it; this view never reads it.
    @State private var paneNav = InspectorNavigation()

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
          VStack(spacing: 0) {
            FilterChipBar(saved: $savedChips)
            Divider()
            ProcessOutline(store: store, grouping: grouping, filter: search, chips: chips,
                           selection: $selection, sort: sort, shownColumns: ColumnPrefs.parse(shownColumns),
                           onOpen: { p in inspect(p) },
                           onSignal: { p, sig, label in
                               // Resume is harmless: send it at once. The rest are confirmed first.
                               if sig == SIGCONT { send(sig, label, to: p) } else { pendingSignal = (p, sig, label) }
                           })
                // A grouping switch re-parents nearly every row; start from a fresh outline (all expanded).
                .id(grouping)
          }
        } bottom: {
            SelectedProcessPane(selection: $selection, nav: paneNav, grouping: grouping, filter: search, chips: chips,
                                sort: sort.wrappedValue,
                                columns: ColumnPrefs.parse(shownColumns))
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
                        ForEach(Grouping.trees) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Menu("Group Flat List By") {
                        Picker("Group flat list by", selection: $grouping) {
                            ForEach(Grouping.pivots) { Text($0.pivotTitle).tag($0) }
                        }
                        .pickerStyle(.inline).labelsHidden()
                    }
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
    @Binding var selection: ProcNode.ID?
    let nav: InspectorNavigation
    var grouping: Grouping
    var filter: String
    var chips: Set<FilterChip> = []
    var sort: ColumnSort
    var columns: Set<String>

    /// The selected process row's process, by key: a pid reused under a still-selected row is another
    /// process. Group rows (an app's row included) have their own inspector and don't go into the history.
    private var selectedProc: ProcInfo? {
        selection.flatMap { $0 >= 0 ? store.procs[pid_t(clamping: $0)] : nil }
    }

    /// Following a link selects its process in the tree. A row the search hides can't be selected, so the
    /// tree's selection clears; the pane keeps showing the process.
    private var links: InspectorLinks {
        InspectorLinks(nav: nav) { [$selection, store] p in
            // Back to a process that has exited: select nothing, not whatever reused its pid (which
            // would push that process and drop the forward history).
            $selection.wrappedValue = store.live(p) != nil ? Int(p.pid) : nil
        }
    }

    var body: some View {
        Group {
            // Reading store.procs makes the summary follow each refresh.
            if let id = selection, id < 0, !store.procs.isEmpty,
               let n = Self.find(id, in: store.nodes(grouping: grouping, filter: filter, chips: chips, sort: sort, columns: columns)) {
                GroupInspectorView(node: n).environment(\.inspectorLinks, links)
            } else if selection.map({ $0 < 0 }) == true {
                placeholder("This group isn't in the list any more.")
            } else {
                // Nothing selected (deselected, or the row went away when its process exited): keep
                // showing the last process, as a browser keeps its page.
                InspectorHost(links: links) { placeholder("Select a process") }
            }
        }
        // Selecting a row in the tree is a navigation: it goes into the history.
        .onChange(of: selectedProc?.key, initial: true) { _, _ in
            if let p = selectedProc { nav.push(p) }
        }
    }

    private func placeholder(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func find(_ id: Int, in nodes: [ProcNode]) -> ProcNode? {
        for n in nodes {
            if n.id == id { return n }
            if let c = n.children, let hit = find(id, in: c) { return hit }
        }
        return nil
    }
}

/// Identifies one process instance for a property window: a pid alone could be reused by a later process.
struct ProcessRef: Codable, Hashable {
    var pid: pid_t
    var start: TimeInterval
    init(_ p: ProcInfo) { pid = p.pid; start = p.start.timeIntervalSince1970 }
    init(pid: pid_t, start: TimeInterval) { self.pid = pid; self.start = start }
}

/// Property sheet for one process, opened by double-clicking (or Return on) a row.
/// Links followed inside it show their process in the same window, with back and forward; ⌘-click opens another.
struct ProcessWindow: View {
    static let id = "process"
    @Environment(Store.self) var store
    /// The window's scene value. It follows the process shown, so opening that process again brings this
    /// window forward, and a restored window comes back on it.
    @Binding var ref: ProcessRef?
    @State private var nav = InspectorNavigation()

    var body: some View {
        let ref = self.ref ?? ProcessRef(pid: -1, start: 0)
        InspectorHost(links: InspectorLinks(nav: nav)) {
            Text(verbatim: "pid \(ref.pid) is not running").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(Text(verbatim: nav.current.map { "\($0.proc.name) (\($0.proc.pid))" } ?? "pid \(ref.pid)"))
        // At launch a restored window can appear before the first process snapshot: wait for it.
        .onChange(of: store.procs[ref.pid]?.start, initial: true) { _, _ in
            if nav.current == nil, let p = store.procs[ref.pid], p.start.timeIntervalSince1970 == ref.start { nav.push(p) }
        }
        .onChange(of: nav.current?.proc.key) { _, _ in
            if let p = nav.current?.proc { self.ref = ProcessRef(p) }
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}

/// The quick filters above the tree. Reads per-refresh data for its counts, so it re-renders on each tick
/// by itself rather than making ProcessesView do so (see the note there).
struct FilterChipBar: View {
    @Environment(Store.self) var store
    @Binding var saved: String

    var body: some View {
        let on = FilterChip.parse(saved)
        let now = Date()
        let procs = Array(store.procs.values)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(FilterChip.allCases) { c in
                    let active = on.contains(c)
                    let count = procs.reduce(0) { $0 + (c.matches($1, now: now) ? 1 : 0) }
                    Button {
                        var s = on
                        if active { s.remove(c) } else { s.insert(c) }
                        saved = FilterChip.encode(s)
                    } label: {
                        HStack(spacing: 4) {
                            Text(c.title)
                            Text(verbatim: "\(count)").monospacedDigit().foregroundStyle(active ? Color.white.opacity(0.85) : .secondary)
                        }
                        .font(.system(size: 11))
                        .padding(.horizontal, 8).frame(height: 20)
                        .foregroundStyle(active ? Color.white : Color.primary)
                        .background(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.12)), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(c.help + " Chips combine: a process must pass every chip that is on.")
                    .accessibilityAddTraits(active ? .isSelected : [])
                    .accessibilityValue("\(count) processes")
                }
                if !on.isEmpty { Button("Clear") { saved = "" }.controlSize(.small) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 30)
    }
}
