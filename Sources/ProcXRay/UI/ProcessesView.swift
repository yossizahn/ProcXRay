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

enum SortKeepsGroups { static let key = "processes.sortKeepsGroups" }

struct ProcessesView: View {
    @Environment(Store.self) var store
    @Environment(\.openWindow) private var openWindow
    /// A value saved by an older version (a grouping since removed) reads as Smart.
    @AppStorage("grouping") private var grouping: Grouping = .smart
    @AppStorage(InspectorPaneKey.name) private var showPane = false
    @AppStorage(ColumnPrefs.key) private var shownColumns = ColumnPrefs.defaultShown
    @State private var search = ""
    /// Chips saved by an older version, moved into the predicate once.
    @AppStorage("processes.chips") private var oldChips = ""
    /// The filter predicate in force (only ever one that parses; see PredicateBar).
    @AppStorage("processes.predicate") private var predicate = ""
    /// Saved predicates, shown as chips (SavedPredicate.encode).
    @AppStorage(SavedPredicate.key) private var savedPredicates = ""
    /// The predicate row was opened with its button. It also shows, whatever this says, while a predicate is on.
    @State private var predicateOpen = false
    @State private var selection: ProcNode.ID?
    /// The column sort, or "" for none. As in Process Hacker: with no column sort the list shows the chosen
    /// grouping in its natural order; sorting by a column shows the flat list sorted by it. Clicking a header
    /// cycles descending → ascending → none. (A new key: the old one defaulted to "pid,asc", which would now
    /// mean a flat list.)
    @AppStorage("processes.columnSort") private var savedSort = ""
    private var sort: Binding<ColumnSort?> {
        Binding(get: {
            let parts = savedSort.split(separator: ",")
            guard parts.count == 2, Column.all.contains(where: { $0.id == parts[0] }) else { return nil }
            return ColumnSort(id: String(parts[0]), ascending: parts[1] == "asc")
        }, set: { savedSort = $0.map { "\($0.id),\($0.ascending ? "asc" : "desc")" } ?? "" })
    }
    /// View ▸ Keep Groups When Sorting: a column sort orders the rows inside each group instead of
    /// switching to the flat list (ranks apps by their summed memory).
    @AppStorage(SortKeepsGroups.key) private var sortKeepsGroups = false
    /// What the list shows: the chosen grouping, or the flat list while a column sort is on (unless
    /// sorting keeps the groups).
    private var shownGrouping: Grouping { sort.wrappedValue == nil || sortKeepsGroups ? grouping : .flat }
    /// Picking a grouping clears the column sort, so the grouping is what you see.
    private var groupingChoice: Binding<Grouping> {
        Binding(get: { shownGrouping }, set: { grouping = $0; savedSort = "" })
    }
    @State private var pendingSignal: (ProcInfo, Int32, String)?
    @State private var signalError: String?
    /// The pane's history. Kept here so hiding the pane doesn't lose it; this view never reads it.
    @State private var paneNav = InspectorNavigation()

    // This body must not read per-refresh data (store.procs, nodes): then it would re-render every tick,
    // and each re-render pushes SwiftUI's environment through every cell view of the outline. The outline
    // observes the store itself. The selected process is looked up only when an action runs.
    /// A process row's pid. Group rows (negative ids), an app's unit row included, have none.
    private var selectedPid: pid_t? { selection.flatMap { $0 >= 0 ? pid_t(clamping: $0) : nil } }
    private var hasProcessSelected: Bool { selectedPid != nil }
    private func inspectSelected() {
        if let pid = selectedPid, let p = store.procs[pid] { inspect(p) }
    }

    private func inspect(_ p: ProcInfo) { openWindow(id: ProcessWindow.id, value: ProcessRef(p)) }

