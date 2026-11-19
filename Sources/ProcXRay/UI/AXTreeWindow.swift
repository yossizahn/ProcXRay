import AppKit
import ApplicationServices

/// An app's (or one window's) accessibility tree: what VoiceOver and automation see. The outline loads each
/// element's children when it's expanded, since a browser or Xcode can have tens of thousands; the pane on the
/// right lists the selected element's attributes and actions, and selecting an element outlines it on screen.
/// The context menu performs the element's actions (press, raise, show menu…).
@MainActor
final class AXTreeWindow: NSWindowController, NSWindowDelegate {
    private static var open: [AXTreeWindow] = []

    /// Opens a tree rooted at the app, or at one of its windows.
    static func show(pid: pid_t, name: String, window: CGWindowID? = nil, title: String? = nil) {
        let root: AXUIElement
        if let window, let el = WindowActions.element(pid: pid, window: window) {
            root = el
        } else {
            root = AXUIElementCreateApplication(pid)
        }
        let label = window.map { "\(name) — window \($0)" + (title.map { " “\($0)”" } ?? "") } ?? name
        let c = AXTreeWindow(root: root, title: "Accessibility Tree — \(label)")
        open.append(c)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private let tree: AXTreeController

    private init(root: AXUIElement, title: String) {
        tree = AXTreeController(root: AXNode(root))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.contentViewController = tree
        w.center()
        super.init(window: w)
        w.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }
}

/// One element of the tree. Its label and children are read once, when first needed.
@MainActor
final class AXNode: NSObject {
    let element: AXUIElement
    private var loaded: [AXNode]?

    init(_ element: AXUIElement) {
        self.element = element
        // A hung app would hold each read for the default 6 s.
        AXUIElementSetMessagingTimeout(element, 0.5)
    }

    var children: [AXNode] {
        if let loaded { return loaded }
        var v: CFTypeRef?
        let list = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &v) == .success ? (v as? [AXUIElement]) ?? [] : []
        let nodes = list.map(AXNode.init)
        loaded = nodes
        return nodes
    }

    func reload() { loaded = nil; _label = nil }

