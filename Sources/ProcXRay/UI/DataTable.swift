import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The app's table for rows of data: one NSTableView that every list of records goes through, so they all
/// select, navigate, sort, copy and export the same way.
///
/// What every table gets, without its view doing anything:
/// - Selection: click, ⇧/⌘-click, ⌘A, Esc to clear; kept across reloads and sorts by row id.
/// - Keyboard: arrows, Page Up/Down, Home/End, typing to jump to a row (by its first text column), Return to
///   open (`onOpen`), Space for a preview (`onSpace`).
/// - Sorting by any column (a click on its header), stable, remembered with the column layout (`autosave`).
/// - Columns: resize, reorder, and show or hide from the header's context menu.
/// - Copy: ⌘C and Edit ▸ Copy put the selected rows on the pasteboard as tab-separated text; the context menu
///   also copies the one cell under the pointer, or the rows with a header line.
/// - Export: the context menu saves the shown rows (or the selection) as CSV or tab-separated text.
///
/// It is fast for the same reason as before it was shared: fixed-height text cells, only visible rows are
/// loaded, and sorting happens in the coordinator. SwiftUI's `Table` measures a row height for every row it
/// inserts (vmmap's 6–16k regions held the main thread for over 25 s).
struct DataColumn<Row> {
    var id: String
    var title: String
    var width: CGFloat
    var minWidth: CGFloat = 40
    var numeric = false
    var mono = false
    /// Cut text that doesn't fit at its end, not in its middle: for prose (a log message), whose start says most.
    var truncatesTail = false
    var help: String? = nil
    /// Starts hidden; the header's menu shows it.
    var hidden = false
    var text: (Row) -> String
    var color: ((Row) -> NSColor?)? = nil
    /// A small filled circle before the text, in this color: a state at a glance (enabled, running).
    var dot: ((Row) -> NSColor?)? = nil
    /// An SF Symbol before the text, in this color: what kind of thing the row is.
    var symbol: ((Row) -> (name: String, color: NSColor)?)? = nil
    /// A small bar before the text: the value as a share (0…1) of the largest, for comparing rows at a glance.
    var bar: ((Row) -> (fraction: Double, color: NSColor)?)? = nil
    var tooltip: ((Row) -> String?)? = nil
    /// Ascending order.
    var less: (Row, Row) -> Bool

    /// A text column sorted by its text, without case.
    static func text(_ id: String, _ title: String, width: CGFloat, mono: Bool = false, help: String? = nil, hidden: Bool = false,
                     color: ((Row) -> NSColor?)? = nil, _ text: @escaping (Row) -> String) -> DataColumn {
        DataColumn(id: id, title: title, width: width, mono: mono, help: help, hidden: hidden, text: text, color: color,
                   less: { text($0).localizedStandardCompare(text($1)) == .orderedAscending })
    }

    /// A right-aligned column sorted by a number (nil sorts first ascending), shown through `format`.
    static func number<N: Comparable>(_ id: String, _ title: String, width: CGFloat, help: String? = nil, hidden: Bool = false,
                                      color: ((Row) -> NSColor?)? = nil, value: @escaping (Row) -> N?,
                                      format: @escaping (N) -> String) -> DataColumn {
        DataColumn(id: id, title: title, width: width, numeric: true, help: help, hidden: hidden,
                   text: { value($0).map(format) ?? "" }, color: color,
                   less: { a, b in
                       switch (value(a), value(b)) {
                       case let (x?, y?): x < y
                       case (nil, _?): true
                       default: false
                       }
                   })
    }
}

/// A context-menu entry for the selected rows.
/// The column a table is sorted by, for a table whose owner sorts its rows (DataTable.sort).
struct DataSort: Equatable, Sendable {
    var column: String
    var ascending: Bool
}

struct DataMenuItem {
    var title: String
    var enabled = true
    var action: () -> Void
    static var separator: DataMenuItem { DataMenuItem(title: "-", action: {}) }
}

