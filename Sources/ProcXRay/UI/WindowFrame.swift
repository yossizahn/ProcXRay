import AppKit
import SwiftUI

/// Reopens the main window on the screen it was on, as AppKit apps do.
///
/// SwiftUI autosaves the frame (with its screen) under "<scene id>-AppWindow-1" and restores the size and position
/// from it, but always on the main screen. So the saved frame is applied once more after the window is up. It's read
/// before that, since by then the autosave has already recorded SwiftUI's placement.
struct RestoreWindowScreen: NSViewRepresentable {
    let sceneID: String

    func makeNSView(context: Context) -> NSView { Probe(key: "NSWindow Frame \(sceneID)-AppWindow-1") }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        let key: String
        var done = false
        init(key: String) { self.key = key; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !done, let window, let saved = UserDefaults.standard.string(forKey: key) else { return }
            done = true
            // Only the window that owns this autosave slot (a ⌘N window gets "-AppWindow-2" and its own frame).
            guard window.identifier?.rawValue.hasSuffix("-AppWindow-1") ?? true else { return }
            // "x y w h  screenX screenY screenW screenH": the window's frame, then its screen's visible frame.
            let n = saved.split(separator: " ").compactMap { Double($0) }
            guard n.count >= 8 else { return }
            let frame = NSRect(x: n[0], y: n[1], width: n[2], height: n[3])
            let savedScreen = NSRect(x: n[4], y: n[5], width: n[6], height: n[7])
            // Only when that screen is still connected (and isn't the main one, where SwiftUI already put it right).
            guard let screen = NSScreen.screens.first(where: { $0.visibleFrame == savedScreen }), screen != NSScreen.main
            else { return }
            // setFrame(from:) would constrain the rect to the window's current (main) screen, so set it directly.
            DispatchQueue.main.async { [weak window] in window?.setFrame(frame, display: true) }
        }
    }
}
