import SwiftUI

/// A row of the Activity outline: an activity, a thread of the waits, or one call under either. Calls carry
/// their parent so a row's identity stays unique and stable while the trace grows.
enum ActivityRowID: Hashable {
    case group(Int)
    case thread(group: Int, tid: UInt64)
    case call(group: Int, tid: UInt64?, id: Int)
}

struct SyscallActivityView: View {
    let groups: [SyscallActivity]
    /// The traced process's thread names (SyscallActivity.Context.threadNames).
    var threadNames: [UInt64: String] = [:]
    let filtered: Bool
    @Binding var selection: Set<ActivityRowID>
    /// The thread the trace view follows (nil: all), and how to follow another or all again (the row menu).
    var followed: Set<UInt64> = []
    var follow: (Set<UInt64>) -> Void = { _ in }
    /// Each thread's colour (ThreadColors), for the graph on the left and the thread ids in calls.
    var threadColors: [UInt64: NSColor] = [:]

    var body: some View {
        if groups.isEmpty {
            ContentUnavailableView(filtered ? "No matching activity" : "No activity to show",
                                   systemImage: "waveform.path.ecg",
                                   description: Text(filtered ? "Try another filter." : "Files, connections, Mach messages, launches and waits appear here. See Calls for the full trace."))
        } else {
            // An NSOutlineView rather than List(children:): on every selection change SwiftUI's outline re-diffed
            // every row, copying each call out of its activity, which took seconds a click on a long trace.
            ActivityOutline(groups: groups, threadNames: threadNames, selection: $selection, followed: followed, follow: follow,
                            threadColors: threadColors)
        }
    }