struct DataTable<Row: Identifiable>: NSViewRepresentable where Row.ID: Hashable {
    let rows: [Row]
    let columns: [DataColumn<Row>]
    /// Column id and direction the table starts sorted by.
    var initialSort: (String, ascending: Bool)
    /// Saves column widths, order, visibility and the sort under this name.
    var autosave: String? = nil
    /// The rows' values change while their ids stay (threads, counters): every update re-sorts and redraws the
    /// visible cells. Off, an update with the same row ids is taken as no change at all.
    var live = false
    /// For a table too big to sort on the main thread at every update (a syscall trace's calls): `rows` come
    /// already in this order, and a click on a header only sets it, for the owner to sort by.
    var sort: Binding<DataSort>? = nil
    /// Columns that don't apply right now: hidden, and left out of the header's menu, until they do.
    var hiddenColumns: Set<String> = []
    /// What Cmd-C and Copy Row put on the pasteboard, when it isn't the cells tab-separated (a trace's calls copy
    /// as strace-style lines with their stacks).
    var copyText: (([Row]) -> String)? = nil
    /// Keeps the last row in view as rows arrive (a log being followed).
    var followsEnd = false
    /// The selected rows' ids, for a view that shows something about the selection.
    var selection: Binding<Set<Row.ID>>? = nil
    var allowsMultipleSelection = true
    /// The caller's entries, above Copy and Export.
    var menu: (([Row]) -> [DataMenuItem])? = nil
    /// Double-click or Return on a row.
    var onOpen: ((Row) -> Void)? = nil
    /// Space with a row selected (the first selected row, with its frame on screen), as Finder's Quick Look; nil
    /// leaves Space to the table.
    var onSpace: ((Row, _ rowOnScreen: NSRect) -> Void)? = nil
    /// The selection moved to a single row (with its frame on screen): for a preview that follows it.
    var onSelect: ((Row, _ rowOnScreen: NSRect) -> Void)? = nil
    /// The name export suggests for its file, without extension.
    var exportName = "Proc X-Ray"

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = KeyTableView()
        let co = context.coordinator
        table.onSpace = { [weak co] in co?.space() ?? false }
        table.onReturn = { [weak co] in co?.openSelected() ?? false }
        table.onCopy = { [weak co] in co?.copyRows(header: false) }
        table.canCopy = { [weak table] in (table?.selectedRowIndexes.count ?? 0) > 0 }
        let header = NSTableHeaderView()
        table.headerView = header
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = allowsMultipleSelection
        table.allowsEmptySelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.allowsTypeSelect = true
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
            col.isHidden = c.hidden
            col.headerCell.alignment = c.numeric ? .right : .left
            col.headerToolTip = c.help
            col.sortDescriptorPrototype = NSSortDescriptor(key: c.id, ascending: !c.numeric)
            table.addTableColumn(col)
        }
        let first = sort?.wrappedValue ?? DataSort(column: initialSort.0, ascending: initialSort.ascending)
        table.sortDescriptors = [NSSortDescriptor(key: first.column, ascending: first.ascending)]
        if let autosave {
            // After the columns exist: setting the name restores their saved widths, order and visibility.
            table.autosaveName = "DataTable." + autosave
            table.autosaveTableColumns = true
        }
        co.table = table
        co.parent = self
        table.dataSource = co
        table.delegate = co
        table.target = co
        table.doubleAction = #selector(Coordinator.doubleClicked)
        let m = NSMenu()
        m.delegate = co
        table.menu = m
        let hm = NSMenu()
        hm.delegate = co
        hm.identifier = Coordinator.headerMenuID
        header.menu = hm
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
        static var headerMenuID: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier("DataTable.header") }

        var parent: DataTable!
        weak var table: NSTableView?
        private var shown: [Row] = []
        private var menuActions: [() -> Void] = []
        /// What `shown` was built from, so a SwiftUI update with the same rows doesn't re-sort and reload.
        private var appliedIDs: [Row.ID] = []
        private var appliedSort: [NSSortDescriptor] = []
        /// Set while this object changes the table's selection itself, so that isn't reported as the user's.
        private var settingSelection = false

        private func column(_ id: String) -> DataColumn<Row>? { parent.columns.first { $0.id == id } }

        /// Sorts the parent's rows by the table's sort descriptor and shows them, keeping the selection.
        func apply(force: Bool = false) {
            guard let table else { return }
            syncHidden(table)
            let ids = parent.rows.map(\.id)
            let same = ids == appliedIDs && table.sortDescriptors == appliedSort
            if !force, same, !parent.live { syncSelectionFromBinding(); return }
            appliedIDs = ids
            appliedSort = table.sortDescriptors
            var rows = parent.rows
            if parent.sort == nil, let d = table.sortDescriptors.first, let key = d.key, let c = column(key) {
                // Stable: equal keys keep the incoming order.
                rows = rows.enumerated().sorted { a, b in
                    if c.less(a.element, b.element) { return d.ascending }
                    if c.less(b.element, a.element) { return !d.ascending }
                    return a.offset < b.offset
                }.map(\.element)
            }
            // Live data in the same order: only the visible cells need their new text.
            if !force, same, rows.count == shown.count, zip(rows, shown).allSatisfy({ $0.id == $1.id }) {
                shown = rows
                refreshVisible(table)
                syncSelectionFromBinding()
                return
            }
            let selected = parent.selection?.wrappedValue
                ?? Set(table.selectedRowIndexes.compactMap { $0 < shown.count ? shown[$0].id : nil })
            let grew = rows.count > shown.count
            shown = rows
            table.reloadData()
            select(selected, in: table)
            if parent.followsEnd, grew, !rows.isEmpty {
                // After this update is laid out: the first rows arrive before the table is in its scroll view.
                let last = rows.count - 1
                DispatchQueue.main.async { [weak table] in
                    MainActor.assumeIsolated { if let table, last < table.numberOfRows { table.scrollRowToVisible(last) } }
                }
            }
        }

        /// Columns the owner says don't apply are hidden; one it hid comes back when it applies again.
        private var forcedHidden: Set<String> = []
        private func syncHidden(_ table: NSTableView) {
            guard parent.hiddenColumns != forcedHidden else { return }
            for tc in table.tableColumns {
                let id = tc.identifier.rawValue
                if parent.hiddenColumns.contains(id) { tc.isHidden = true }
                else if forcedHidden.contains(id) { tc.isHidden = false }
            }
            forcedHidden = parent.hiddenColumns
        }

        private func select(_ ids: Set<Row.ID>, in table: NSTableView) {
            let idx = ids.isEmpty ? IndexSet() : IndexSet(shown.indices.filter { ids.contains(shown[$0].id) })
            guard idx != table.selectedRowIndexes else { return }
            settingSelection = true
            table.selectRowIndexes(idx, byExtendingSelection: false)
            settingSelection = false
        }

        /// The owner changed the selection (a link to a row, a reset): show it.
        private func syncSelectionFromBinding() {
            guard let table, let want = parent.selection?.wrappedValue else { return }
            select(want, in: table)
        }

        /// Sets the visible cells' text again, each only if it changed.
        private func refreshVisible(_ table: NSTableView) {
            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0 else { return }
            for row in visible.location..<min(visible.location + visible.length, shown.count) {
                for (ci, tc) in table.tableColumns.enumerated() where !tc.isHidden {
                    guard let cell = table.view(atColumn: ci, row: row, makeIfNecessary: false) as? DataCellView,
                          let c = column(tc.identifier.rawValue) else { continue }
                    fill(cell, c, shown[row])
                }
            }
        }

        private func fill(_ cell: DataCellView, _ c: DataColumn<Row>, _ r: Row) {
            let field = cell.label
            if let bar = c.bar { cell.setBar(bar(r)) }
            if let symbol = c.symbol { cell.setSymbol(symbol(r)) }
            let text = c.text(r)
            let color = c.color?(r) ?? .labelColor
            if let dot = c.dot { cell.setDot(dot(r)) }
            if field.stringValue != text { field.stringValue = text }
            if field.textColor != color { field.textColor = color }
            let tip = c.tooltip?(r) ?? (text.count > 30 ? text : nil)
            if cell.toolTip != tip { cell.toolTip = tip }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            // The owner sorts: tell it, and its next rows arrive in the new order.
            if let b = parent.sort, let d = tableView.sortDescriptors.first, let key = d.key {
                let s = DataSort(column: key, ascending: d.ascending)
                if b.wrappedValue != s { b.wrappedValue = s }
                return
            }
            apply(force: true)
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, row < shown.count, let c = column(tableColumn.identifier.rawValue) else { return nil }
            let id = NSUserInterfaceItemIdentifier("cell." + c.id)
            let cell: DataCellView
            if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? DataCellView {
                cell = reused
            } else {
                cell = DataCellView(hasBar: c.bar != nil, hasDot: c.dot != nil, hasSymbol: c.symbol != nil)
                cell.identifier = id
                cell.label.lineBreakMode = c.numeric ? .byTruncatingHead : c.truncatesTail ? .byTruncatingTail : .byTruncatingMiddle
                cell.label.alignment = c.numeric ? .right : .left
                cell.label.font = c.mono ? .monospacedSystemFont(ofSize: 11, weight: .regular)
                    : .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            }
            fill(cell, c, shown[row])
            return cell
        }

        /// Typing jumps to the row whose first shown text column starts with what was typed.
        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            guard row < shown.count,
                  let first = tableView.tableColumns.first(where: { tc in !tc.isHidden && column(tc.identifier.rawValue)?.numeric == false }),
                  tableColumn === first, let c = column(first.identifier.rawValue) else { return nil }
            return c.text(shown[row])
        }

        /// Whether Space was handled.
        func space() -> Bool {
            guard let table, let onSpace = parent.onSpace, let i = table.selectedRowIndexes.first, i < shown.count else { return false }
            onSpace(shown[i], screenRect(ofRow: i, in: table))
            return true
        }

        /// Return: opens the first selected row. Whether it was handled.
        func openSelected() -> Bool {
            guard let table, let onOpen = parent.onOpen, let i = table.selectedRowIndexes.first, i < shown.count else { return false }
            onOpen(shown[i])
            return true
        }

        /// The row's visible part, in screen coordinates: what a popup over the row lines up with.
        private func screenRect(ofRow i: Int, in table: NSTableView) -> NSRect {
            table.scrollRowToVisible(i)
            let inTable = table.rect(ofRow: i).intersection(table.visibleRect)
            return table.window.map { $0.convertToScreen(table.convert(inTable, to: nil)) } ?? .zero
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table, !settingSelection else { return }
            if let b = parent.selection {
                let ids = Set(table.selectedRowIndexes.compactMap { $0 < shown.count ? shown[$0].id : nil })
                if b.wrappedValue != ids { b.wrappedValue = ids }
            }
            guard let onSelect = parent.onSelect, table.selectedRowIndexes.count == 1,
                  let i = table.selectedRowIndexes.first, i < shown.count else { return }
            onSelect(shown[i], screenRect(ofRow: i, in: table))
        }

        @objc func doubleClicked() {
            guard let table, table.clickedRow >= 0, table.clickedRow < shown.count else { return }
            parent.onOpen?(shown[table.clickedRow])
        }

        // MARK: Copy and export

        /// The shown columns, left to right as the user arranged them.
        private var visibleColumns: [DataColumn<Row>] {
            (table?.tableColumns ?? []).filter { !$0.isHidden }.compactMap { column($0.identifier.rawValue) }
        }

        private var selectedRows: [Row] {
            (table?.selectedRowIndexes ?? []).compactMap { $0 < shown.count ? shown[$0] : nil }
        }

        /// Rows as lines of `separator`-joined cells. A cell holding the separator, a quote or a line break is
        /// quoted, as CSV wants it; tabs and line breaks become spaces in tab-separated text.
        private func text(_ rows: [Row], header: Bool, separator: String) -> String {
            let cols = visibleColumns
            var lines: [[String]] = []
            if header { lines.append(cols.map(\.title)) }
            for r in rows { lines.append(cols.map { $0.text(r) }) }
            return DelimitedText.join(lines, separator: separator)
        }

        private func put(_ s: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        }

        func copyRows(header: Bool) {
            let rows = selectedRows
            guard !rows.isEmpty else { return }
            put(rowsText(rows, header: header))
        }

        /// The owner's own format when it has one and no header line is asked for, else the cells tab-separated.
        private func rowsText(_ rows: [Row], header: Bool) -> String {
            if !header, let custom = parent.copyText { return custom(rows) }
            return text(rows, header: header, separator: "\t")
        }

        private func export(_ rows: [Row]) {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText]
            panel.nameFieldStringValue = parent.exportName + ".csv"
            panel.canCreateDirectories = true
            let write: (URL) -> Void = { [weak self] url in
                guard let self else { return }
                let tsv = url.pathExtension.lowercased() == "tsv" || url.pathExtension.lowercased() == "txt"
                let body = self.text(rows, header: true, separator: tsv ? "\t" : ",") + "\n"
                do { try Data(body.utf8).write(to: url) } catch { NSAlert(error: error).runModal() }
            }
            if let w = table?.window {
                panel.beginSheetModal(for: w) { if $0 == .OK, let url = panel.url { write(url) } }
            } else if panel.runModal() == .OK, let url = panel.url {
                write(url)
            }
        }

        // MARK: Menus

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            menuActions = []
            guard let table else { return }
            if menu.identifier == Self.headerMenuID { headerMenu(menu, table); return }
            func add(_ title: String, enabled: Bool = true, _ action: @escaping () -> Void) {
                let mi = NSMenuItem(title: title, action: enabled ? #selector(menuPicked(_:)) : nil, keyEquivalent: "")
                mi.target = self
                mi.tag = menuActions.count
                mi.isEnabled = enabled
                menuActions.append(action)
                menu.addItem(mi)
            }
            // The clicked row joins the selection's menu only if it's selected; otherwise it alone is the target.
            let clicked = table.clickedRow
            var rows: [Row] = []
            if clicked >= 0, clicked < shown.count {
                if table.selectedRowIndexes.contains(clicked) {
                    rows = selectedRows
                } else {
                    // As everywhere on the Mac: the menu is about the row under the pointer (AppKit rings it), and
                    // the selection stays as it was.
                    rows = [shown[clicked]]
                }
            }
            if !rows.isEmpty, let build = parent.menu {
                let own = build(rows)
                for item in own {
                    if item.title == "-" { menu.addItem(.separator()) } else { add(item.title, enabled: item.enabled, item.action) }
                }
                if !own.isEmpty { menu.addItem(.separator()) }
            }
            if !rows.isEmpty {
                let n = rows.count
                add(n == 1 ? "Copy Row" : "Copy \(n) Rows") { [weak self] in
                    guard let self else { return }
                    self.put(self.rowsText(rows, header: false))
                }
                let ci = table.clickedColumn
                if n == 1, ci >= 0, ci < table.tableColumns.count, let c = column(table.tableColumns[ci].identifier.rawValue) {
                    let value = c.text(rows[0])
                    add("Copy \(c.title)", enabled: !value.isEmpty) { [weak self] in self?.put(value) }
                }
                add("Copy with Headers") { [weak self] in
                    guard let self else { return }
                    self.put(self.text(rows, header: true, separator: "\t"))
                }
                menu.addItem(.separator())
                if n > 1 { add("Export \(n) Rows…") { [weak self] in self?.export(rows) } }
            }
            let all = shown
            add(all.count == 1 ? "Export 1 Row…" : "Export All \(all.count) Rows…", enabled: !all.isEmpty) { [weak self] in self?.export(all) }
        }

        /// The header's menu: every column, checked while shown.
        private func headerMenu(_ menu: NSMenu, _ table: NSTableView) {
            for tc in table.tableColumns where !parent.hiddenColumns.contains(tc.identifier.rawValue) {
                guard let c = column(tc.identifier.rawValue) else { continue }
                let mi = NSMenuItem(title: c.title.isEmpty ? c.id : c.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = tc
                mi.state = tc.isHidden ? .off : .on
                // The last shown column stays: a table with none can't bring one back.
                if !tc.isHidden, table.tableColumns.filter({ !$0.isHidden }).count == 1 { mi.action = nil }
                menu.addItem(mi)
            }
            menu.addItem(.separator())
            let fit = NSMenuItem(title: "Size Columns to Fit", action: #selector(sizeToFit), keyEquivalent: "")
            fit.target = self
            menu.addItem(fit)
        }

        @objc func toggleColumn(_ sender: NSMenuItem) {
            guard let tc = sender.representedObject as? NSTableColumn else { return }
            tc.isHidden.toggle()
        }

        /// Each shown column as wide as its header and its widest visible cell.
        @objc func sizeToFit() {
            guard let table else { return }
            let visible = table.rows(in: table.visibleRect)
            for tc in table.tableColumns where !tc.isHidden {
                guard let c = column(tc.identifier.rawValue) else { continue }
                let font: NSFont = c.mono ? .monospacedSystemFont(ofSize: 11, weight: .regular)
                    : .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                var w = (tc.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]).width + 24
                if visible.length > 0 {
                    for row in visible.location..<min(visible.location + visible.length, shown.count) {
                        w = max(w, (c.text(shown[row]) as NSString).size(withAttributes: [.font: font]).width + 10)
                    }
                }
                tc.width = min(max(w, tc.minWidth), 600)
            }
        }

        @objc func menuPicked(_ sender: NSMenuItem) {
            guard sender.tag < menuActions.count else { return }
            menuActions[sender.tag]()
        }
    }
}

