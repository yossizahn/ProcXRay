import AppKit
import SwiftUI

/// The process's windows and its event taps: what it shows on screen and what input it watches.
/// Both are re-read every 2 s while the tab is shown.
struct WindowsTab: View {
    @Environment(Store.self) var store
    let proc: ProcInfo
    var exited = false

    private struct Loaded: Equatable {
        var key: String
        var windows: WindowList.Reading
        var taps: [EventTaps.Tap]
    }
    @State private var loaded: Loaded?
    @State private var onScreenOnly = false
    /// The last action's failure, shown under the table's header until the next one.
    @State private var actionNote: String?
    /// Bumped after an action, to re-read at once.
    @State private var refresh = 0

    var body: some View {
        let l = loaded?.key == proc.key ? loaded : nil
        VStack(alignment: .leading, spacing: 8) {
            if let l {
                TapsCard(pid: proc.pid, taps: l.taps).padding(.horizontal, 10)
                windows(l.windows)
            } else {
                Text(exited ? "Exited." : "Reading…").foregroundStyle(.secondary).padding(10)
                Spacer()
            }
        }
        .padding(.top, 10)
        .task(id: "\(proc.key)|\(exited)|\(refresh)") {
            guard !exited else { return }
            let pid = proc.pid, start = proc.start, key = proc.key
            while !Task.isCancelled {
                let r = await Task.detached { () -> Loaded? in
                    let w = WindowList.read(pid), t = EventTaps.all()
                    return Native.isSame(pid, start: start) ? Loaded(key: key, windows: w, taps: t) : nil
                }.value
                guard !Task.isCancelled, let r else { return }
                if r != loaded { loaded = r }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder private func windows(_ r: WindowList.Reading) -> some View {
        let rows = onScreenOnly ? r.windows.filter(\.onScreen) : r.windows
        HStack(spacing: 8) {
            Text("Windows").font(.headline)
            Picker("", selection: $onScreenOnly) { Text("All").tag(false); Text("On screen").tag(true) }
                .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
            Spacer()
            Text(verbatim: "\(r.windows.count) windows · \(r.windows.filter(\.onScreen).count) on screen")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Button("Accessibility Tree") { AXTreeWindow.show(pid: proc.pid, name: proc.name) }
                .controlSize(.small).disabled(!r.accessibility || exited)
                .help(r.accessibility ? "Every element of the app, as VoiceOver and automation see it" : "Needs Accessibility permission for Proc X-Ray")
        }
        .padding(.horizontal, 10)
        if let note = permissionNote(r) {
            Text(note).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
        }
        if let actionNote {
            Text(actionNote).font(.caption).foregroundStyle(.orange).padding(.horizontal, 10)
        }
        if rows.isEmpty {
            Text(r.windows.isEmpty ? "No windows." : "No windows on screen.").foregroundStyle(.secondary).padding(.horizontal, 10)
            Spacer()
        } else {
            FastTable(rows: rows, columns: Self.columns, initialSort: ("layer", true),
                      menu: { menu($0, r) }, onOpen: { w in act { WindowActions.raise(pid: proc.pid, window: w.id) } },
                      onSpace: { w in
                          if ScreenshotWindow.isShowing(w.id) { ScreenshotWindow.close() }
                          else if r.screenRecording { screenshot(w, .show) }
                          else { actionNote = "Screenshots need Screen Recording permission for Proc X-Ray." }
                      })
        }
    }

    /// Runs an AX action, noting a failure; re-reads at once so the table shows the result.
    private func act(_ name: String = "That", _ f: () -> Bool) {
        actionNote = f() ? nil : "\(name) didn't work: the app refused, or the window is gone."
        refresh += 1
    }

    private func menu(_ ws: [WindowList.Window], _ r: WindowList.Reading) -> [FastMenuItem] {
        guard let w = ws.first, !exited else { return [] }
        let pid = proc.pid, name = proc.name
        let ax = r.accessibility
        let needs = ax ? "" : " (needs Accessibility)"
        var items: [FastMenuItem] = [
            FastMenuItem(title: "Bring to Front" + needs, enabled: ax) { act("Bring to Front") { WindowActions.raise(pid: pid, window: w.id) } },
            w.minimized == true
                ? FastMenuItem(title: "Restore" + needs, enabled: ax) { act("Restore") { WindowActions.setMinimized(false, pid: pid, window: w.id) } }
                : FastMenuItem(title: "Minimize" + needs, enabled: ax) { act("Minimize") { WindowActions.setMinimized(true, pid: pid, window: w.id) } },
            FastMenuItem(title: "Toggle Full Screen" + needs, enabled: ax) { act("Full screen") { WindowActions.toggleFullScreen(pid: pid, window: w.id) } },
            FastMenuItem(title: "Close" + needs, enabled: ax) { act("Close") { WindowActions.close(pid: pid, window: w.id) } },
            .separator,
        ]
        let hidden = WindowActions.isHidden(pid)
        items.append(FastMenuItem(title: hidden ? "Unhide \(name)" : "Hide \(name)") {
            act(hidden ? "Unhide" : "Hide") { WindowActions.setHidden(!hidden, pid: pid) }
        })
        items.append(FastMenuItem(title: "Show on Screen", enabled: w.onScreen) { ScreenHighlight.flash(w.bounds, seconds: 2.5) })
        items.append(.separator)
        let shot = r.screenRecording ? "" : " (needs Screen Recording)"
        items.append(FastMenuItem(title: "Show Screenshot (Space)" + shot, enabled: r.screenRecording) { screenshot(w, .show) })
        items.append(FastMenuItem(title: "Copy Screenshot" + shot, enabled: r.screenRecording) { screenshot(w, .copy) })
        items.append(FastMenuItem(title: "Save Screenshot…" + shot, enabled: r.screenRecording) { screenshot(w, .save) })
        items.append(.separator)
        items.append(FastMenuItem(title: "Accessibility Tree of This Window" + needs, enabled: ax) {
            AXTreeWindow.show(pid: pid, name: name, window: w.id, title: w.shownTitle)
        })
        items.append(FastMenuItem(title: "Copy Window ID") { ProcessCommands.copy(String(w.id)) })
        return items
    }

    private enum ShotMode { case show, copy, save }

    private func screenshot(_ w: WindowList.Window, _ mode: ShotMode) {
        let name = "\(proc.name) window \(w.id)" + (w.shownTitle.map { " “\($0)”" } ?? "")
        Task { @MainActor in
            do {
                let img = try await WindowActions.screenshot(window: w.id)
                actionNote = nil
                switch mode {
                case .show: ScreenshotWindow.show(img, title: name, windowID: w.id)
                case .copy: try ScreenshotWindow.copy(img)
                case .save: try ScreenshotWindow.save(img, name: name)
                }
            } catch {
                actionNote = "Screenshot failed: \(error.localizedDescription)"
            }
        }
    }

    private func permissionNote(_ r: WindowList.Reading) -> String? {
        switch (r.screenRecording, r.accessibility) {
        case (true, true): nil
        case (false, false): "Titles need Screen Recording or Accessibility permission for Proc X-Ray, capture state needs Screen Recording, role and minimized state need Accessibility."
        case (true, false): "Role and minimized state need Accessibility permission for Proc X-Ray."
        case (false, true): "Capture state, and titles of windows Accessibility doesn't list (other Spaces, the app's private windows), need Screen Recording permission."
        }
    }

    private static let columns: [FastColumn<WindowList.Window>] = {
        let secondary = NSColor.secondaryLabelColor
        func state(_ w: WindowList.Window) -> String {
            if w.minimized == true { return "Minimized" }
            if w.onScreen { return w.alpha == 0 ? "On screen, transparent" : "On screen" }
            return "Hidden"
        }
        return [
            FastColumn(id: "id", title: "ID", width: 60, numeric: true,
                       help: "The window server's window number (CGWindowID)",
                       text: { String($0.id) }, less: { $0.id < $1.id }),
            FastColumn(id: "title", title: "Title", width: 220, text: { $0.shownTitle ?? "—" },
                       color: { $0.shownTitle == nil ? secondary : nil }, tooltip: { $0.shownTitle },
                       less: { ($0.shownTitle ?? "") < ($1.shownTitle ?? "") }),
            FastColumn(id: "layer", title: "Level", width: 110,
                       help: "The window level: which windows it stays above (kCGWindowLayer)",
                       text: { WindowList.layerName($0.layer) }, tooltip: { "kCGWindowLayer \($0.layer)" },
                       less: { ($0.layer, $0.id) < ($1.layer, $1.id) }),
            FastColumn(id: "role", title: "Role", width: 190,
                       help: "What kind of window the app says it is (Accessibility subrole)",
                       text: { $0.subrole.map(Self.roleName) ?? "—" }, color: { $0.subrole == nil ? secondary : nil },
                       tooltip: { $0.subrole }, less: { ($0.subrole ?? "") < ($1.subrole ?? "") }),
            FastColumn(id: "state", title: "State", width: 90, text: state,
                       color: { $0.onScreen && $0.minimized != true ? nil : secondary }, less: { state($0) < state($1) }),
            FastColumn(id: "frame", title: "Position", width: 110, numeric: true, mono: true,
                       help: "Top-left corner in global screen coordinates (origin at the main display's top left)",
                       text: { "\(Int($0.bounds.minX)), \(Int($0.bounds.minY))" },
                       less: { ($0.bounds.minY, $0.bounds.minX) < ($1.bounds.minY, $1.bounds.minX) }),
            FastColumn(id: "size", title: "Size", width: 90, numeric: true, mono: true,
                       text: { "\(Int($0.bounds.width))×\(Int($0.bounds.height))" },
                       less: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }),
            FastColumn(id: "sharing", title: "Capture", width: 90,
                       help: "Whether screenshots and screen capture can see it (kCGWindowSharingState)",
                       text: { w in w.sharing.map { ["Hidden", "Allowed", "Allowed (read-write)"][min(max($0, 0), 2)] } ?? "—" },
                       color: { $0.sharing == 0 ? .systemOrange : $0.sharing == nil ? secondary : nil },
                       tooltip: { $0.sharing == nil ? "Needs Screen Recording permission for Proc X-Ray" : nil },
                       less: { ($0.sharing ?? -1) < ($1.sharing ?? -1) }),
        ]
    }()

    private static func roleName(_ subrole: String) -> String {
        switch subrole {
        case "AXStandardWindow": "Standard (AXStandardWindow)"
        case "AXDialog": "Dialog (AXDialog)"
        case "AXSystemDialog": "System dialog (AXSystemDialog)"
        case "AXFloatingWindow": "Floating panel (AXFloatingWindow)"
        case "AXSystemFloatingWindow": "System panel (AXSystemFloatingWindow)"
        case "AXUnknown": "Unknown (AXUnknown)"
        default: subrole
        }
    }
}

/// The event taps this process installed, and those aimed at it.
private struct TapsCard: View {
    @Environment(Store.self) var store
    let pid: pid_t
    let taps: [EventTaps.Tap]

    var body: some View {
        let mine = taps.filter { $0.tapping == pid }
        let onIt = taps.filter { $0.tapped == pid && $0.tapping != pid }
        // CGGetEventTapList lists every login's taps; one in another GUI login never sees this one's input.
        let session = store.procs[pid]?.asid
        let global = taps.filter { t in
            guard t.tapped == 0, t.tapping != pid else { return false }
            guard let session, let other = store.procs[t.tapping] else { return true }
            return other.asid == nil || other.asid == session || other.session?.kind == .system
        }
        Card(title: "Input taps (Event taps)", trailing: mine.isEmpty ? "none installed" : "\(mine.count) installed") {
            VStack(alignment: .leading, spacing: 6) {
                if mine.isEmpty {
                    Text("This process doesn't watch keyboard or mouse input.").foregroundStyle(.secondary)
                } else {
                    ForEach(mine) { row($0, other: $0.tapped == 0 ? nil : $0.tapped, otherLabel: "watching") }
                }
                if !onIt.isEmpty {
                    Text("Aimed at this process").font(.subheadline).foregroundStyle(.secondary).padding(.top, 2)
                    ForEach(onIt) { row($0, other: $0.tapping, otherLabel: "installed by") }
                }
                if !global.isEmpty {
                    Collapsible(title: "Other processes see all input (\(global.count) tap\(global.count == 1 ? "" : "s"))", startsOpen: false) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(global) { row($0, other: $0.tapping, otherLabel: "installed by") }
                        }
                    }
                }
            }
        }
        .help("CGGetEventTapList: taps see keyboard and mouse events before apps do. A tap that isn't listen-only can also change or drop them.")
    }