    nonisolated static func threads(_ calls: [SyscallRecord]) -> [(UInt64, [SyscallRecord])] {
        Dictionary(grouping: calls, by: \.thread).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    nonisolated static func threadLabel(_ tid: UInt64, _ count: Int, name: String? = nil) -> String {
        "Thread " + String(tid) + (name.map { " (\($0))" } ?? "") + " · " + count.formatted() + (count == 1 ? " call" : " calls")
    }

    nonisolated static func groupLine(_ g: SyscallActivity) -> String {
        var parts: [String] = []
        if g.operation != .waits { parts.append(g.calls[0].start.map(SyscallTraceView.seconds) ?? "before") }
        parts.append(g.operation.rawValue)
        if !g.target.isEmpty { parts.append(g.target) }
        return parts.joined(separator: "  ") + "  — " + g.detail
    }

    /// The activities as indented text, every call under its activity. With `only`, just the selected rows: an
    /// activity or thread brings its calls, a call under an activity that is also selected isn't repeated.
    nonisolated static func text(_ groups: [SyscallActivity], only: Set<ActivityRowID>? = nil, names: [UInt64: String] = [:]) -> String {
        var lines: [String] = []
        func want(_ id: ActivityRowID) -> Bool { only?.contains(id) ?? true }
        for g in groups {
            let whole = want(.group(g.id))
            if whole { lines.append(groupLine(g)) }
            if g.operation == .waits {
                for (tid, calls) in threads(g.calls) {
                    let thread = whole || want(.thread(group: g.id, tid: tid))
                    if thread { lines.append("    " + threadLabel(tid, calls.count, name: names[tid])) }
                    for r in calls where thread || want(.call(group: g.id, tid: tid, id: r.id)) {
                        lines.append("        " + SyscallTraceView.line(r))
                    }
                }
            } else {
                for r in g.calls where whole || want(.call(group: g.id, tid: nil, id: r.id)) {
                    lines.append("    " + SyscallTraceView.line(r))
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}

private struct GroupLabel: View {
    let group: SyscallActivity

    var body: some View {
        HStack(spacing: 8) {
            if group.operation != .waits {
                Text(group.calls[0].start.map(SyscallTraceView.seconds) ?? "before")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Text(group.operation.rawValue).fontWeight(.medium)
            if !group.target.isEmpty {
                Text(group.target).lineLimit(1).truncationMode(.middle).help(group.target)
            }
            Spacer(minLength: 8)
            Text(group.detail).foregroundStyle(group.allFailed ? Color.red : group.failures > 0 ? .orange : .secondary)
        }
        .font(.callout)
    }
}

private struct ActivityCall: View {
    let call: SyscallRecord
    var threadName: String?
    var threadColor: NSColor?

    private var head: Text {
        let time = call.start.map(SyscallTraceView.seconds) ?? "before"
        let tid = Text(String(call.thread))
        let rest = Text((threadName.map { " " + $0 } ?? "") + "]  " + call.name + "(" + call.namedArgsText + ")")
        guard let threadColor else { return Text(time + "  [") + tid + rest }
        return Text(time + "  [") + tid.foregroundStyle(Color(nsColor: threadColor)).bold() + rest
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            head
            HStack {
                Text(call.resultText).foregroundStyle(call.failed ? Color.red : .secondary)
                if let duration = call.duration { Text(SyscallTraceView.duration(duration)) }
                if !call.caller.isEmpty { Text(call.caller) }
                if !call.paths.isEmpty { Text(call.pathText) }
            }
            .foregroundStyle(.secondary)
        }
        .font(.system(size: 11, design: .monospaced))
    }
}

enum Pasteboard {
    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

// MARK: - Outline

/// The Activity outline in AppKit: an activity's rows are made the first time it's expanded and only visible rows
/// get a view, so a click or a trace update costs the same however many calls the trace holds.
private struct ActivityOutline: NSViewRepresentable {
    let groups: [SyscallActivity]
    let threadNames: [UInt64: String]
    @Binding var selection: Set<ActivityRowID>
    let followed: Set<UInt64>
    let follow: (Set<UInt64>) -> Void
    let threadColors: [UInt64: NSColor]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = CopyOutlineView()
        outline.headerView = nil
        outline.style = .inset
        outline.allowsMultipleSelection = true
        outline.usesAutomaticRowHeights = false
        // Only the activity column takes the view's width: the graph's is set by its lanes.
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.indentationPerLevel = 14
        // The thread graph first, outside the outline column, so its lanes don't shift with each row's indentation.
        let graph = NSTableColumn(identifier: ThreadGraphCell.column)
        graph.resizingMask = []
        graph.width = 0
        outline.addTableColumn(graph)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("activity"))
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        // No gaps between rows, so a thread's lane runs on unbroken.
        outline.intercellSpacing = NSSize(width: 0, height: 0)

        let co = context.coordinator
        co.outline = outline
        outline.dataSource = co
        outline.delegate = co
        outline.onCopy = { [weak co] in co?.copy(clicked: false) }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = co
        outline.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    final class Item: NSObject {
        enum Kind {
            case group(SyscallActivity)
            case thread(group: Int, tid: UInt64, calls: [SyscallRecord])
            case call(SyscallRecord)
        }
        let id: ActivityRowID
        let kind: Kind
        /// A call's index among its parent's calls; an activity's index among the activities.
        let position: Int
        private var built: [Item]?

        init(_ id: ActivityRowID, _ kind: Kind, position: Int = 0) { self.id = id; self.kind = kind; self.position = position }

        var expandable: Bool {
            if case .call = kind { return false }
            return true
        }

        /// Made the first time the outline asks, so a collapsed activity of thousands of calls costs nothing.
        var children: [Item] {
            if let built { return built }
            let made: [Item]
            switch kind {
            case .group(let g) where g.operation == .waits:
                made = SyscallActivityView.threads(g.calls).map { tid, calls in
                    Item(.thread(group: g.id, tid: tid), .thread(group: g.id, tid: tid, calls: calls))
                }
            case .group(let g):
                made = g.calls.enumerated().map { Item(.call(group: g.id, tid: nil, id: $1.id), .call($1), position: $0) }
            case .thread(let gid, let tid, let calls):
                made = calls.enumerated().map { Item(.call(group: gid, tid: tid, id: $1.id), .call($1), position: $0) }
            case .call:
                made = []
            }
            built = made
            return made
        }

        override func isEqual(_ object: Any?) -> Bool { (object as? Item)?.id == id }
        override var hash: Int { id.hashValue }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        weak var outline: NSOutlineView?
        private var parent: ActivityOutline?
        private var groups: [SyscallActivity] = []
        private var names: [UInt64: String] = [:]
        private var colors: [UInt64: NSColor] = [:]
        private var graph = ThreadGraph()
        private var roots: [Item] = []
        private var loaded = false
        /// Set while applying SwiftUI's state, so the outline's own notifications don't write it back.
        private var updating = false

        func update(_ p: ActivityOutline) {
            parent = p
            guard let o = outline else { return }
            updating = true
            defer { updating = false }
            // The same array storage: only the selection (or nothing) changed, which mustn't rebuild any rows.
            let same = groups.withUnsafeBufferPointer { a in
                p.groups.withUnsafeBufferPointer { b in a.baseAddress == b.baseAddress && a.count == b.count }
            }
            if !loaded || !same || p.threadNames != names || p.threadColors != colors { reload(p, o) }
            select(p.selection, o)
        }

        private func reload(_ p: ActivityOutline, _ o: NSOutlineView) {
            // Rows open before stay open: activities keep their ids while the trace grows.
            var open = Set<ActivityRowID>()
            for r in roots where o.isItemExpanded(r) {
                open.insert(r.id)
                for c in r.children where c.expandable && o.isItemExpanded(c) { open.insert(c.id) }
            }
            loaded = true
            groups = p.groups
            names = p.threadNames
            colors = p.threadColors
            graph = ThreadGraph(groups)
            if let c = o.tableColumns.first(where: { $0.identifier == ThreadGraphCell.column }) {
                let w = graph.columns == 0 ? 0 : ThreadGraphCell.width(columns: graph.columns)
                if c.width != w { c.width = w; o.sizeLastColumnToFit() }
            }
            roots = groups.enumerated().map { Item(.group($1.id), .group($1), position: $0) }
            o.reloadData()
            guard !open.isEmpty else { return }
            for r in roots where open.contains(r.id) {
                o.expandItem(r)
                for c in r.children where c.expandable && open.contains(c.id) { o.expandItem(c) }
            }
        }

        private func selectedIDs(_ o: NSOutlineView) -> Set<ActivityRowID> {
            Set(o.selectedRowIndexes.compactMap { (o.item(atRow: $0) as? Item)?.id })
        }

        /// Selects the rows of `ids` that are showing (a call inside a collapsed activity can't be).
        private func select(_ ids: Set<ActivityRowID>, _ o: NSOutlineView) {
            guard selectedIDs(o) != ids else { return }
            var rows = IndexSet()
            if !ids.isEmpty {
                for r in 0..<o.numberOfRows {
                    if let it = o.item(atRow: r) as? Item, ids.contains(it.id) { rows.insert(r) }
                }
            }
            o.selectRowIndexes(rows, byExtendingSelection: false)
        }

        // MARK: Data source

        func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? Item)?.children.count ?? roots.count
        }
        func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? Item)?.children[index] ?? roots[index]
        }
        func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? Item)?.expandable ?? false
        }

