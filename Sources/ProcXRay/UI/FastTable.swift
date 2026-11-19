import AppKit
import SwiftUI

/// A plain NSTableView for lists of thousands of rows (vmmap's region list: 6–16k).
///
/// SwiftUI's `Table` measures an automatic row height for every row it inserts: narrowing vmmap's list to
/// one region type and back (81 → 6447 rows) held the main thread for over 25 s. This one has fixed-height
/// text cells, reloads only what's visible, and sorts in the coordinator.
struct FastColumn<Row> {
    var id: String
    var title: String
    var width: CGFloat
    var minWidth: CGFloat = 40
    var numeric = false
    var mono = false
    var help: String? = nil
    var text: (Row) -> String
    var color: ((Row) -> NSColor?)? = nil
    var tooltip: ((Row) -> String?)? = nil
    /// Ascending order.
    var less: (Row, Row) -> Bool
}

/// A context-menu entry for the selected rows.
struct FastMenuItem {
    var title: String
    var enabled = true
    var action: () -> Void
    static var separator: FastMenuItem { FastMenuItem(title: "-", action: {}) }
}

struct FastTable<Row: Identifiable>: NSViewRepresentable where Row.ID: Hashable {
    let rows: [Row]
    let columns: [FastColumn<Row>]
    /// Column id and direction the table starts sorted by.
    var initialSort: (String, ascending: Bool)
    var menu: (([Row]) -> [FastMenuItem])? = nil
    var onOpen: ((Row) -> Void)? = nil
    /// Space with a row selected (the first selected row), as Finder's Quick Look; nil leaves Space to the table.
    var onSpace: ((Row) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = KeyTableView()
        table.onSpace = { [weak co = context.coordinator] in co?.space() ?? false }
        table.headerView = NSTableHeaderView()
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.usesAutomaticRowHeights = false
        table.rowHeight = 18
        table.intercellSpacing = NSSize(width: 6, height: 2)
        table.style = .fullWidth
        for c in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(c.id))
            col.title = c.title
            col.width = c.width
            col.minWidth = c.minWidth
            col.headerCell.alignment = c.numeric ? .right : .left
            col.headerToolTip = c.help
            col.sortDescriptorPrototype = NSSortDescriptor(key: c.id, ascending: !c.numeric)
            table.addTableColumn(col)
        }
        table.sortDescriptors = [NSSortDescriptor(key: initialSort.0, ascending: initialSort.ascending)]
        let co = context.coordinator
        co.table = table
        co.parent = self
        table.dataSource = co
        table.delegate = co
        table.target = co
        table.doubleAction = #selector(Coordinator.doubleClicked)
        let m = NSMenu()
        m.delegate = co
        table.menu = m
        co.apply()

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: FastTable!
        weak var table: NSTableView?
        private var shown: [Row] = []
        private var menuActions: [() -> Void] = []
        /// What `shown` was built from, so a SwiftUI update with the same rows doesn't re-sort and reload.
        private var appliedIDs: [Row.ID] = []
        private var appliedSort: [NSSortDescriptor] = []

        /// Sorts the parent's rows by the table's sort descriptor and reloads, keeping the selection.
        func apply(force: Bool = false) {
            guard let table else { return }
            let ids = parent.rows.map(\.id)
            if !force, ids == appliedIDs, table.sortDescriptors == appliedSort { return }
            appliedIDs = ids
            appliedSort = table.sortDescriptors
            let selected = Set(table.selectedRowIndexes.compactMap { $0 < shown.count ? shown[$0].id : nil })
            var rows = parent.rows
            if let d = table.sortDescriptors.first, let key = d.key, let c = parent.columns.first(where: { $0.id == key }) {
                // Stable: equal keys keep the incoming (address) order.
                rows = rows.enumerated().sorted { a, b in
                    if c.less(a.element, b.element) { return d.ascending }
                    if c.less(b.element, a.element) { return !d.ascending }
                    return a.offset < b.offset
                }.map(\.element)
            }
            shown = rows
            table.reloadData()
            if !selected.isEmpty {
                let idx = IndexSet(shown.indices.filter { selected.contains(shown[$0].id) })
                table.selectRowIndexes(idx, byExtendingSelection: false)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { apply() }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, row < shown.count,
                  let c = parent.columns.first(where: { $0.id == tableColumn.identifier.rawValue }) else { return nil }
            let id = NSUserInterfaceItemIdentifier("cell." + c.id)
            let field: NSTextField
            if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField {
                field = reused
            } else {
                field = NSTextField(labelWithString: "")
                field.identifier = id
                field.lineBreakMode = c.numeric ? .byTruncatingHead : .byTruncatingMiddle
                field.alignment = c.numeric ? .right : .left
                field.font = c.mono ? .monospacedSystemFont(ofSize: 11, weight: .regular)
                    : .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            }
            let r = shown[row]
            let text = c.text(r)
            field.stringValue = text
            field.textColor = c.color?(r) ?? .labelColor
            field.toolTip = c.tooltip?(r) ?? (text.count > 30 ? text : nil)
            return field
        }

        /// Whether Space was handled.
        func space() -> Bool {
            guard let table, let onSpace = parent.onSpace, let i = table.selectedRowIndexes.first, i < shown.count else { return false }
            onSpace(shown[i])
            return true
        }

        @objc func doubleClicked() {
            guard let table, table.clickedRow >= 0, table.clickedRow < shown.count else { return }
            parent.onOpen?(shown[table.clickedRow])
        }

        /// The clicked row joins the selection's menu only if it's selected; otherwise it alone is the target.
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            menuActions = []
            guard let table, let build = parent.menu else { return }
            let clicked = table.clickedRow
            guard clicked >= 0, clicked < shown.count else { return }
            let rows: [Row]
            if table.selectedRowIndexes.contains(clicked) {
                rows = table.selectedRowIndexes.compactMap { $0 < shown.count ? shown[$0] : nil }
            } else {
                rows = [shown[clicked]]
            }
            for item in build(rows) {
                if item.title == "-" { menu.addItem(.separator()); continue }
                let mi = NSMenuItem(title: item.title, action: item.enabled ? #selector(menuPicked(_:)) : nil, keyEquivalent: "")
                mi.target = self
                mi.tag = menuActions.count
                mi.isEnabled = item.enabled
                menuActions.append(item.action)
                menu.addItem(mi)
            }
        }

        @objc func menuPicked(_ sender: NSMenuItem) {
            guard sender.tag < menuActions.count else { return }
            menuActions[sender.tag]()
        }
    }
}

/// An NSTableView that hands Space to its owner.
final class KeyTableView: NSTableView {
    var onSpace: (() -> Bool)?
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ", event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
           onSpace?() == true { return }
        super.keyDown(with: event)
    }
}
