import AppKit
import SwiftUI

/// Which menu bar widget a click landed on. MenuBarExtra reports no click position and the widgets are one image
/// (MenuBarLabel), so: the label records each widget's x range in the image as it renders, and when the popover
/// window becomes key, the mouse's position over the status item says which widget it was opened from.
///
/// Why not the click event itself: measured on macOS 27.2, status item clicks never reach the app as mouse events
/// (the items are hosted by MenuBarAgent; a local monitor saw only appKitDefined events), but the app's
/// NSStatusBarWindow keeps the item's screen frame, and NSEvent.mouseLocation is where the click was.
/// Opened from the keyboard (the mouse isn't over the item), the popover keeps its metric.
@MainActor
@Observable
final class MenuBarHit {
    static let shared = MenuBarHit()

    /// The widget under the mouse when the popover last opened, and a counter so the same widget opened twice
    /// still counts as a new opening.
    private(set) var metric: AmbientMetric?
    private(set) var opens = 0

    /// Works out each widget's x range in the label image, in points, as of the last render; and the image's width.
    /// Measuring renders every widget again, so it's done when the popover opens, not on every render.
    @ObservationIgnored private var ranges: @MainActor () -> [(AmbientMetric, ClosedRange<CGFloat>)] = { [] }
    @ObservationIgnored private var imageWidth: CGFloat = 0
    @ObservationIgnored private var observer: NSObjectProtocol?

    /// Called by the label each time it renders.
    func layout(_ ranges: @escaping @MainActor () -> [(AmbientMetric, ClosedRange<CGFloat>)], imageWidth: CGFloat) {
        if Self.logging, imageWidth != self.imageWidth { NSLog("menubar layout: image %.1f, %@", imageWidth, Self.describe(ranges())) }
        self.ranges = ranges
        self.imageWidth = imageWidth
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { n in
                guard let w = n.object as? NSWindow, String(describing: type(of: w)).hasPrefix("MenuBarExtraWindow") else { return }
                MainActor.assumeIsolated { MenuBarHit.shared.popoverOpened() }
            }
        }
    }

    private func popoverOpened() {
        guard let item = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("StatusBarWindow") }) else { return }
        let mouse = NSEvent.mouseLocation, f = item.frame
        let over = f.insetBy(dx: 0, dy: -2).contains(mouse)
        // The status button centers the image in its window.
        let x = mouse.x - f.minX - (f.width - imageWidth) / 2
        let hit = over ? Self.metric(at: x, in: ranges()) : nil
        if Self.logging {
            NSLog("menubar open: mouse %@, item %@, x in image %.1f -> %@", NSStringFromPoint(mouse), NSStringFromRect(f), x,
                  hit?.rawValue ?? (over ? "none" : "not over the item"))
        }
        guard let hit else { return }
        metric = hit
        opens += 1
    }

    /// The widget under `x`; in the gap between two, the nearer one; outside all of them (the alert sign, the
    /// button's padding), none.
    static func metric(at x: CGFloat, in ranges: [(AmbientMetric, ClosedRange<CGFloat>)]) -> AmbientMetric? {
        if let r = ranges.first(where: { $0.1.contains(x) }) { return r.0 }
        guard let first = ranges.first, let last = ranges.last, x > first.1.lowerBound, x < last.1.upperBound else { return nil }
        return ranges.min { dist(x, $0.1) < dist(x, $1.1) }?.0
    }

    /// PROCXRAY_MENUBAR_HIT_LOG=1: logs the layout and each opening's mapping, for checking it against the screen.
    private static let logging = ProcessInfo.processInfo.environment["PROCXRAY_MENUBAR_HIT_LOG"] != nil
    private static func describe(_ r: [(AmbientMetric, ClosedRange<CGFloat>)]) -> String {
        r.map { String(format: "%@ %.1f…%.1f", $0.0.rawValue, $0.1.lowerBound, $0.1.upperBound) }.joined(separator: ", ")
    }

    private static func dist(_ x: CGFloat, _ r: ClosedRange<CGFloat>) -> CGFloat { x < r.lowerBound ? r.lowerBound - x : x - r.upperBound }
}