    var childCount: Int {
        if let loaded { return loaded.count }
        var n: CFIndex = 0
        return AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &n) == .success ? n : 0
    }

    func string(_ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private var _label: String?
    /// "Button  “Save”  (AXButton)": the role's description first, then the element's own text.
    var label: String {
        if let _label { return _label }
        let role = string(kAXRoleAttribute) ?? "?"
        let sub = string(kAXSubroleAttribute)
        let kind = string(kAXRoleDescriptionAttribute) ?? role
        var text = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXIdentifierAttribute]
            .lazy.compactMap { self.string($0) }.first { !$0.isEmpty }
        if let t = text, t.count > 80 { text = String(t.prefix(80)) + "…" }
        let term = sub.map { "\(role), \($0)" } ?? role
        let l = kind.capitalizedFirst + (text.map { "  “\($0.replacingOccurrences(of: "\n", with: " "))”" } ?? "") + "  (\(term))"
        _label = l
        return l
    }

    /// The element's frame in global coordinates (top-left origin), when it has a position and size.
    var frame: CGRect? {
        func value<T>(_ attr: String, _ type: AXValueType, _ empty: T) -> T? {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attr as CFString, &v) == .success, let v,
                  CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
            var out = empty
            return AXValueGetValue(v as! AXValue, type, &out) ? out : nil
        }
        guard let p = value(kAXPositionAttribute, .cgPoint, CGPoint.zero), let s = value(kAXSizeAttribute, .cgSize, CGSize.zero) else { return nil }
        return CGRect(origin: p, size: s)
    }

    var actions: [String] {
        var v: CFArray?
        guard AXUIElementCopyActionNames(element, &v) == .success else { return [] }
        return (v as? [String]) ?? []
    }

    /// Every attribute and its value, one per line, then the actions.
    var details: String {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success, let list = names as? [String] else {
            return "The element no longer answers (it may be gone)."
        }
        var lines: [String] = []
        let width = list.map(\.count).max() ?? 0
        for n in list.sorted() {
            var v: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(element, n as CFString, &v)
            let shown = err == .success ? Self.describe(v) : "(\(Self.errorName(err)))"
            lines.append(n.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + shown)
        }
        let acts = actions
        if !acts.isEmpty {
            lines.append("")
            lines.append("Actions")
            for a in acts {
                var d: CFString?
                let desc = AXUIElementCopyActionDescription(element, a as CFString, &d) == .success ? (d as String?) : nil
                lines.append("  " + a + (desc.map { $0 != a ? "  — \($0)" : "" } ?? ""))
            }
        }
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success { lines.append(""); lines.append("pid \(pid)") }
        return lines.joined(separator: "\n")
    }

    static func describe(_ v: CFTypeRef?) -> String {
        guard let v else { return "nil" }
        let type = CFGetTypeID(v)
        if type == AXUIElementGetTypeID() {
            let n = AXNode(v as! AXUIElement)
            return "<" + (n.string(kAXRoleAttribute) ?? "element") + (n.string(kAXTitleAttribute).map { " “\($0)”" } ?? "") + ">"
        }
        if type == AXValueGetTypeID() {
            let a = v as! AXValue
            switch AXValueGetType(a) {
            case .cgPoint: var p = CGPoint.zero; AXValueGetValue(a, .cgPoint, &p); return "x \(Int(p.x)), y \(Int(p.y))"
            case .cgSize: var s = CGSize.zero; AXValueGetValue(a, .cgSize, &s); return "\(Int(s.width)) × \(Int(s.height))"
            case .cgRect: var r = CGRect.zero; AXValueGetValue(a, .cgRect, &r); return "x \(Int(r.minX)), y \(Int(r.minY)), \(Int(r.width)) × \(Int(r.height))"
            case .cfRange: var r = CFRange(); AXValueGetValue(a, .cfRange, &r); return "location \(r.location), length \(r.length)"
            default: return "\(a)"
            }
        }
        if type == CFBooleanGetTypeID() { return (v as! Bool) ? "true" : "false" }
        if let s = v as? String { return "“" + (s.count > 300 ? String(s.prefix(300)) + "…" : s).replacingOccurrences(of: "\n", with: "⏎") + "”" }
        if let n = v as? NSNumber { return n.stringValue }
        if let a = v as? [Any] {
            if a.isEmpty { return "[]" }
            if a.count <= 4 { return "[" + a.map { describe($0 as CFTypeRef) }.joined(separator: ", ") + "]" }
            return "\(a.count) items"
        }
        if let u = v as? URL { return u.absoluteString }
        return String(describing: v)
    }

    static func errorName(_ e: AXError) -> String {
        switch e {
        case .noValue: "no value"
        case .attributeUnsupported: "unsupported"
        case .cannotComplete: "no answer"
        case .invalidUIElement: "element gone"
        case .apiDisabled: "Accessibility not allowed"
        default: "error \(e.rawValue)"
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

@MainActor
private final class AXTreeController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    private let root: AXNode
    private let outline = NSOutlineView()
    private let detail = NSTextView()
    private var menuActions: [() -> Void] = []

    init(root: AXNode) {
        self.root = root
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let col = NSTableColumn(identifier: .init("element"))
        col.title = "Element"
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.rowHeight = 20
        outline.usesAutomaticRowHeights = false
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
        detail.string = "Select an element to see its attributes. Right-click an element to perform its actions."
        let right = NSScrollView()
        right.documentView = detail
        right.hasVerticalScroller = true

        let reload = NSButton(title: "Reload", target: self, action: #selector(reloadAll))
        reload.bezelStyle = .accessoryBarAction
        reload.controlSize = .small
        let note = NSTextField(labelWithString: "Selecting an element outlines it on screen.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let bar = NSStackView(views: [reload, note])
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(left)
        split.addArrangedSubview(right)
        left.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        right.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true

        let stack = NSStackView(views: [bar, split])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        split.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        view = stack
        view.frame = NSRect(x: 0, y: 0, width: 980, height: 620)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let split = view.subviews.compactMap({ $0 as? NSSplitView }).first { split.setPosition(560, ofDividerAt: 0) }
        outline.reloadData()
        outline.expandItem(root)
    }

    @objc private func reloadAll() {
        func reset(_ n: AXNode) { n.reload() }
        reset(root)
        outline.reloadData()
        outline.expandItem(root)
    }

    // MARK: Data

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let n = item as? AXNode else { return 1 }
        return n.children.count
    }
    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let n = item as? AXNode else { return root }
        return n.children[index]
    }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? AXNode)?.childCount ?? 0 > 0
    }
    func outlineView(_ o: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = o.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = id
            let t = NSTextField(labelWithString: "")
            t.lineBreakMode = .byTruncatingTail
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
        cell.textField?.stringValue = (item as? AXNode)?.label ?? ""
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let n = outline.item(atRow: outline.selectedRow) as? AXNode else { return }
        detail.string = n.details
        if let f = n.frame { ScreenHighlight.flash(f) }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menuActions = []
        guard outline.clickedRow >= 0, let n = outline.item(atRow: outline.clickedRow) as? AXNode else { return }
        func add(_ title: String, _ action: @escaping () -> Void) {
            let mi = NSMenuItem(title: title, action: #selector(picked(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = menuActions.count
            menuActions.append(action)
            menu.addItem(mi)
        }
        for a in n.actions {
            add("Perform \(a)") { [weak self] in
                let err = AXUIElementPerformAction(n.element, a as CFString)
                if err != .success { self?.detail.string = "\(a) failed: \(AXNode.errorName(err))\n\n" + n.details }
            }
        }
        if !n.actions.isEmpty { menu.addItem(.separator()) }
        if let f = n.frame { add("Show on Screen") { ScreenHighlight.flash(f, seconds: 2.5) } }
        add("Copy Attributes") { ProcessCommands.copy(n.label + "\n" + n.details) }
        add("Reload Children") { [weak self] in n.reload(); self?.outline.reloadItem(n, reloadChildren: true) }
    }

    @objc private func picked(_ sender: NSMenuItem) {
        guard sender.tag < menuActions.count else { return }
        menuActions[sender.tag]()
    }
}