    @ViewBuilder private func row(_ t: EventTaps.Tap, other: pid_t?, otherLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if t.seesKeys { Image(systemName: "keyboard").foregroundStyle(.orange).help("Sees keystrokes") }
                Text(t.events)
                Text(t.listenOnly ? "· listen only" : "· can change or drop events")
                    .foregroundStyle(t.listenOnly ? Color.secondary : Color.orange)
                if !t.enabled { Text("· disabled").foregroundStyle(.secondary) }
            }
            HStack(spacing: 6) {
                if let other {
                    Text(otherLabel).foregroundStyle(.secondary)
                    if let p = store.procs[other] { ProcessChip(proc: p) } else { Text(verbatim: "pid \(other)").monospacedDigit() }
                } else {
                    Text("on \(t.placeName)").foregroundStyle(.secondary)
                }
                // The window server's average can be wildly off (minutes, for a tap that barely runs): shown only when plausible.
                if t.avgLatencyUs > 0, t.avgLatencyUs < 1_000_000 {
                    Text(verbatim: String(format: "· %.1f ms average delay", t.avgLatencyUs / 1000)).foregroundStyle(.secondary).monospacedDigit()
                }
                Text(verbatim: "· tap \(t.id)").foregroundStyle(.tertiary).monospacedDigit()
            }
            .font(.caption)
        }
    }
}

