import AppKit
import SwiftUI

/// The process table, as a plain NSOutlineView.
///
/// SwiftUI's `Table` re-diffed every row on every refresh, hosted a SwiftUI view per cell, measured
/// automatic row heights, and had no way to start expanded or react to a double-click. This view
/// reuses one row object per id, reloads only the visible rows when the tree's shape is unchanged,
/// and uses fixed-height cells.
struct ProcessOutline: NSViewRepresentable {
    let store: Store
    let grouping: Grouping
    let filter: String
    @Binding var selection: ProcNode.ID?
    @Binding var sort: ColumnSort
    /// Column ids shown (ColumnPrefs); shared by every window and View ▸ Columns.
    var shownColumns: Set<String> = ColumnPrefs.parse(ColumnPrefs.defaultShown)
    let onOpen: (ProcInfo) -> Void
    let onSignal: (ProcInfo, Int32, String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = KeyOutlineView()
        outline.headerView = NSTableHeaderView()
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = false
        outline.allowsColumnReordering = true
        outline.allowsColumnResizing = true
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.usesAutomaticRowHeights = false
        outline.rowHeight = 18
        outline.intercellSpacing = NSSize(width: 6, height: 2)
        outline.style = .fullWidth
        outline.autoresizesOutlineColumn = false
        outline.indentationPerLevel = 14
        for c in Column.all {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(c.id))
            col.title = c.title
            col.minWidth = min(c.minWidth, c.width)
            col.width = max(c.width, Column.sortedHeaderWidth(col))
            col.headerCell.alignment = c.numeric ? .right : .left
            col.headerToolTip = c.tooltip
            if c.id != "context" {
                col.sortDescriptorPrototype = NSSortDescriptor(key: c.id, ascending: true)
            }
            // Before the autosave is read: a column it doesn't know (new in this version) stays hidden.
            col.isHidden = !Column.defaultShown.contains(c.id)
            outline.addTableColumn(col)
            if c.id == "name" { outline.outlineTableColumn = col }
        }
        outline.autosaveName = "ProcessOutline.columns"
        outline.autosaveTableColumns = true

