import AppKit
import Carbon

/// A running app's AppleScript objects, explored live: an outline from `application` down through its
/// elements (windows, documents, disks…) and the objects its properties point to, with the selected object's
/// properties on the right. Everything is read with Apple Events on a background queue, one object or one
/// page of elements at a time, when it's expanded or selected (ScriptingExplorer).
@MainActor
final class ScriptingExplorerWindow: NSWindowController, NSWindowDelegate {
    private static var open: [ScriptingExplorerWindow] = []

    static func show(pid: pid_t, name: String, dictionary: ScriptingDictionary) {
        if let w = open.first(where: { $0.pid == pid }) { w.window?.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let c = ScriptingExplorerWindow(pid: pid, name: name, model: ScriptingExplorer.Model(dictionary, appName: name))
        open.append(c)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    let pid: pid_t

    /// For testing without a screen: after the root has loaded, expands the first two kinds of elements and
    /// the first object in each, selects the last one expanded, and renders the window to a PNG.
    static func snapshot(pid: pid_t, to path: String) {
        guard let c = open.first(where: { $0.pid == pid }), let ctl = c.window?.contentViewController as? ExplorerController else { return }
        func later(_ s: Double, _ f: @escaping @MainActor () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated(f) } }
        later(3) { ctl.expandForTest(level: 0) }
        later(6) { ctl.expandForTest(level: 1) }
        later(9) {
            guard let v = c.window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    private init(pid: pid_t, name: String, model: ScriptingExplorer.Model) {
        self.pid = pid
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 640),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "AppleScript Objects — \(name) (\(pid))"
        w.isReleasedWhenClosed = false
        w.contentViewController = ExplorerController(pid: pid, name: name, model: model)
        w.center()
        super.init(window: w)
        w.delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) { Self.open.removeAll { $0 === self } }
}

/// One row: an object, a kind of element under an object ("windows (3)"), a "load more" row, or a note.
@MainActor
private final class ObjectNode: NSObject {
    enum Kind { case object, elements, more, note }
    let kind: Kind
    /// The object itself; for `elements` and `more`, the container.
    let spec: NSAppleEventDescriptor
    var title: String
    var subtitle: String
    var elementCode: FourCharCode = 0
    var total: Int?
    weak var group: ObjectNode?

    var children: [ObjectNode]?
    var contents: ScriptingExplorer.Contents?
    var loading = false
    var nextIndex = 1
    lazy var placeholder = ObjectNode(.note, spec: spec, title: "Reading…", subtitle: "")

    init(_ kind: Kind, spec: NSAppleEventDescriptor, title: String, subtitle: String) {
        self.kind = kind; self.spec = spec; self.title = title; self.subtitle = subtitle
    }

    func reset() { children = nil; contents = nil; nextIndex = 1; loading = false }
}

@MainActor
final class ExplorerController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    private let pid: pid_t
    private let name: String
    private let model: ScriptingExplorer.Model
    private let queue: DispatchQueue
    private var root: ObjectNode
    private let outline = NSOutlineView()
    private let detail = NSTextView()
    private let status = NSTextField(wrappingLabelWithString: "Checking permission…")
    private let action = NSButton(title: "", target: nil, action: nil)
    private var permission: ScriptingExplorer.Permission?
    private var menuActions: [() -> Void] = []

    init(pid: pid_t, name: String, model: ScriptingExplorer.Model) {
        self.pid = pid; self.name = name; self.model = model
        queue = DispatchQueue(label: "ScriptingExplorer.\(pid)", qos: .userInitiated)
        root = ObjectNode(.object, spec: ScriptingExplorer.application, title: "application “\(name)”", subtitle: "")
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let col = NSTableColumn(identifier: .init("object"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.rowHeight = 20
        outline.style = .plain
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        let left = NSScrollView()
        left.documentView = outline
        left.hasVerticalScroller = true
        left.hasHorizontalScroller = true

        detail.isEditable = false
        detail.isSelectable = true
        detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detail.textContainerInset = NSSize(width: 8, height: 8)
        detail.isVerticallyResizable = true
        detail.autoresizingMask = [.width]
        detail.string = "Select an object to see its properties. Right-click to copy its reference."
        let right = NSScrollView()
        right.documentView = detail
        right.hasVerticalScroller = true

        let reload = NSButton(title: "Reload", target: self, action: #selector(reloadAll))
        reload.bezelStyle = .accessoryBarAction
        reload.controlSize = .small
        action.bezelStyle = .accessoryBarAction
        action.controlSize = .small
        action.target = self
        action.action = #selector(permissionAction)
        action.isHidden = true
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [reload, action, status])
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(left)
        split.addArrangedSubview(right)
        left.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        right.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        let stack = NSStackView(views: [bar, split])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        split.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        bar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        view = stack
        view.frame = NSRect(x: 0, y: 0, width: 1040, height: 640)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let split = view.subviews.compactMap({ $0 as? NSSplitView }).first { split.setPosition(520, ofDividerAt: 0) }
        checkPermission(ask: false)
    }

    // MARK: Permission

    private func checkPermission(ask: Bool) {
        let pid = pid
        status.stringValue = ask ? "Waiting for your answer to the system's prompt…" : "Checking permission…"
        action.isHidden = true
        queue.async {
            let p = ScriptingExplorer.permission(pid, ask: ask)
            DispatchQueue.main.async { self.permissionChanged(p) }
        }
    }

    private func permissionChanged(_ p: ScriptingExplorer.Permission) {
        permission = p
        action.isHidden = true
        switch p {
        case .allowed:
            status.stringValue = "Reads go to the app as Apple Events, when you expand or select something. Each waits up to \(Int(ScriptingExplorer.timeout)) s."
            outline.reloadData()
            outline.expandItem(root)
            outline.selectRowIndexes([0], byExtendingSelection: false)
        case .notAsked:
            status.stringValue = "Proc X-Ray needs your permission to send Apple Events to \(name) (Automation). macOS asks once."
            action.title = "Ask…"
            action.isHidden = false
        case .denied:
            status.stringValue = "Not allowed: turn on \(name) under Proc X-Ray in System Settings ▸ Privacy & Security ▸ Automation."
            action.title = "Open Settings"
            action.isHidden = false
        case .notRunning:
            status.stringValue = "\(name) isn't running."
        case .other(let e):
            status.stringValue = "Can't tell whether Proc X-Ray may send Apple Events to \(name) (\(e))."
        }
    }

    @objc private func permissionAction() {
        switch permission {
        case .notAsked: checkPermission(ask: true)
        case .denied:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
        default: checkPermission(ask: false)
        }
    }

    @objc private func reloadAll() {
        root.reset()
        outline.reloadData()
        checkPermission(ask: false)
    }

    // MARK: Loading

    private func load(_ n: ObjectNode) {
        guard permission == .allowed, !n.loading else { return }
        switch n.kind {
        case .object:
            guard n.contents == nil else { return }
            n.loading = true
            let pid = pid, spec = n.spec, model = model
            queue.async {
                let c = ScriptingExplorer.contents(pid, spec, model: model)
                DispatchQueue.main.async { self.loaded(n, c) }
            }
        case .elements:
            guard n.children == nil else { return }
            loadPage(n)
        case .more:
            if let g = n.group { loadPage(g) }
        case .note: break
        }
    }

    private func loaded(_ n: ObjectNode, _ c: ScriptingExplorer.Contents) {
        n.loading = false
        n.contents = c
        var kids: [ObjectNode] = []
        if let f = c.failure {
            kids.append(ObjectNode(.note, spec: n.spec, title: failureText(f), subtitle: ""))
        }
        for e in c.elements {
            let g = ObjectNode(.elements, spec: n.spec, title: e.plural, subtitle: "")
            g.elementCode = e.code
            switch e.count {
            case .success(let k):
                if k == 0 { continue }
                g.total = k
                g.subtitle = "\(k)"
            case .failure(let f):
                g.subtitle = "count: \(f.text)"
            }
            kids.append(g)
        }
        for p in c.properties {
            guard let r = p.reference else { continue }
            kids.append(ObjectNode(.object, spec: r, title: p.name, subtitle: ScriptingExplorer.reference(r, model)))
        }
        if n === root, let cl = c.className { n.subtitle = cl }
        n.children = kids
        outline.reloadItem(n, reloadChildren: true)
        if outline.item(atRow: outline.selectedRow) as? ObjectNode === n { showDetail(n) }
    }

    private func loadPage(_ g: ObjectNode) {
        guard !g.loading else { return }
        g.loading = true
        let pid = pid, spec = g.spec, code = g.elementCode, from = g.nextIndex, total = g.total
        queue.async {
            let kids = ScriptingExplorer.children(pid, spec, code, from: from, upTo: total)
            DispatchQueue.main.async { self.pageLoaded(g, kids, from: from) }
        }
    }

    private func pageLoaded(_ g: ObjectNode, _ kids: [ScriptingExplorer.Child], from: Int) {
        g.loading = false
        var list = (g.children ?? []).filter { $0.kind != .more }
        let cls = model.className(g.elementCode)
        for k in kids {
            if let f = k.failure {
                list.append(ObjectNode(.note, spec: k.spec, title: "\(cls) \(k.index): \(f.text)", subtitle: ""))
            } else {
                let title = k.name.map { "\(cls) “\($0)”" } ?? "\(cls) \(k.index)"
                list.append(ObjectNode(.object, spec: k.spec, title: title, subtitle: ScriptingExplorer.reference(k.spec, model)))
            }
        }
        g.nextIndex = from + kids.count
        if kids.count == ScriptingExplorer.pageSize, g.total.map({ g.nextIndex <= $0 }) ?? true {
            let left = g.total.map { " (\($0 - g.nextIndex + 1) left)" } ?? ""
            let more = ObjectNode(.more, spec: g.spec, title: "Read \(ScriptingExplorer.pageSize) more\(left)…", subtitle: "")
            more.group = g
            list.append(more)
        }
        if list.isEmpty { list.append(ObjectNode(.note, spec: g.spec, title: "None.", subtitle: "")) }
        g.children = list
        outline.reloadItem(g, reloadChildren: true)
    }

    private func failureText(_ f: ScriptingExplorer.Failure) -> String {
        // Automation is allowed but the app still refuses: apps holding personal data also check that the
        // sender may read it (measured: Reminders needs Proc X-Ray to have Reminders access too).
        if f.code == -1743, permission == .allowed {
            return "\(name) refused (errAEEventNotPermitted). Automation is allowed, so it also wants Proc X-Ray to have access to its data: Privacy & Security ▸ \(name)."
        }
        return f.text
    }

    /// ScriptingExplorerWindow.snapshot: level 0 expands the root's first two element kinds, level 1 the first
    /// object in each.
    func expandForTest(level: Int) {
        let groups = (root.children ?? []).filter { $0.kind == .elements }.prefix(2)
        if level == 0 { groups.forEach { outline.expandItem($0) }; return }
        for g in groups { if let o = g.children?.first(where: { $0.kind == .object }) { outline.expandItem(o); outline.selectRowIndexes([outline.row(forItem: o)], byExtendingSelection: false) } }
    }

    // MARK: Detail

    private func showDetail(_ n: ObjectNode) {
        switch n.kind {
        case .object:
            var s = "Reference\n  " + (n === root ? "application \"\(name)\"" : ScriptingExplorer.reference(n.spec, model)) + "\n"
            guard let c = n.contents else {
                detail.string = s + "\nReading…"
                load(n)
                return
            }
            if let f = c.failure { detail.string = s + "\n" + failureText(f); return }
            if let cl = c.className { s += "\nClass\n  \(cl)\n" }
            if let note = c.propertiesNote { s += "\n\(note)\n" }
            if !c.properties.isEmpty {
                let w = min(28, c.properties.map(\.name.count).max() ?? 0)
                s += "\nProperties\n"
                for p in c.properties {
                    s += "  " + p.name.padding(toLength: max(w, p.name.count), withPad: " ", startingAt: 0) + "  " + p.text + "\n"
                }
            }
            if !c.elements.isEmpty {
                s += "\nElements\n"
                for e in c.elements {
                    let v: String
                    switch e.count {
                    case .success(let k): v = "\(k)"
                    case .failure(let f): v = f.text
                    }
                    s += "  \(e.plural): \(v)\n"
                }
            }
            detail.string = s
        case .elements:
            detail.string = "every \(model.className(n.elementCode)) of " + ScriptingExplorer.reference(n.spec, model)
                + "\n\n" + (n.total.map { "\($0) in all. Read \(ScriptingExplorer.pageSize) at a time." } ?? n.subtitle)
        case .more:
            load(n)
        case .note:
            detail.string = n.title
        }
    }

    // MARK: Outline

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let n = item as? ObjectNode else { return 1 }
        return n.children?.count ?? 1
    }
    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let n = item as? ObjectNode else { return root }
        return n.children?[index] ?? n.placeholder
    }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let n = item as? ObjectNode, permission == .allowed else { return false }
        switch n.kind {
        case .object: return n.children.map { !$0.isEmpty } ?? true
        case .elements: return true
        case .more, .note: return false
        }
    }
    func outlineViewItemWillExpand(_ notification: Notification) {
        if let n = notification.userInfo?["NSObject"] as? ObjectNode { load(n) }
    }
    func outlineView(_ o: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = o.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = id
            let t = NSTextField(labelWithString: "")
            t.lineBreakMode = .byTruncatingTail
            t.maximumNumberOfLines = 1
            t.cell?.wraps = false
            t.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(t)
            c.textField = t
            NSLayoutConstraint.activate([
                t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                t.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                t.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        guard let n = item as? ObjectNode else { return cell }
        let one = NSMutableParagraphStyle()
        one.lineBreakMode = .byTruncatingTail
        let s = NSMutableAttributedString(string: n.title, attributes: [
            .paragraphStyle: one,
            .font: n.kind == .elements ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 13),
            .foregroundColor: n.kind == .note || n.kind == .more ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])
        if !n.subtitle.isEmpty {
            s.append(NSAttributedString(string: "   " + n.subtitle, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: one]))
        }
        cell.textField?.attributedStringValue = s
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let n = outline.item(atRow: outline.selectedRow) as? ObjectNode else { return }
        showDetail(n)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menuActions = []
        guard outline.clickedRow >= 0, let n = outline.item(atRow: outline.clickedRow) as? ObjectNode else { return }
        func add(_ title: String, _ f: @escaping () -> Void) {
            let mi = NSMenuItem(title: title, action: #selector(picked(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = menuActions.count
            menuActions.append(f)
            menu.addItem(mi)
        }
        let ref = n === root ? "application \"\(name)\"" : ScriptingExplorer.reference(n.spec, model)
        if n.kind == .object {
            add("Copy Reference") { ProcessCommands.copy(ref) }
            let inner = n === root ? "" : " of " + ref.replacingOccurrences(of: " of application \"\(name)\"", with: "")
            add("Copy as AppleScript") { [name] in ProcessCommands.copy("tell application \"\(name)\" to get properties\(inner)") }
            if let c = n.contents {
                add("Copy Properties") { ProcessCommands.copy(c.properties.map { "\($0.name): \($0.text)" }.joined(separator: "\n")) }
            }
        }
        if n.kind == .object || n.kind == .elements {
            menu.addItem(.separator())
            add("Reload") { [weak self] in n.reset(); self?.outline.reloadItem(n, reloadChildren: true); self?.load(n) }
        }
    }
    @objc private func picked(_ sender: NSMenuItem) {
        guard sender.tag < menuActions.count else { return }
        menuActions[sender.tag]()
    }
}
