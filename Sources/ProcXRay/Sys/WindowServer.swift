import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// A process's windows, as the window server lists them.
///
/// CGWindowListCopyWindowInfo with `.optionAll` gives every window the process owns: on screen, hidden,
/// minimized and on other Spaces, with its layer, bounds and sharing state, and no permission needed. Only the
/// title (kCGWindowName) needs Screen Recording. Accessibility, when granted, adds what the window server
/// doesn't know: the title the app set, the role (dialog, sheet, floating panel) and whether it's minimized.
/// AX lists only the app's own windows, usually just those on the current Space, so it fills in rows rather
/// than adding them.
enum WindowList {
    struct Window: Identifiable, Sendable, Equatable {
        var id: CGWindowID
        var layer: Int
        var title: String?
        /// Global display coordinates, origin at the top left of the main display.
        var bounds: CGRect
        var onScreen: Bool
        var alpha: Double
        /// kCGWindowSharingState: 0 none (hidden from screenshots and capture), 1 read-only, 2 read-write.
        /// nil without Screen Recording permission: macOS then reports 0 for every other process's window.
        var sharing: Int?
        /// From Accessibility, when it's granted and AX lists this window.
        var subrole: String?
        var minimized: Bool?
        var axTitle: String?

        var shownTitle: String? { [axTitle, title].compactMap { $0 }.first { !$0.isEmpty } }
    }

    struct Reading: Sendable, Equatable {
        var windows: [Window]
        var screenRecording: Bool
        var accessibility: Bool
    }

    static func read(_ pid: pid_t) -> Reading {
        let capture = CGPreflightScreenCaptureAccess()
        let info = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
        var windows: [Window] = info.compactMap { w in
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid,
                  let n = w[kCGWindowNumber as String] as? Int else { return nil }
            var r = CGRect.zero
            if let b = w[kCGWindowBounds as String] as? NSDictionary { r = CGRect(dictionaryRepresentation: b as CFDictionary) ?? .zero }
            return Window(id: CGWindowID(n), layer: w[kCGWindowLayer as String] as? Int ?? 0,
                          title: w[kCGWindowName as String] as? String, bounds: r,
                          onScreen: w[kCGWindowIsOnscreen as String] as? Bool ?? false,
                          alpha: w[kCGWindowAlpha as String] as? Double ?? 1,
                          sharing: capture || pid == getpid() ? w[kCGWindowSharingState as String] as? Int : nil)
        }
        let trusted = AXIsProcessTrusted()
        if trusted { addAccessibility(pid, &windows) }
        return Reading(windows: windows, screenRecording: capture, accessibility: trusted)
    }

    /// `_AXUIElementGetWindow` maps an AX window to its window server id. Private, but stable since 10.x and
    /// the only way to match the two lists; looked up at run time so a missing symbol just skips AX.
    fileprivate typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    fileprivate static let getWindow: GetWindow? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow")
        .map { unsafeBitCast($0, to: GetWindow.self) }

    private static func addAccessibility(_ pid: pid_t, _ windows: inout [Window]) {
        guard let getWindow else { return }
        let app = AXUIElementCreateApplication(pid)
        // A hung app would otherwise hold this read for the default 6 s.
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return }
        for el in list {
            var id: CGWindowID = 0
            guard getWindow(el, &id) == .success, let i = windows.firstIndex(where: { $0.id == id }) else { continue }
            windows[i].axTitle = string(el, kAXTitleAttribute)
            windows[i].subrole = string(el, kAXSubroleAttribute)
            var m: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXMinimizedAttribute as CFString, &m) == .success { windows[i].minimized = m as? Bool }
        }
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v as? String : nil
    }

    /// The window level's name, for the levels CGWindowLevelKey names.
    static func layerName(_ layer: Int) -> String {
        if let n = levelNames[layer] { return n }
        return "level \(layer)"
    }

    private static let levelNames: [Int: String] = {
        let keys: [(CGWindowLevelKey, String)] = [
            (.baseWindow, "Base"), (.minimumWindow, "Minimum"), (.desktopWindow, "Desktop"),
            (.desktopIconWindow, "Desktop icons"), (.backstopMenu, "Backstop menu"), (.normalWindow, "Normal"),
            (.tornOffMenuWindow, "Torn-off menu"), (.floatingWindow, "Floating"), (.modalPanelWindow, "Modal panel"),
            (.utilityWindow, "Utility"), (.dockWindow, "Dock"), (.mainMenuWindow, "Menu bar"),
            (.statusWindow, "Status item"), (.popUpMenuWindow, "Pop-up menu"), (.overlayWindow, "Overlay"),
            (.helpWindow, "Help tag"), (.draggingWindow, "Dragging"), (.screenSaverWindow, "Screen saver"),
            (.assistiveTechHighWindow, "Assistive"), (.cursorWindow, "Cursor"), (.maximumWindow, "Maximum"),
        ]
        var d: [Int: String] = [:]
        // Keys that share a level (floating and torn-off menu) keep the name listed last.
        for (k, n) in keys { d[Int(CGWindowLevelForKey(k))] = n }
        return d
    }()
}