    var body: some View {
        SplitPane(id: "processes", defaultFraction: 0.6, showsBottom: showPane) {
          VStack(spacing: 0) {
            FilterChipBar(predicate: $predicate, predicateOpen: $predicateOpen,
                          savedPredicates: $savedPredicates)
            if predicateOpen || !predicate.isEmpty {
                PredicateBar(applied: $predicate, open: $predicateOpen, saved: $savedPredicates)
            }
            Divider()
            ProcessOutline(store: store, grouping: shownGrouping, filter: search, predicate: predicate,
                           selection: $selection, sort: sort, shownColumns: ColumnPrefs.parse(shownColumns),
                           onOpen: { p in inspect(p) },
                           onSignal: { p, sig, label in
                               // Resume is harmless: send it at once. The rest are confirmed first.
                               if sig == SIGCONT { send(sig, label, to: p) } else { pendingSignal = (p, sig, label) }
                           })
                // Tree ↔ flat re-parents nearly every row; start from a fresh outline (all expanded).
                .id(shownGrouping)
          }
        } bottom: {
            SelectedProcessPane(selection: $selection, nav: paneNav, grouping: shownGrouping, filter: search,
                                predicate: predicate, sort: sort.wrappedValue ?? .pid,
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
                // A pull-down menu with an inline picker, not a pop-up picker: the pop-up wrote the value it
                // was showing back through the binding when a column sort switched the list to flat,
                // which saved Flat as the grouping.
                Menu {
                    Picker("Group", selection: groupingChoice) {
                        ForEach(Grouping.trees) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Menu("Group Flat List By") {
                        Picker("Group flat list by", selection: groupingChoice) {
                            ForEach(Grouping.pivots) { Text($0.pivotTitle).tag($0) }
                        }
                        .pickerStyle(.inline).labelsHidden()
                    }
                } label: {
                    Label(shownGrouping.label, systemImage: "list.bullet.indent").labelStyle(.titleAndIcon)
                }
                .fixedSize()
                .help(sortKeepsGroups
                      ? "Smart tree, flat list, or the flat list grouped by one field. Clicking a column header sorts the rows inside each group."
                      : "Smart tree, flat list, or the flat list grouped by one field. Clicking a column header shows the flat list sorted by it; a third click comes back here. View ▸ Keep Groups When Sorting sorts inside the groups instead.")
                Button { WindowPicker.start { AppRouter.shared.show($0) } } label: { Label("Pick Window", systemImage: "scope") }
                    .help("Click any window on screen to select the process that owns it (⌥⌘P)")
                Button { store.paused.toggle() } label: {
                    Label(store.paused ? "Resume" : "Pause", systemImage: store.paused ? "play.fill" : "pause.fill")
                }
                Button { store.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        }
        .navigationTitle("Processes")
        .onAppear {
            guard !oldChips.isEmpty else { return }
            let old = FilterChip.migrate(oldChips)
            if !old.isEmpty { predicate = predicate.isEmpty ? old : PredicateCompiler.toggling(old, in: predicate) }
            oldChips = ""
        }
        .onChange(of: AppRouter.shared.reveal, initial: true) { _, r in if let r { reveal(r.pid, tries: 4) } }
        .confirmationDialog(pendingSignal.map { "Send \($0.2) to \($0.0.name) (pid \($0.0.pid))?" } ?? "",
                            isPresented: Binding(get: { pendingSignal != nil }, set: { if !$0 { pendingSignal = nil } })) {
            Button(pendingSignal?.2 ?? "Send", role: .destructive) {
                if let (p, sig, label) = pendingSignal { send(sig, label, to: p) }
                pendingSignal = nil
            }
        }
        .signalFailureAlert($signalError)
    }

    /// Selects `pid` in the tree (the outline expands its group and scrolls to it). A process newer than the
    /// last snapshot isn't listed yet: refresh, and try again shortly.
    private func reveal(_ pid: pid_t, tries: Int) {
        if store.procs[pid] != nil {
            if !search.isEmpty || !predicate.isEmpty {   // never hide the target
                search = ""; predicate = ""
            }
            selection = Int(pid)
            return
        }
        guard tries > 0 else { return }
        store.refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { reveal(pid, tries: tries - 1) }
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
    var predicate: String = ""
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
               let n = Self.find(id, in: store.nodes(grouping: grouping, filter: filter, predicate: predicate, sort: sort, columns: columns)) {
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

/// The quick filters above the tree: presets that add their clause to the predicate or take it out, then the
/// saved filters, then the button that opens the predicate row. Reads per-refresh data for its counts, so it
/// re-renders on each tick by itself rather than making ProcessesView do so (see the note there).
struct FilterChipBar: View {
    @Environment(Store.self) var store
    @Binding var predicate: String
    @Binding var predicateOpen: Bool
    @Binding var savedPredicates: String

    var body: some View {
        let now = Date()
        let procs = Array(store.procs.values)
        let filters = SavedPredicate.parse(savedPredicates)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(FilterChip.allCases) { c in
                    let count = store.compiledPredicate(c.source).map { p in procs.reduce(0) { $0 + (p.test($1, now) ? 1 : 0) } }
                    chip(c.title, icon: nil, clause: c.source, count: count,
                         help: c.help + " Adds “\(c.source)” to the predicate; chips combine with “and”.")
                }
                if !filters.isEmpty {
                    Divider().frame(height: 14)
                    ForEach(filters) { f in
                        chip(f.name, icon: "bookmark", clause: f.source, count: nil, help: "Saved filter: \(f.source)")
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    savedPredicates = SavedPredicate.encode(filters.filter { $0.id != f.id })
                                }
                            }
                    }
                }
                let on = !predicate.isEmpty
                let open = predicateOpen || on
                // While a predicate is on, the row stays: this does nothing then, and the row's ✕ clears it.
                Button { if !on { predicateOpen.toggle() } } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 11))
                        .frame(width: 28, height: 20)
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .background(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(open ? 0.25 : 0.12)), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(on ? "A predicate is on. Clear it with ✕ in its row."
                         : open ? "Hide the predicate row" : "Filter with an expression, such as cpu > 5 and not sandboxed. Combines with the search.")
                .accessibilityLabel("Predicate filter")
                .accessibilityAddTraits(on ? .isSelected : [])
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 30)
    }

    /// A chip that's on while `clause` is one of the predicate's top-level `and` clauses, however it got there.
    private func chip(_ title: String, icon: String?, clause: String, count: Int?, help: String) -> some View {
        let active = PredicateCompiler.contains(predicate, clause: clause)
        return Button { predicate = PredicateCompiler.toggling(clause, in: predicate) } label: {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon) }
                Text(title)
                if let count {
                    Text(verbatim: "\(count)").monospacedDigit().foregroundStyle(active ? Color.white.opacity(0.85) : .secondary)
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 8).frame(height: 20)
            .foregroundStyle(active ? Color.white : Color.primary)
            .background(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.12)), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityValue(count.map { "\($0) processes" } ?? "")
    }
}