        // MARK: Delegate

        func outlineView(_ o: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            guard let it = item as? Item, case .call = it.kind else { return 22 }
            return 34
        }

        func outlineView(_ o: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
            guard let it = item as? Item else { return nil }
            if col?.identifier == ThreadGraphCell.column { return graphCell(o, it) }
            let cell = o.makeView(withIdentifier: HostCell.reuse, owner: nil) as? HostCell ?? HostCell()
            switch it.kind {
            case .group(let g):
                cell.content = AnyView(GroupLabel(group: g))
            case .thread(_, let tid, let calls):
                cell.content = AnyView(Text(SyscallActivityView.threadLabel(tid, calls.count, name: names[tid])).font(.callout))
            case .call(let r):
                cell.content = AnyView(ActivityCall(call: r, threadName: names[r.thread], threadColor: colors[r.thread]))
            }
            return cell
        }

        // MARK: Thread graph

        private func graphCell(_ o: NSOutlineView, _ it: Item) -> NSView {
            let cell = o.makeView(withIdentifier: ThreadGraphCell.column, owner: nil) as? ThreadGraphCell ?? ThreadGraphCell()
            let marks = graphMarks(o, it)
            cell.marks = marks
            cell.colors = colors
            let tids = marks.filter(\.dot).map(\.tid)
            cell.toolTip = tids.isEmpty ? nil : tids.map { SyscallTraceView.thread($0, names) }.joined(separator: "\n")
            return cell
        }