/// Event taps: code that sees (and may change or drop) keyboard and mouse events before apps get them.
/// CGGetEventTapList lists every tap in the session, with the process that installed it and the one it
/// watches (0: all input). Public, and needs no permission to list.
enum EventTaps {
    struct Tap: Identifiable, Sendable, Equatable {
        var id: UInt32
        var tapPoint: UInt32
        var listenOnly: Bool
        var mask: UInt64
        var tapping: pid_t
        var tapped: pid_t
        var enabled: Bool
        var avgLatencyUs: Float

        var placeName: String {
            switch tapPoint {
            case CGEventTapLocation.cghidEventTap.rawValue: "all input, as it enters the window server (HID)"
            case CGEventTapLocation.cgSessionEventTap.rawValue: "the login session's input (Session)"
            case CGEventTapLocation.cgAnnotatedSessionEventTap.rawValue: "input routed to apps (Annotated session)"
            default: "tap point \(tapPoint)"
            }
        }

        /// The kinds of event the mask covers, in plain words.
        var events: String {
            if mask == .max || mask & 0xFFFF_FFFF == 0xFFFF_FFFF { return "All events" }
            func has(_ types: [CGEventType]) -> Bool { types.contains { mask & (1 << UInt64($0.rawValue)) != 0 } }
            var out: [String] = []
            if has([.keyDown, .keyUp]) { out.append("Keystrokes") }
            if has([.flagsChanged]) { out.append("Modifier keys") }
            if has([.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]) { out.append("Clicks") }
            if has([.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { out.append("Pointer movement") }
            if has([.scrollWheel]) { out.append("Scrolling") }
            if has([.tabletPointer, .tabletProximity]) { out.append("Tablet") }
            if mask & (1 << 14) != 0 { out.append("System keys (media, brightness)") }   // NX_SYSDEFINED
            if mask & ((1 << 29) | (1 << 30) | (1 << 31)) != 0 { out.append("Gestures") }
            return out.isEmpty ? String(format: "mask 0x%llx", mask) : out.joined(separator: ", ")
        }

        /// Whether it can read what's typed.
        var seesKeys: Bool { mask & ((1 << UInt64(CGEventType.keyDown.rawValue)) | (1 << UInt64(CGEventType.keyUp.rawValue))) != 0 }
    }

    static func all() -> [Tap] {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return [] }
        var list = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &list, &count) == .success else { return [] }
        return list.prefix(Int(count)).map {
            Tap(id: $0.eventTapID, tapPoint: $0.tapPoint.rawValue, listenOnly: $0.options == .listenOnly,
                mask: $0.eventsOfInterest, tapping: $0.tappingProcess, tapped: $0.processBeingTapped,
                enabled: $0.enabled, avgLatencyUs: $0.avgUsecLatency)
        }
    }
}