/// A window's screenshot in a small floating panel, like Quick Look: Space on a row shows it, Space again
/// closes it, Space on another row replaces it. There is only ever one. Thumbnail-sized at first; resize it to see more. The panel
/// doesn't take keyboard focus, so the table keeps it.
@MainActor
final class ScreenshotWindow: NSObject, NSWindowDelegate {
    private static var current: ScreenshotWindow?
    /// The size the panel opens at; the image is fitted inside it.
    private static let thumbnail = NSSize(width: 360, height: 240)

    let windowID: CGWindowID
    private let image: CGImage
    private let name: String
    private let panel: NSPanel

    /// Whether the preview of `id` is the one on screen.
    static func isShowing(_ id: CGWindowID) -> Bool { current?.windowID == id && current?.panel.isVisible == true }

    static func close() { current?.panel.close() }

    static func show(_ image: CGImage, title: String, windowID: CGWindowID) {
        // Replacing a preview keeps its place on screen.
        let previous = current?.panel.frame
        current?.panel.close()
        let c = ScreenshotWindow(image, title: title, windowID: windowID, near: previous)
        current = c
        c.panel.orderFront(nil)
    }

    struct EncodeError: LocalizedError { var errorDescription: String? { "Couldn't encode the screenshot as PNG." } }

    static func copy(_ image: CGImage) throws {
        guard let png = WindowActions.png(image) else { throw EncodeError() }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
    }