        /// What the graph draws on a row. The waits at the bottom hold every thread, so their rows get a dot alone,
        /// no lanes.
        private func graphMarks(_ o: NSOutlineView, _ it: Item) -> [ThreadGraphCell.Mark] {
            switch it.kind {
            case .group(let g) where g.operation == .waits: return []
            case .group: return graph.groupMarks(it.position, expanded: o.isItemExpanded(it))
            case .thread(_, let tid, _): return graph.dot(tid)
            case .call(let r):
                guard case .call(let gid, let tid, _) = it.id else { return [] }
                if tid != nil { return graph.dot(r.thread) }
                guard let i = groups.firstIndex(where: { $0.id == gid }) else { return [] }
                return graph.callMarks(group: i, call: it.position, thread: r.thread)
            }
        }

        /// A row's lanes go on below it when it opens, and stop when it closes.
        private func redrawGraph(_ n: Notification) {
            guard let o = outline, let it = n.userInfo?["NSObject"] as? Item, graph.columns > 0 else { return }
            let row = o.row(forItem: it)
            guard row >= 0 else { return }
            o.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        }
        func outlineViewItemDidExpand(_ n: Notification) { redrawGraph(n) }
        func outlineViewItemDidCollapse(_ n: Notification) { redrawGraph(n) }

        func outlineViewSelectionDidChange(_ n: Notification) {
            guard !updating, let o = outline else { return }
            let ids = selectedIDs(o)
            if ids != parent?.selection { parent?.selection = ids }
        }

        // MARK: Copy

        /// The right-clicked row, or the selection when the click was on a selected row.
        private func menuItems(_ o: NSOutlineView) -> [Item] {
            let r = o.clickedRow
            guard r >= 0 else { return [] }
            let rows = o.selectedRowIndexes.contains(r) ? Array(o.selectedRowIndexes) : [r]
            return rows.compactMap { o.item(atRow: $0) as? Item }
        }

        private func menuIDs(_ o: NSOutlineView) -> Set<ActivityRowID> { Set(menuItems(o).map(\.id)) }

        /// The threads of the calls in the menu's rows.
        private func menuThreads(_ o: NSOutlineView) -> Set<UInt64> {
            var out = Set<UInt64>()
            for it in menuItems(o) {
                switch it.kind {
                case .group(let g): out.formUnion(g.calls.lazy.map(\.thread))
                case .thread(_, let tid, _): out.insert(tid)
                case .call(let r): out.insert(r.thread)
                }
                if out.count > 1 { break }
            }
            return out
        }

        func copy(clicked: Bool) {
            guard let o = outline else { return }
            let ids = clicked ? menuIDs(o) : selectedIDs(o)
            guard !ids.isEmpty else { return }
            Pasteboard.copy(SyscallActivityView.text(groups, only: ids, names: names))
        }

        @objc private func copyClicked() { copy(clicked: true) }

        @objc private func followClicked(_ item: NSMenuItem) {
            if let next = item.representedObject as? Set<UInt64> { parent?.follow(next) }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let o = outline else { return }
            let item = NSMenuItem(title: "Copy", action: #selector(copyClicked), keyEquivalent: "")
            item.target = self
            item.isEnabled = !menuIDs(o).isEmpty
            menu.addItem(item)
            let follows = ThreadFollow.items(rows: menuThreads(o), shown: parent?.followed ?? [], names: names)
            if !follows.isEmpty { menu.addItem(.separator()) }
            for (title, next) in follows {
                let f = NSMenuItem(title: title, action: #selector(followClicked), keyEquivalent: "")
                f.representedObject = next
                f.target = self
                menu.addItem(f)
            }
        }
    }
}

/// ⌘C (Edit ▸ Copy) copies the selected rows.
private final class CopyOutlineView: NSOutlineView {
    var onCopy: (() -> Void)?