/// What can be done to another process's window. Raise, minimize, close and full screen go through
/// Accessibility (the window server takes no orders from other apps); hiding is the app's, through
/// NSRunningApplication; a screenshot is ScreenCaptureKit's, and needs Screen Recording.
@MainActor
enum WindowActions {
    /// The window's AX element, matched by window number among the app's AX windows.
    static func element(pid: pid_t, window id: CGWindowID) -> AXUIElement? {
        guard AXIsProcessTrusted(), let getWindow = WindowList.getWindow else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return nil }
        return list.first { el in
            var n: CGWindowID = 0
            return getWindow(el, &n) == .success && n == id
        }
    }

    /// Brings the window to the front and activates its app (un-minimizing it first).
    @discardableResult
    static func raise(pid: pid_t, window id: CGWindowID) -> Bool {
        guard let el = element(pid: pid, window: id) else { return false }
        AXUIElementSetAttributeValue(el, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        let ok = AXUIElementPerformAction(el, kAXRaiseAction as CFString) == .success
        NSRunningApplication(processIdentifier: pid)?.activate()
        return ok
    }

    @discardableResult
    static func setMinimized(_ on: Bool, pid: pid_t, window id: CGWindowID) -> Bool {
        guard let el = element(pid: pid, window: id) else { return false }
        return AXUIElementSetAttributeValue(el, kAXMinimizedAttribute as CFString, on ? kCFBooleanTrue : kCFBooleanFalse) == .success
    }

    /// Presses the window's close button, as a click would: the app may ask to save first.
    @discardableResult
    static func close(pid: pid_t, window id: CGWindowID) -> Bool {
        guard let el = element(pid: pid, window: id) else { return false }
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXCloseButtonAttribute as CFString, &button) == .success,
              let b = button, CFGetTypeID(b) == AXUIElementGetTypeID() else { return false }
        return AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString) == .success
    }

    @discardableResult
    static func toggleFullScreen(pid: pid_t, window id: CGWindowID) -> Bool {
        guard let el = element(pid: pid, window: id) else { return false }
        var v: CFTypeRef?
        let on = AXUIElementCopyAttributeValue(el, "AXFullScreen" as CFString, &v) == .success && (v as? Bool) == true
        return AXUIElementSetAttributeValue(el, "AXFullScreen" as CFString, on ? kCFBooleanFalse : kCFBooleanTrue) == .success
    }

    static func isHidden(_ pid: pid_t) -> Bool { NSRunningApplication(processIdentifier: pid)?.isHidden ?? false }

    @discardableResult
    static func setHidden(_ on: Bool, pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return on ? app.hide() : app.unhide()
    }

    enum ScreenshotError: LocalizedError {
        case permission, notFound
        var errorDescription: String? {
            switch self {
            case .permission: "Taking a screenshot of another app's window needs Screen Recording permission for Proc X-Ray (System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording)."
            case .notFound: "ScreenCaptureKit doesn't list this window: it may be minimized, hidden, or gone."
            }
        }
    }

    /// The window alone, at the display's pixel scale, even when other windows cover it.
    static func screenshot(window id: CGWindowID) async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else { throw ScreenshotError.permission }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let w = content.windows.first(where: { $0.windowID == id }) else { throw ScreenshotError.notFound }
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = max(1, Int(filter.contentRect.width * scale))
        config.height = max(1, Int(filter.contentRect.height * scale))
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

/// A brief outline around a screen rectangle (global coordinates, origin at the top left of the main
/// display), to show which window or element a row means.
@MainActor
enum ScreenHighlight {
    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?

    static func flash(_ rect: CGRect, seconds: Double = 1.2) {
        guard rect.width > 0, rect.height > 0 else { return }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        var frame = CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height).insetBy(dx: -3, dy: -3)
        // Kept on the screen it's on: a full-screen window's outline would otherwise sit just off its edges.
        if let screen = NSScreen.screens.map(\.frame).max(by: { $0.intersection(frame).area < $1.intersection(frame).area }),
           screen.intersects(frame) {
            frame = frame.intersection(screen)
        }
        let p = panel ?? {
            let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .screenSaver
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.isReleasedWhenClosed = false
            let v = NSView()
            v.wantsLayer = true
            v.layer?.borderColor = NSColor.systemRed.cgColor
            v.layer?.borderWidth = 3
            v.layer?.cornerRadius = 4
            v.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.08).cgColor
            p.contentView = v
            panel = p
            return p
        }()
        p.setFrame(frame, display: true)
        p.orderFrontRegardless()
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            panel?.orderOut(nil)
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