    static func save(_ image: CGImage, name: String) throws {
        guard let png = WindowActions.png(image) else { throw EncodeError() }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-") + ".png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try png.write(to: url)
    }

    private init(_ image: CGImage, title: String, windowID: CGWindowID, near previous: NSRect?) {
        self.image = image
        self.name = title
        self.windowID = windowID
        let bar: CGFloat = 32
        let aspect = CGFloat(image.width) / max(1, CGFloat(image.height))
        // Fit the image in the thumbnail box, never larger than real size.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let box = Self.thumbnail
        var w = min(box.width, CGFloat(image.width) / scale), h = w / aspect
        if h > box.height { h = box.height; w = h * aspect }
        let size = NSSize(width: max(220, w), height: max(60, h) + bar)

        let iv = NSImageView()
        iv.image = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.translatesAutoresizingMaskIntoConstraints = false
        // The image's own size mustn't size the panel (a full-screen window's would open screen-sized).
        for o in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            iv.setContentCompressionResistancePriority(.init(1), for: o)
            iv.setContentHuggingPriority(.init(1), for: o)
        }

        let copy = NSButton(title: "Copy", target: nil, action: #selector(copyImage))
        let save = NSButton(title: "Save…", target: nil, action: #selector(saveImage))
        for b in [copy, save] { b.controlSize = .small; b.bezelStyle = .push }
        let label = NSTextField(labelWithString: "\(image.width) × \(image.height)")
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 11)
        let stack = NSStackView(views: [label, NSView(), copy, save])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        let content = NSView()
        content.addSubview(iv)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            iv.topAnchor.constraint(equalTo: content.topAnchor),
            iv.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            iv.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            iv.bottomAnchor.constraint(equalTo: stack.topAnchor),
            stack.heightAnchor.constraint(equalToConstant: bar),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        // Stays above every app's windows, also while another app is in front: one preview, always in sight.
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = content
        super.init()
        panel.delegate = self
        copy.target = self
        save.target = self
        if let previous {
            // Same top-left corner as the one it replaces.
            panel.setFrameTopLeftPoint(NSPoint(x: previous.minX, y: previous.maxY))
        } else if let key = NSApp.keyWindow {
            // Over the right-hand side of the window it was opened from.
            let f = key.frame
            panel.setFrameTopLeftPoint(NSPoint(x: f.maxX - panel.frame.width - 24, y: f.maxY - 120))
        } else {
            panel.center()
        }
    }

    @objc private func copyImage() { try? Self.copy(image) }
    @objc private func saveImage() { try? Self.save(image, name: name) }

    func windowWillClose(_ notification: Notification) {
        if Self.current === self { Self.current = nil }
    }
}