    @objc func copy(_ sender: Any?) { onCopy?() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !selectedRowIndexes.isEmpty }
        return super.validateUserInterfaceItem(item)
    }
}

/// A row's SwiftUI label, white on the selection's accent like a List row.
private final class HostCell: NSTableCellView {
    static let reuse = NSUserInterfaceItemIdentifier("ActivityCell")
    private let host = NSHostingView(rootView: AnyView(EmptyView()))

    var content = AnyView(EmptyView()) { didSet { render() } }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { render() } }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.reuse
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            // A margin at the end, so a row's details don't run into the view's edge (or the scroller).
            host.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func render() {
        let selected = backgroundStyle == .emphasized
        host.rootView = AnyView(content
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .environment(\.backgroundProminence, selected ? .increased : .standard))
    }
}

// MARK: - Thread colours and graph

/// One colour per thread, the same in Activity's graph, its calls and the Lanes view: by the thread's place among all
/// the trace's threads (by id), so a thread keeps its colour as the trace grows (new threads get higher ids).
enum ThreadColors {
    static let palette: [NSColor] = [.systemBlue, .systemOrange, .systemGreen, .systemPink, .systemPurple, .systemTeal,
                                     .systemRed, .systemIndigo, .systemBrown, .systemMint, .systemCyan]

    static func map(_ tids: [UInt64]) -> [UInt64: NSColor] {
        var out: [UInt64: NSColor] = [:]
        for (i, t) in tids.sorted().enumerated() { out[t] = palette[i % palette.count] }
        return out
    }
}

/// Where each thread's lane runs in Activity's graph, as `git log --graph` draws branches: down from the first
/// activity (top) with its calls to the last. Each row packs the lanes open on it from the left, oldest first, so
/// when one ends the ones to its right curve left to close the gap: no holes, and the graph is as wide as the most
/// threads at work at once. Activity puts the newest first.
struct ThreadGraph {
    /// Each thread's first and last activity (indexes, top to bottom).
    private(set) var span: [UInt64: (top: Int, bottom: Int)] = [:]
    /// Per activity: the lanes open on its row, by column.
    private(set) var lanes: [[UInt64]] = []
    /// Per activity: the index of each thread's last call in it.
    private var lastCall: [[UInt64: Int]] = []
    private(set) var columns = 0
    /// Past this many lanes at once, the rest share the last column (keeping their colours).
    static let maxColumns = 16

    init() {}

    init(_ groups: [SyscallActivity]) {
        self.init(activities: groups.map { ($0.operation == .waits, $0.calls.map(\.thread)) })
    }

    /// Each activity's calls' threads, top to bottom, and whether it is the waits.
    init(activities: [(waits: Bool, threads: [UInt64])]) {
        for (i, a) in activities.enumerated() {
            var last: [UInt64: Int] = [:]
            // The waits hold every thread: they'd keep every lane open to the bottom.
            if !a.waits {
                for (k, t) in a.threads.enumerated() { last[t] = k }
                for t in last.keys { span[t] = (span[t]?.top ?? i, i) }
            }
            lastCall.append(last)
        }
        var starts = [[UInt64]](repeating: [], count: activities.count)
        for (t, s) in span { starts[s.top].append(t) }
        var open: [UInt64] = []
        for i in activities.indices {
            open.removeAll { span[$0]!.bottom < i }
            open += starts[i].sorted()
            lanes.append(open)
            columns = max(columns, min(open.count, Self.maxColumns))
        }
    }

    private func col(_ i: Int, _ t: UInt64) -> Int? {
        lanes[i].firstIndex(of: t).map { min($0, Self.maxColumns - 1) }
    }

    /// An activity's row: the lanes passing it (curving from where they were on the row above), and a dot on each
    /// thread with calls in it. Open, its threads' lanes go on down into its calls.
    func groupMarks(_ i: Int, expanded: Bool) -> [ThreadGraphCell.Mark] {
        guard i < lanes.count else { return [] }
        return lanes[i].enumerated().map { c, t in
            let s = span[t]!
            let here = lastCall[i][t] != nil
            let from = s.top < i ? col(i - 1, t) : nil
            return .init(tid: t, column: min(c, Self.maxColumns - 1), from: from,
                         bottom: s.bottom > i || (here && expanded), dot: here)
        }
    }

