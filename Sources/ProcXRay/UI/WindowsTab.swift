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
                      menu: { menu($0, r) }, onOpen: { w in act { WindowActions.raise(pid: proc.pid, window: w.id) } })
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
        items.append(FastMenuItem(title: "Show Screenshot" + shot, enabled: r.screenRecording) { screenshot(w, .show) })
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
                case .show: ScreenshotWindow.show(img, title: name)
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
            FastColumn(id: "role", title: "Role", width: 110,
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

/// A window screenshot in a window of its own, at its real size (scaled down to fit the screen), with Copy and Save.
@MainActor
final class ScreenshotWindow: NSWindowController, NSWindowDelegate {
    private static var open: [ScreenshotWindow] = []
    private let image: CGImage
    private let name: String

    static func show(_ image: CGImage, title: String) {
        let c = ScreenshotWindow(image, title: title)
        open.append(c)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
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

    private init(_ image: CGImage, title: String) {
        self.image = image
        self.name = title
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let scale = screen.backingScaleFactor
        let natural = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let limit = NSSize(width: screen.visibleFrame.width * 0.8, height: screen.visibleFrame.height * 0.8 - 40)
        let fit = min(1, limit.width / natural.width, limit.height / natural.height)
        let shown = NSSize(width: max(200, natural.width * fit), height: max(80, natural.height * fit))

        let iv = NSImageView()
        iv.image = NSImage(cgImage: image, size: natural)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.translatesAutoresizingMaskIntoConstraints = false

        let copy = NSButton(title: "Copy", target: nil, action: #selector(copyImage))
        let save = NSButton(title: "Save…", target: nil, action: #selector(saveImage))
        let size = NSTextField(labelWithString: "\(image.width) × \(image.height) pixels")
        size.textColor = .secondaryLabelColor
        size.font = .systemFont(ofSize: 11)
        let bar = NSStackView(views: [size, NSView(), copy, save])
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)

        let content = NSView()
        content.addSubview(iv)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            iv.topAnchor.constraint(equalTo: content.topAnchor),
            iv.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            iv.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            iv.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        let w = NSWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: shown.width, height: shown.height + 40)),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Screenshot — " + title
        w.isReleasedWhenClosed = false
        w.contentView = content
        w.center()
        super.init(window: w)
        w.delegate = self
        copy.target = self
        save.target = self
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func copyImage() { try? Self.copy(image) }
    @objc private func saveImage() { try? Self.save(image, name: name) }

    func windowWillClose(_ notification: Notification) { Self.open.removeAll { $0 === self } }
}
