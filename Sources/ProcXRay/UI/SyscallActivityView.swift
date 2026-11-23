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
    var followed: UInt64? = nil
    var follow: (UInt64?) -> Void = { _ in }

    var body: some View {
        if groups.isEmpty {
            ContentUnavailableView(filtered ? "No matching activity" : "No activity to show",
                                   systemImage: "waveform.path.ecg",
                                   description: Text(filtered ? "Try another filter." : "Files, connections, Mach messages, launches and waits appear here. See Calls for the full trace."))
        } else {
            // An NSOutlineView rather than List(children:): on every selection change SwiftUI's outline re-diffed
            // every row, copying each call out of its activity, which took seconds a click on a long trace.
            ActivityOutline(groups: groups, threadNames: threadNames, selection: $selection, followed: followed, follow: follow)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(call.start.map(SyscallTraceView.seconds) ?? "before")  [\(String(call.thread))\(threadName.map { " " + $0 } ?? "")]  \(call.name)(\(call.namedArgsText))")
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
    let followed: UInt64?
    let follow: (UInt64?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = CopyOutlineView()
        outline.headerView = nil
        outline.style = .inset
        outline.allowsMultipleSelection = true
        outline.usesAutomaticRowHeights = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.indentationPerLevel = 14
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("activity"))
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col

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
        private var built: [Item]?

        init(_ id: ActivityRowID, _ kind: Kind) { self.id = id; self.kind = kind }

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
                made = g.calls.map { Item(.call(group: g.id, tid: nil, id: $0.id), .call($0)) }
            case .thread(let gid, let tid, let calls):
                made = calls.map { Item(.call(group: gid, tid: tid, id: $0.id), .call($0)) }
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
            if !loaded || !same || p.threadNames != names { reload(p, o) }
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
            roots = groups.map { Item(.group($0.id), .group($0)) }
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
            let cell = o.makeView(withIdentifier: HostCell.reuse, owner: nil) as? HostCell ?? HostCell()
            switch it.kind {
            case .group(let g):
                cell.content = AnyView(GroupLabel(group: g))
            case .thread(_, let tid, let calls):
                cell.content = AnyView(Text(SyscallActivityView.threadLabel(tid, calls.count, name: names[tid])).font(.callout))
            case .call(let r):
                cell.content = AnyView(ActivityCall(call: r, threadName: names[r.thread]))
            }
            return cell
        }

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

        @objc private func followClicked(_ item: NSMenuItem) { parent?.follow(item.representedObject as? UInt64) }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let o = outline else { return }
            let item = NSMenuItem(title: "Copy", action: #selector(copyClicked), keyEquivalent: "")
            item.target = self
            item.isEnabled = !menuIDs(o).isEmpty
            menu.addItem(item)
            let follow: NSMenuItem
            if parent?.followed != nil {
                follow = NSMenuItem(title: "Show All Threads", action: #selector(followClicked), keyEquivalent: "")
            } else {
                let tids = menuThreads(o)
                guard tids.count == 1, let t = tids.first else { return }
                follow = NSMenuItem(title: "Follow Thread " + SyscallTraceView.thread(t, names), action: #selector(followClicked), keyEquivalent: "")
                follow.representedObject = t
            }
            follow.target = self
            menu.addItem(.separator())
            menu.addItem(follow)
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
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
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
