import AppKit

/// Click a window on screen to find its process, like Process Hacker's "Find window" crosshair. A clear
/// overlay covers every screen; the window under the pointer is outlined with its owner's name and pid, a
/// click picks it, Esc or a right click cancels.
///
/// Uses CGWindowListCopyWindowInfo, which gives every window's owner pid and bounds without Accessibility or
/// Screen Recording permission (only window titles need the latter, and they aren't used). Windows are read
/// once when picking starts, front to back. Two kinds are skipped: WindowServer's own (the menu bar strip) and
/// any window above the normal level that covers a whole screen (the Dock draws itself in one), which would
/// otherwise catch every click.
@MainActor
final class WindowPicker {
    struct Target: Equatable {
        var pid: pid_t
        var owner: String
        var frame: CGRect          // AppKit coordinates (origin at the bottom left of the main screen)
        var title: String?
    }

    private static var current: WindowPicker?

    private var overlays: [NSWindow] = []
    private var targets: [Target] = []
    private let onPick: (pid_t) -> Void
    private var monitors: [Any] = []

    private init(onPick: @escaping (pid_t) -> Void) { self.onPick = onPick }

    /// Starts picking; `onPick` runs with the chosen window's owner pid. Starting again while picking cancels.
    static func start(onPick: @escaping (pid_t) -> Void) {
        if let c = current { c.finish(nil); return }
        let p = WindowPicker(onPick: onPick)
        current = p
        p.begin()
    }

    private func begin() {
        targets = Self.windows()
        for screen in NSScreen.screens {
            let w = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = false
            w.acceptsMouseMovedEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.isReleasedWhenClosed = false
            let v = PickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.screenOrigin = screen.frame.origin
            v.picker = self
            w.contentView = v
            w.setFrame(screen.frame, display: false)
            w.orderFrontRegardless()
            overlays.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
        overlays.first?.makeKey()
        // Keys go to the key window only when the app is active; the local monitor catches Esc either way.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.finish(nil); return nil }
            return e
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { Task { @MainActor in self?.finish(nil) } }
        } as Any)
        NSCursor.crosshair.push()
        moved(to: NSEvent.mouseLocation)
    }

    fileprivate func target(at point: CGPoint) -> Target? { targets.first { $0.frame.contains(point) } }

    fileprivate func moved(to point: CGPoint) {
        let t = target(at: point)
        for w in overlays { (w.contentView as? PickerView)?.show(t) }
    }

    fileprivate func finish(_ t: Target?) {
        NSCursor.pop()
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        for w in overlays { w.orderOut(nil) }
        overlays = []
        Self.current = nil
        if let t { onPick(t.pid) }
    }

    /// Every window on screen that a click could mean, front to back, in AppKit coordinates.
    private static func windows() -> [Target] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let screens = NSScreen.screens.map(\.frame)
        let me = getpid()
        return list.compactMap { w in
            guard let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != me,
                  let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue, layer >= 0,
                  (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let cg = CGRect(dictionaryRepresentation: b), cg.width > 2, cg.height > 2 else { return nil }
            let owner = w[kCGWindowOwnerName as String] as? String ?? "pid \(pid)"
            if owner == "Window Server" { return nil }
            let frame = CGRect(x: cg.minX, y: mainHeight - cg.maxY, width: cg.width, height: cg.height)
            if layer > 0, screens.contains(where: { $0.size == frame.size }) { return nil }
            return Target(pid: pid, owner: owner, frame: frame, title: w[kCGWindowName as String] as? String)
        }
    }
}

private final class PickerView: NSView {
    weak var picker: WindowPicker?
    var screenOrigin: CGPoint = .zero
    private var shown: WindowPicker.Target?
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseMoved(with event: NSEvent) { picker?.moved(to: NSEvent.mouseLocation) }
    override func mouseDown(with event: NSEvent) { picker?.finish(picker?.target(at: NSEvent.mouseLocation)) }
    override func rightMouseDown(with event: NSEvent) { picker?.finish(nil) }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { picker?.finish(nil) } else { super.keyDown(with: event) } }

    func show(_ t: WindowPicker.Target?) {
        guard t != shown else { return }
        shown = t
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // A faint wash, so it's clear picking is on even over empty desktop.
        NSColor.black.withAlphaComponent(0.04).setFill()
        bounds.fill()
        hint()
        guard let t = shown else { return }
        let r = t.frame.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y)
        guard r.intersects(bounds) else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        r.fill()
        let path = NSBezierPath(rect: r.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 3
        NSColor.controlAccentColor.setStroke()
        path.stroke()
        label("\(t.owner)  —  pid \(t.pid)", in: r)
    }

    private func label(_ s: String, in r: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.white]
        let size = (s as NSString).size(withAttributes: attrs)
        let box = CGRect(x: r.midX - size.width / 2 - 10, y: r.midY - size.height / 2 - 6, width: size.width + 20, height: size.height + 12)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        (s as NSString).draw(at: CGPoint(x: box.minX + 10, y: box.minY + 6), withAttributes: attrs)
    }

    private func hint() {
        let s = "Click a window to find its process · Esc to cancel"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let size = (s as NSString).size(withAttributes: attrs)
        let box = CGRect(x: bounds.midX - size.width / 2 - 10, y: bounds.maxY - 60 - size.height, width: size.width + 20, height: size.height + 10)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        (s as NSString).draw(at: CGPoint(x: box.minX + 10, y: box.minY + 5), withAttributes: attrs)
    }
}