        let co = context.coordinator
        co.outline = outline
        co.parent = self
        co.observeStore()
        outline.dataSource = co
        outline.delegate = co
        outline.target = co
        outline.doubleAction = #selector(Coordinator.openClicked)
        outline.onReturn = { [weak co] in co?.openSelected() }
        let menu = NSMenu()
        menu.delegate = co
        outline.menu = menu
        let headerMenu = NSMenu()
        headerMenu.delegate = co
        outline.headerView?.menu = headerMenu
        co.headerMenu = headerMenu
        co.listenForColumnCommands()

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let co = context.coordinator
        co.parent = self
        co.apply()
    }

    // MARK: Coordinator

    final class Item: NSObject {
        let id: Int
        var node: ProcNode
        var children: [Item] = []   // target, from the latest tree
        var shown: [Item] = []      // what the outline currently displays; the data source reads this
        init(_ node: ProcNode) { id = node.id; self.node = node }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var parent: ProcessOutline!
        weak var outline: NSOutlineView?
        private var roots: [Item] = []
        private var byID: [Int: Item] = [:]
        private var appliedVersion = -1
        private var procs: [pid_t: ProcInfo] = [:]

        /// Re-apply whenever the store's process data changes, without going through SwiftUI.
        /// withObservationTracking fires once, before the change, so re-register and read after it lands.
        var headerMenu: NSMenu?
        private var shownApplied: Set<String>?
        /// The header column a column shown from the header menu goes next to.
        private var showNextTo: String?
        private var commandObservers: [NSObjectProtocol] = []

        /// View ▸ Columns acts on the outline in the key window (several main windows can be open).
        func listenForColumnCommands() {
            let nc = NotificationCenter.default
            commandObservers = [
                nc.addObserver(forName: ColumnPrefs.sizeAllToFit, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { if let self, self.isInKeyWindow { self.sizeAllToFit() } }
                },
                nc.addObserver(forName: ColumnPrefs.reset, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { if let self, self.isInKeyWindow { self.resetColumns() } }
                },
            ]
        }
        deinit { commandObservers.forEach(NotificationCenter.default.removeObserver) }

        private var isInKeyWindow: Bool {
            guard let w = outline?.window else { return false }
            return w == (NSApp.keyWindow ?? NSApp.mainWindow)
        }

        private func syncShown(_ outline: NSOutlineView) {
            let shown = parent.shownColumns
            guard shown != shownApplied else { return }
            let first = shownApplied == nil
            shownApplied = shown
            for col in outline.tableColumns {
                let id = col.identifier.rawValue
                let hide = id != "name" && !shown.contains(id)
                guard col.isHidden != hide else { continue }
                col.isHidden = hide
                // A column just switched on goes next to the header column it was picked from, or after
                // the last shown one, not wherever it sat in the catalogue.
                if !hide, !first { place(col, in: outline) }
            }
            showNextTo = nil
            // Sorting by a column nobody can see: back to the default (PID).
            // Next turn: this runs inside a SwiftUI update, which mustn't change state.
            if parent.sort.id != "name", !shown.contains(parent.sort.id) {
                DispatchQueue.main.async { [weak self] in self?.parent.sort = .pid }
            }
        }

        private func place(_ col: NSTableColumn, in o: NSOutlineView) {
            guard let from = o.tableColumns.firstIndex(of: col) else { return }
            // After the column it was picked from. Otherwise just before Context, a wide trailing summary
            // that would push it out of sight, or after the last shown column.
            let to: Int
            if let id = showNextTo, case let a = o.column(withIdentifier: NSUserInterfaceItemIdentifier(id)), a >= 0 {
                to = from < a ? a : a + 1
            } else if let c = o.tableColumns.firstIndex(where: { $0.identifier.rawValue == "context" && !$0.isHidden }) {
                to = from < c ? c - 1 : c
            } else if let a = o.tableColumns.lastIndex(where: { !$0.isHidden && $0 !== col }) {
                to = from < a ? a : a + 1
            } else { return }
            if to != from { o.moveColumn(from, toColumn: to) }
        }

        // MARK: Column sizing

        /// Width that shows `col`'s header and every visible cell in it untruncated.
        private func fittingWidth(_ col: NSTableColumn) -> CGFloat {
            guard let o = outline, let c = Column.byID[col.identifier.rawValue] else { return col.width }
            let ci = o.column(withIdentifier: col.identifier)
            var w = Column.sortedHeaderWidth(col)
            let rows = o.rows(in: o.visibleRect)
            guard ci >= 0, rows.length > 0 else { return max(col.minWidth, w) }
            let probe = Cell(column: c)
            for r in rows.location..<rows.location + rows.length {
                guard let it = o.item(atRow: r) as? Item else { continue }
                probe.show(it.node, column: c, store: parent.store)
                // The outline column's cells start after the row's indentation and disclosure triangle.
                let inset = o.frameOfCell(atColumn: ci, row: r).minX - o.rect(ofColumn: ci).minX
                w = max(w, inset + probe.fittingWidth)
            }
            return max(col.minWidth, min(w, 1200))
        }

        func outlineView(_ o: NSOutlineView, sizeToFitWidthOfColumn ci: Int) -> CGFloat {
            fittingWidth(o.tableColumns[ci])
        }

        private func sizeToFit(_ col: NSTableColumn) { col.width = fittingWidth(col) }
        func sizeAllToFit() { outline?.tableColumns.filter { !$0.isHidden }.forEach(sizeToFit) }

        /// Catalogue order, default widths, default visibility.
        func resetColumns() {
            guard let o = outline else { return }
            // Shown columns first, in the default order, then the rest of the catalogue.
            let order = Column.defaultShown + Column.all.map(\.id).filter { !Column.defaultShown.contains($0) }
            for (i, id) in order.enumerated() {
                let at = o.column(withIdentifier: NSUserInterfaceItemIdentifier(id))
                guard at >= 0, let c = Column.byID[id] else { continue }
                if at != i { o.moveColumn(at, toColumn: i) }
                o.tableColumns[i].width = max(c.width, Column.sortedHeaderWidth(o.tableColumns[i]))
            }
            shownApplied = nil   // re-apply visibility without moving anything
            ColumnPrefs.setShown(Set(Column.defaultShown))
        }

        private func buildHeaderMenu(_ menu: NSMenu) {
            guard let o = outline, let header = o.headerView else { return }
            func item(_ title: String, state: Bool? = nil, in m: NSMenu? = nil, _ action: @escaping () -> Void) {
                let mi = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
                let a = MenuAction(action)
                mi.target = a
                mi.representedObject = a
                if let state { mi.state = state ? .on : .off }
                (m ?? menu).addItem(mi)
            }
            // The column under the pointer when the menu opened.
            var clicked: NSTableColumn?
            if let e = NSApp.currentEvent, e.window == header.window {
                let ci = header.column(at: header.convert(e.locationInWindow, from: nil))
                if ci >= 0 { clicked = o.tableColumns[ci] }
            }
            if let col = clicked {
                if col.identifier.rawValue != "name" {
                    let id = col.identifier.rawValue
                    item("Hide \(col.title)") { ColumnPrefs.toggle(id) }
                }
                item("Size Column to Fit") { [weak self] in self?.sizeToFit(col) }
            }
            item("Size All Columns to Fit") { [weak self] in self?.sizeAllToFit() }
            menu.addItem(.separator())
            // The shown columns, in table order, for one-click hiding; then the whole catalogue by section.
            let shown = parent.shownColumns
            let anchor = clicked?.identifier.rawValue
            for col in o.tableColumns where !col.isHidden && col.identifier.rawValue != "name" {
                let id = col.identifier.rawValue
                item(col.title, state: true) { ColumnPrefs.toggle(id) }
            }
            menu.addItem(.separator())
            for section in Column.Section.allCases {
                let sub = NSMenu(title: section.title)
                for c in Column.all where c.section == section && c.id != "name" {
                    item(c.title, state: shown.contains(c.id), in: sub) { [weak self] in
                        self?.showNextTo = anchor
                        ColumnPrefs.toggle(c.id)
                    }
                }
                let mi = NSMenuItem(title: section.title, action: nil, keyEquivalent: "")
                mi.submenu = sub
                menu.addItem(mi)
            }
            menu.addItem(.separator())
            item("Reset Columns") { [weak self] in self?.resetColumns() }
        }

        func observeStore() {
            guard let store = parent?.store else { return }
            withObservationTracking {
                _ = store.procs
                _ = store.lsApps
            } onChange: { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.apply()
                    self.observeStore()
                }
            }
        }
        private var collapsed: Set<Int> = []    // rows the user collapsed; everything else starts expanded
        /// Rows that start collapsed (ProcNode.startsCollapsed) and the user hasn't opened or closed
        /// yet. They stay shut unless a search is active; `seeded` keeps them from being re-added.
        private var defaultCollapsed: Set<Int> = []
        private var seeded: Set<Int> = []
        private var appliedFilter = ""
        private var updating = false
        private var pushedSort: ColumnSort?

        private var shownRoots: [Item] = []
        private var loaded = false

        func apply() {
            guard let outline else { return }
            updating = true
            defer { updating = false }
            syncSortIndicators(outline)
            syncShown(outline)
            let nodes = parent.store.nodes(grouping: parent.grouping, filter: parent.filter, sort: parent.sort,
                                           columns: parent.shownColumns)
            procs = parent.store.procs
            if parent.store.nodesVersion != appliedVersion {
                appliedVersion = parent.store.nodesVersion
                var seen: [Int: Item] = [:]
                func build(_ n: ProcNode) -> Item {
                    let it = byID[n.id] ?? Item(n)
                    it.node = n
                    seen[n.id] = it
                    if n.startsCollapsed, seeded.insert(n.id).inserted { defaultCollapsed.insert(n.id) }
                    it.children = (n.children ?? []).map(build)
                    return it
                }
                roots = nodes.map(build)
                byID = seen
                if !loaded {
                    loaded = true
                    func adopt(_ items: [Item]) { for it in items { it.shown = it.children; adopt(it.children) } }
                    adopt(roots)
                    shownRoots = roots
                    outline.reloadData()
                    expand(roots, in: outline)
                } else {
                    sync(outline)
                }
            }
            if parent.filter != appliedFilter {
                let wasEmpty = appliedFilter.isEmpty
                appliedFilter = parent.filter
                // A search opens every group that has a match; clearing it shuts the default-collapsed
                // ones again, unless the user has touched them since.
                if parent.filter.isEmpty {
                    for id in defaultCollapsed { if let it = byID[id] { outline.collapseItem(it) } }
                } else if wasEmpty {
                    expand(shownRoots, in: outline)
                }
            }
            syncSelection(outline)
        }

        /// Brings the displayed tree to the target tree with per-parent removes, inserts and moves, then
        /// refreshes the values of the visible cells in place. No reloadData: existing cell views and
        /// expansion state survive, and only rows that actually changed position are touched.
        private func sync(_ outline: NSOutlineView) {
            // Keep the row at the top of the viewport where it is while rows come and go above it.
            let topRow = outline.row(at: NSPoint(x: 0, y: outline.visibleRect.minY + 1))
            let anchor = topRow >= 0 ? outline.item(atRow: topRow) as? Item : nil
            let anchorOffset = anchor == nil ? 0 : outline.rect(ofRow: topRow).minY - outline.visibleRect.minY

            var inserted: [Item] = []
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            outline.beginUpdates()
            // The outline calls back into the data source synchronously (e.g. from reloadItem), so the
            // displayed arrays are only ever touched in short, separate accesses: never held inout across
            // an outline call, which would be a Swift exclusivity violation (abort).
            func shown(_ p: Item?) -> [Item] { p?.shown ?? shownRoots }
            func edit(_ p: Item?, _ f: (inout [Item]) -> Void) {
                if let p { f(&p.shown) } else { f(&shownRoots) }
            }
            // Pass 1: removals everywhere first, so an item that changed parent is gone from its old
            // parent before it is inserted under the new one.
            func remove(_ p: Item?, target: [Item]) {
                let keep = Set(target.map(ObjectIdentifier.init))
                for i in shown(p).indices.reversed() where !keep.contains(ObjectIdentifier(shown(p)[i])) {
                    edit(p) { $0.remove(at: i) }
                    outline.removeItems(at: IndexSet(integer: i), inParent: p, withAnimation: [])
                }
                for c in shown(p) { remove(c, target: c.children) }
            }
            remove(nil, target: roots)
            // Pass 2: inserts and moves, top-down.
            var insertedIDs = Set<ObjectIdentifier>()
            func place(_ p: Item?, target: [Item]) {
                for (i, t) in target.enumerated() {
                    let cur = shown(p)
                    if i < cur.count, cur[i] === t { continue }
                    if let j = cur.firstIndex(where: { $0 === t }) {
                        edit(p) { $0.remove(at: j); $0.insert(t, at: i) }
                        outline.moveItem(at: j, inParent: p, to: i, inParent: p)
                    } else {
                        func adopt(_ it: Item) { it.shown = it.children; it.children.forEach(adopt) }
                        adopt(t)
                        edit(p) { $0.insert(t, at: i) }
                        outline.insertItems(at: IndexSet(integer: i), inParent: p, withAnimation: [])
                        inserted.append(t)
                        insertedIDs.insert(ObjectIdentifier(t))
                    }
                }
                for c in target where !insertedIDs.contains(ObjectIdentifier(c)) {
                    let wasLeaf = c.shown.isEmpty
                    place(c, target: c.children)
                    if wasLeaf != c.shown.isEmpty { outline.reloadItem(c, reloadChildren: false) }
                    if wasLeaf, !c.shown.isEmpty { inserted.append(c) }   // newly a parent: expand it
                }
            }
            place(nil, target: roots)
            outline.endUpdates()
            NSAnimationContext.endGrouping()
            expand(inserted, in: outline)

            if let anchor, let clip = outline.enclosingScrollView?.contentView, case let row = outline.row(forItem: anchor), row >= 0 {
                let y = outline.rect(ofRow: row).minY - anchorOffset
                if abs(y - clip.bounds.minY) > 0.5 {
                    clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(y, -clip.contentInsets.top)))
                    outline.enclosingScrollView?.reflectScrolledClipView(clip)
                }
            }

            // Values: update the visible cells in place.
            let visible = outline.rows(in: outline.visibleRect)
            guard visible.length > 0 else { return }
            for row in visible.location..<visible.location + visible.length {
                guard let it = outline.item(atRow: row) as? Item else { continue }
                for col in 0..<outline.numberOfColumns {
                    if let cell = outline.view(atColumn: col, row: row, makeIfNecessary: false) as? Cell,
                       let c = Column.byID[outline.tableColumns[col].identifier.rawValue] {
                        cell.show(it.node, column: c, store: parent.store)
                    }
                }
            }
        }

        /// Expands the given items and their descendants, except ones the user collapsed.
        private func expand(_ items: [Item], in outline: NSOutlineView) {
            for it in items where !it.shown.isEmpty {
                if collapsed.contains(it.id) { continue }
                if parent.filter.isEmpty, defaultCollapsed.contains(it.id) { continue }
                outline.expandItem(it)
                expand(it.shown, in: outline)
            }
        }

        private func syncSelection(_ outline: NSOutlineView) {
            let current = outline.selectedRow >= 0 ? (outline.item(atRow: outline.selectedRow) as? Item)?.id : nil
            guard current != parent.selection else { return }
            if let id = parent.selection, let it = byID[id] {
                // Programmatic jumps (Select Parent / Responsible, inspector links) may target a row inside
                // a collapsed group. The outline doesn't know the parents of rows it hasn't loaded, so the
                // path comes from the displayed tree.
                for x in Self.path(to: it, in: shownRoots) {
                    collapsed.remove(x.id); defaultCollapsed.remove(x.id); outline.expandItem(x)
                }
                let row = outline.row(forItem: it)
                if row >= 0 {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    outline.scrollRowToVisible(row)
                } else {
                    outline.deselectAll(nil)   // never leave another row highlighted
                }
            } else {
                // Nothing selected, or a target this outline doesn't show: never leave another row
                // highlighted, or Inspect and Return would act on different processes.
                outline.deselectAll(nil)
                // A target the search hides (or that exited) isn't selected any more either: otherwise the
                // toolbar's Inspect and the inspector pane would act on a row nobody can see.
                if let id = parent.selection {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.parent.selection == id, self.byID[id] == nil else { return }
                        self.parent.selection = nil
                    }
                }
            }
        }

        /// The displayed ancestors of `target`, outermost first; empty when it's a root or not shown.
        private static func path(to target: Item, in items: [Item]) -> [Item] {
            for it in items {
                if it.shown.contains(where: { $0 === target }) { return [it] }
                let sub = path(to: target, in: it.shown)
                if !sub.isEmpty { return [it] + sub }
            }
            return []
        }

        private func syncSortIndicators(_ outline: NSOutlineView) {
            guard parent.sort != pushedSort else { return }
            pushedSort = parent.sort
            outline.sortDescriptors = [NSSortDescriptor(key: parent.sort.id, ascending: parent.sort.ascending)]
        }

        // MARK: Data source

        func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? Item)?.shown.count ?? shownRoots.count
        }
        func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? Item)?.shown[index] ?? shownRoots[index]
        }
        func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool {
            !((item as? Item)?.shown.isEmpty ?? true)
        }

        func outlineView(_ o: NSOutlineView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
            guard !updating else { return }
            guard let d = o.sortDescriptors.first, let key = d.key, Column.byID[key] != nil else { return }
            let new = ColumnSort(id: key, ascending: d.ascending)
            pushedSort = new
            parent.sort = new
        }

        // MARK: Delegate

        func outlineViewItemDidCollapse(_ n: Notification) {
            if !updating, let it = n.userInfo?["NSObject"] as? Item { collapsed.insert(it.id); defaultCollapsed.remove(it.id) }
        }
        func outlineViewItemDidExpand(_ n: Notification) {
            if !updating, let it = n.userInfo?["NSObject"] as? Item { collapsed.remove(it.id); defaultCollapsed.remove(it.id) }
        }

        func outlineViewSelectionDidChange(_ n: Notification) {
            guard !updating, let o = outline else { return }
            let id = o.selectedRow >= 0 ? (o.item(atRow: o.selectedRow) as? Item)?.id : nil
            if id != parent.selection { parent.selection = id }
        }

        func outlineView(_ o: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
            guard let col, let c = Column.byID[col.identifier.rawValue], let it = item as? Item else { return nil }
            let cell = (o.makeView(withIdentifier: col.identifier, owner: nil) as? Cell) ?? Cell(column: c)
            cell.show(it.node, column: c, store: parent.store)
            return cell
        }

        // MARK: Actions

        @objc func openClicked() {
            guard let o = outline, o.clickedRow >= 0 else { return }
            open(o.item(atRow: o.clickedRow) as? Item)
        }

        func openSelected() {
            guard let o = outline, o.selectedRow >= 0 else { return }
            open(o.item(atRow: o.selectedRow) as? Item)
        }

        private func open(_ it: Item?) {
            guard let it, let o = outline else { return }
            if let p = it.node.proc ?? it.node.rootPid.flatMap({ procs[$0] }) { parent.onOpen(p); return }
            // Group rows toggle, like a disclosure triangle.
            if o.isItemExpanded(it) { o.collapseItem(it) } else { o.expandItem(it) }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            if menu === headerMenu { buildHeaderMenu(menu); return }
            // A unit row (Smart tree) acts as the app or job it stands for.
            guard let o = outline, o.clickedRow >= 0, let n = (o.item(atRow: o.clickedRow) as? Item)?.node,
                  let p = n.proc ?? n.rootPid.flatMap({ procs[$0] }) else { return }
            let parent = self.parent!
            func add(_ title: String, _ action: @escaping () -> Void) {
                let mi = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
                let a = MenuAction(action)
                mi.target = a
                mi.representedObject = a    // keeps the target alive while the menu is up
                menu.addItem(mi)
            }
            add("Properties") { parent.onOpen(p) }
            menu.addItem(.separator())
            // No signals for kernel_task (pid 0): kill(0, …) would hit ProcXRay's own process group.
            if p.pid > 0 {
                add("Terminate (SIGTERM)") { parent.onSignal(p, SIGTERM, "SIGTERM") }
                add("Kill (SIGKILL)") { parent.onSignal(p, SIGKILL, "SIGKILL") }
                add("Suspend (SIGSTOP)") { parent.onSignal(p, SIGSTOP, "SIGSTOP") }
                add("Resume (SIGCONT)") { parent.onSignal(p, SIGCONT, "SIGCONT") }   // sent without asking
                menu.addItem(.separator())
            }
            if let path = p.path {
                add("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                add("Copy Path") { Self.copy(path) }
            }
            add("Copy PID") { Self.copy("\(p.pid)") }
            // Only jump to rows the outline shows; a search may hide the target.
            func jump(_ title: String, to pid: pid_t) {
                if byID[Int(pid)] != nil { add(title) { parent.selection = Int(pid) }; return }
                let mi = NSMenuItem(title: title + " — hidden by the search", action: nil, keyEquivalent: "")
                mi.isEnabled = false
                menu.addItem(mi)
            }
            if let r = p.responsible, r != p.pid, procs[r] != nil { jump("Select Responsible (\(r))", to: r) }
            if p.ppid > 1 { jump("Select Parent (\(p.ppid))", to: p.ppid) }
        }

        static func copy(_ s: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        }
    }

    final class MenuAction: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }

    /// Return opens the selected process, like a double-click.
    final class KeyOutlineView: NSOutlineView {
        var onReturn: (() -> Void)?
        override func keyDown(with e: NSEvent) {
            if e.keyCode == 36 || e.keyCode == 76 { onReturn?() } else { super.keyDown(with: e) }
        }
    }

    // MARK: Cells

    final class Cell: NSTableCellView {
        private let label = NSTextField(labelWithString: "")
        private let icon = NSImageView()
        private static let mono = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        private static let body = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        private static let bold = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        private static let semibold = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        private static let ghostIcon = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        private static let groupIcon = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)
        private static let terminalIcon = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        /// Attributed strings carry their own paragraph style, which overrides the field's lineBreakMode.
        private static let truncating: NSParagraphStyle = {
            let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail; return p
        }()

        init(column c: Column) {
            super.init(frame: .zero)
            identifier = NSUserInterfaceItemIdentifier(c.id)
            label.lineBreakMode = c.truncateMiddle ? .byTruncatingMiddle : .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.usesSingleLineMode = true
            label.cell?.truncatesLastVisibleLine = true
            label.alignment = c.numeric ? .right : .left
            label.font = c.numeric ? Self.mono : Self.body
            addSubview(label)
            textField = label
            hasIcon = c.id == "name"
            if hasIcon {
                icon.imageScaling = .scaleProportionallyDown
                addSubview(icon)
                imageView = icon
            }
        }
        required init?(coder: NSCoder) { fatalError() }

        // Frame layout, no constraints: with Auto Layout every value change re-ran the window's layout pass.
        private var hasIcon = false
        override func layout() {
            super.layout()
            let h = bounds.height, lh = ceil(Self.body.ascender - Self.body.descender + 2)
            var x: CGFloat = 2
            if hasIcon {
                icon.frame = NSRect(x: 2, y: (h - 16) / 2, width: 16, height: 16)
                x = 22
            }
            label.frame = NSRect(x: x, y: (h - lh) / 2, width: max(0, bounds.width - x - 2), height: lh)
        }

        /// Width this cell needs to show its content untruncated.
        var fittingWidth: CGFloat {
            (hasIcon ? 22 : 2) + ceil(label.attributedStringValue.size().width) + 6
        }

        // Assign only on change, so unchanged cells cause no redraw at all.
        private func set(_ v: String) { if label.stringValue != v { label.stringValue = v } }
        private func set(_ v: NSAttributedString) { if label.attributedStringValue != v { label.attributedStringValue = v } }
        private func set(color: NSColor) { if label.textColor != color { label.textColor = color } }
        private func set(image: NSImage?, tint: NSColor?) {
            if icon.image !== image { icon.image = image }
            if icon.contentTintColor != tint { icon.contentTintColor = tint }
        }

        func show(_ n: ProcNode, column c: Column, store: Store) {
            switch c.id {
            case "name":
                showName(n, procs: store.procs)
            case "context":
                set(Self.context(n))
                set(color: .secondaryLabelColor)
            default:
                // Processes: the column's own value. Group rows: what Store.sorted worked out for them.
                let v = n.proc.map { c.value($0, store) } ?? n.groupValues[c.id] ?? .empty
                set(v.display)
                set(color: Self.color(v.tint))
            }
        }

        private static func color(_ t: CellValue.Tint) -> NSColor {
            switch t {
            case .normal: .labelColor
            case .secondary: .secondaryLabelColor
            case .warning: .systemOrange
            case .danger: .systemRed
            }
        }

        private static var symbols: [String: NSImage] = [:]
        private static func symbol(_ name: String) -> NSImage? {
            if let i = symbols[name] { return i }
            let i = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            symbols[name] = i
            return i
        }

        private func showName(_ n: ProcNode, procs: [pid_t: ProcInfo]) {
            guard let p = n.proc else {
                if n.kind == .unit, let r = n.rootPid.flatMap({ procs[$0] }) {
                    // An app with its helpers: the app's icon and name, in regular weight.
                    set(image: IconCache.icon(for: r) ?? Self.terminalIcon, tint: nil)
                    set(NSAttributedString(string: n.title, attributes: [
                        .font: Self.body, .foregroundColor: NSColor.labelColor, .paragraphStyle: Self.truncating,
                    ]))
                    return
                }
                let image = n.isGhost ? Self.ghostIcon
                    : n.kind == .category ? n.category.flatMap { Self.symbol($0.symbol) } : Self.groupIcon
                let ghostly = n.isGhost || n.category == .leftBehind
                set(image: image, tint: ghostly ? .systemOrange : .secondaryLabelColor)
                set(NSAttributedString(string: n.title, attributes: [
                    .font: n.kind == .group ? Self.semibold : Self.bold,
                    .foregroundColor: ghostly ? NSColor.systemOrange : NSColor.labelColor,
                    .paragraphStyle: Self.truncating,
                ]))
                return
            }
            set(image: IconCache.icon(for: p) ?? Self.terminalIcon, tint: nil)
            let orphan = p.leftBehindGroup != nil
            let color: NSColor = p.isZombie || !p.isInspectable ? .secondaryLabelColor : orphan ? .systemOrange : .labelColor
            let s = NSMutableAttributedString(string: n.title, attributes: [.font: Self.body, .foregroundColor: color])
            // An app extension says what kind it is (its declared extension point), unless a group above does.
            if let e = p.extensionPoint, !n.extensionPointShownAbove {
                s.append(NSAttributedString(string: " · " + ExtensionInfo.title(e), attributes: [
                    .font: Self.body, .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            func badge(_ t: String, _ c: NSColor) {
                s.append(NSAttributedString(string: "  "))
                s.append(NSAttributedString(string: t, attributes: [
                    .font: NSFont.systemFont(ofSize: 8, weight: .bold), .foregroundColor: c,
                    .backgroundColor: c.withAlphaComponent(0.2), .baselineOffset: 1,
                ]))
            }
            if orphan { badge("LEFT", .systemOrange) }
            if p.isZombie { badge("ZOMBIE", .systemGray) }
            if p.isTranslated { badge("ROSETTA", .systemPurple) }
            if p.sandboxed == true { badge("SBX", .systemTeal) }
            if p.lsTags.contains(where: { $0.hasPrefix("exited") }) { badge("EXITED", .systemRed) }
            s.addAttribute(.paragraphStyle, value: Self.truncating, range: NSRange(location: 0, length: s.length))
            set(s)
        }

        static func context(_ n: ProcNode) -> String {
            guard let p = n.proc else {
                guard n.subtitle.isEmpty else { return n.subtitle }
                // "3 of 151 processes" while a search hides some.
                let procs = n.shownCount == n.totalCount ? "\(n.totalCount) processes" : "\(n.shownCount) of \(n.totalCount) processes"
                if n.kind == .category, let c = n.category, n.unitCount != n.shownCount {
                    return "\(n.unitCount) \(c.unitNoun) · \(procs)"
                }
                return procs
            }
            var parts: [String] = []
            if let app = p.containingAppName { parts.append("in \(app)") }
            if let e = p.extensionPoint { parts.append("extension: \(ExtensionInfo.title(e))") }
            if let t = p.tty { parts.append(SmartTree.ttyName(t)) }
            if let l = p.launchdLabel { parts.append("launchd: \(l)") }
            if let a = p.lsAppName { parts.append("LS: \(a)") }
            if !p.lsTags.isEmpty { parts.append(p.lsTags.joined(separator: " ")) }
            if parts.isEmpty, let path = p.path { parts.append(path) }
            return parts.joined(separator: " · ")
        }
    }
}