    /// A call's row under activity `i`: lanes going on past the activity, and the activity's own threads down to
    /// their last call in it.
    func callMarks(group i: Int, call k: Int, thread: UInt64) -> [ThreadGraphCell.Mark] {
        guard i < lanes.count else { return [] }
        return lanes[i].enumerated().compactMap { c, t in
            let passes = span[t]!.bottom > i
            let last = lastCall[i][t]
            let more = last.map { k < $0 } ?? false
            guard passes || last.map({ k <= $0 }) ?? false else { return nil }
            let c = min(c, Self.maxColumns - 1)
            return .init(tid: t, column: c, from: c, bottom: passes || more, dot: t == thread)
        }
    }

    /// A row of the waits: the thread's dot, no lanes.
    func dot(_ t: UInt64) -> [ThreadGraphCell.Mark] {
        [.init(tid: t, column: 0, from: nil, bottom: false, dot: true)]
    }
}

/// One row of Activity's thread graph: lanes in each thread's colour, a dot where the row has the thread's calls,
/// and a line joining the dots of an activity several threads took part in.
final class ThreadGraphCell: NSView {
    static let column = NSUserInterfaceItemIdentifier("threadGraph")
    static let step: CGFloat = 12, inset: CGFloat = 10
    /// Level with the row's first line of text.
    static let dotY: CGFloat = 11

    static func width(columns: Int) -> CGFloat { inset + CGFloat(columns) * step }

    struct Mark: Equatable {
        let tid: UInt64
        /// The lane's column on this row.
        let column: Int
        /// Its column at the row's top edge (the row above's), nil when the lane starts on this row.
        let from: Int?
        /// It goes on below the row.
        let bottom: Bool
        let dot: Bool
    }

    var marks: [Mark] = [] { didSet { if marks != oldValue { needsDisplay = true } } }
    var colors: [UInt64: NSColor] = [:] { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        identifier = Self.column
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirty: NSRect) {
        func x(_ c: Int) -> CGFloat { Self.inset + CGFloat(c) * Self.step }
        let y = min(Self.dotY, bounds.midY)
        let dots = marks.filter(\.dot)
        if dots.count > 1, let lo = dots.map(\.column).min(), let hi = dots.map(\.column).max(), lo < hi {
            let join = NSBezierPath()
            join.move(to: NSPoint(x: x(lo), y: y))
            join.line(to: NSPoint(x: x(hi), y: y))
            join.lineWidth = 1.5
            NSColor.tertiaryLabelColor.setStroke()
            join.stroke()
        }
        for m in marks where m.from != nil || m.bottom {
            let lane = NSBezierPath()
            let mid = NSPoint(x: x(m.column), y: y)
            if let f = m.from {
                // From where it was on the row above, curving over when a lane to its left ended.
                lane.move(to: NSPoint(x: x(f), y: bounds.minY))
                if f == m.column { lane.line(to: mid) } else {
                    lane.curve(to: mid, controlPoint1: NSPoint(x: x(f), y: y * 0.6), controlPoint2: NSPoint(x: x(m.column), y: y * 0.4))
                }
            } else {
                lane.move(to: mid)
            }
            if m.bottom { lane.line(to: NSPoint(x: x(m.column), y: bounds.maxY)) }
            lane.lineWidth = 2
            lane.lineCapStyle = .round
            (colors[m.tid] ?? .secondaryLabelColor).setStroke()
            lane.stroke()
        }
        for m in dots {
            let r: CGFloat = 3.5
            let dot = NSBezierPath(ovalIn: NSRect(x: x(m.column) - r, y: y - r, width: 2 * r, height: 2 * r))
            (colors[m.tid] ?? .secondaryLabelColor).setFill()
            dot.fill()
            dot.lineWidth = 1.5
            NSColor.controlBackgroundColor.setStroke()
            dot.stroke()
        }
    }
}