/// Rows of cells as text, for the pasteboard and for export.
enum DelimitedText {
    /// One line per row, cells joined by `separator`. With a comma, a cell holding a comma, a quote or a line break
    /// is quoted and its quotes doubled, as CSV wants it; with anything else (a tab), tabs and line breaks inside
    /// a cell become spaces, so a paste into a spreadsheet keeps its columns.
    static func join(_ rows: [[String]], separator: String) -> String {
        func cell(_ s: String) -> String {
            if separator == "," {
                return s.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
            }
            return String(s.map { $0 == "\t" || $0.isNewline ? " " : $0 })
        }
        return rows.map { $0.map(cell).joined(separator: separator) }.joined(separator: "\n")
    }
}

/// One cell of a DataTable: a line of text, after a small bar or a state dot when the column has one. Both are
/// layers, so a new value moves a layer's frame or changes its color and draws nothing.
/// An NSTableCellView, so the row hands its selected state to the text and the colors invert with it.
final class DataCellView: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    private let track: CALayer?
    private let fill: CALayer?
    private let dot: CALayer?
    private var dotColor: NSColor?
    private let symbolView: NSImageView?
    private var symbolKey: String?
    private static let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
    nonisolated(unsafe) private static var symbols: [String: NSImage] = [:]
    private var fraction = -1.0
    static let barWidth: CGFloat = 46, barHeight: CGFloat = 5, dotSize: CGFloat = 7

    init(hasBar: Bool, hasDot: Bool = false, hasSymbol: Bool = false) {
        track = hasBar ? CALayer() : nil
        fill = hasBar ? CALayer() : nil
        dot = hasDot ? CALayer() : nil
        symbolView = hasSymbol ? NSImageView() : nil
        super.init(frame: .zero)
        if let symbolView {
            symbolView.imageScaling = .scaleProportionallyDown
            addSubview(symbolView)
        }
        if let dot {
            wantsLayer = true
            dot.cornerRadius = Self.dotSize / 2
            dot.actions = ["backgroundColor": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
            layer?.addSublayer(dot)
        }
        if let track, let fill {
            wantsLayer = true
            track.cornerRadius = Self.barHeight / 2
            fill.cornerRadius = Self.barHeight / 2
            // No implicit animation: a bar that slides on every refresh costs a render pass per frame.
            track.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(), "hidden": NSNull()]
            fill.actions = track.actions
            layer?.addSublayer(track)
            layer?.addSublayer(fill)
        }
        addSubview(label)
        textField = label
    }
    required init?(coder: NSCoder) { fatalError() }

    /// nil: no symbol on this row (the text keeps its place).
    func setSymbol(_ v: (name: String, color: NSColor)?) {
        guard let symbolView else { return }
        if symbolKey != v?.name {
            symbolKey = v?.name
            symbolView.image = v.flatMap { s in
                if let hit = Self.symbols[s.name] { return hit }
                let img = NSImage(systemSymbolName: s.name, accessibilityDescription: nil)?.withSymbolConfiguration(Self.symbolConfig)
                Self.symbols[s.name] = img
                return img
            }
        }
        if symbolView.contentTintColor != v?.color { symbolView.contentTintColor = v?.color }
    }

    /// nil: no dot on this row (the text keeps its place).
    func setDot(_ color: NSColor?) {
        guard let dot, color != dotColor || dot.backgroundColor == nil else { return }
        dotColor = color
        dot.isHidden = color == nil
        effectiveAppearance.performAsCurrentDrawingAppearance { dot.backgroundColor = color?.cgColor }
    }

    func setBar(_ v: (fraction: Double, color: NSColor)?) {
        guard let track, let fill else { return }
        track.isHidden = v == nil
        fill.isHidden = v == nil
        guard let v else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            fill.backgroundColor = v.color.cgColor
        }
        let f = min(max(v.fraction, 0), 1)
        if f != fraction { fraction = f; needsLayout = true }
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        if let track, let fill {
            let y = (bounds.height - Self.barHeight) / 2
            track.frame = CGRect(x: 0, y: y, width: Self.barWidth, height: Self.barHeight)
            fill.frame = CGRect(x: 0, y: y, width: max(fraction > 0 ? 2 : 0, Self.barWidth * fraction), height: Self.barHeight)
            x = Self.barWidth + 6
        }
        if let dot {
            dot.frame = CGRect(x: 1, y: (bounds.height - Self.dotSize) / 2, width: Self.dotSize, height: Self.dotSize)
            x = Self.dotSize + 6
        }
        if let symbolView {
            symbolView.frame = NSRect(x: 0, y: (bounds.height - 14) / 2, width: 16, height: 14)
            x = 20
        }
        let h = label.intrinsicContentSize.height
        label.frame = NSRect(x: x, y: (bounds.height - h) / 2, width: max(0, bounds.width - x), height: h)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            dot?.backgroundColor = dotColor?.cgColor
        }
    }
}

/// The table view under DataTable: hands Space and Return to its owner, clears the selection on Esc, and answers
/// Edit ▸ Copy.
final class KeyTableView: NSTableView, NSMenuItemValidation {
    var onSpace: (() -> Bool)?
    var onReturn: (() -> Bool)?
    var onCopy: (() -> Void)?
    var canCopy: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function]).isEmpty
        if plain {
            switch event.keyCode {
            case 49 where onSpace?() == true: return          // Space
            case 36, 76: if onReturn?() == true { return }     // Return, Enter
            case 53 where !selectedRowIndexes.isEmpty:         // Esc
                deselectAll(nil)
                return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) { onCopy?() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) { return canCopy?() ?? false }
        return true
    }
}
