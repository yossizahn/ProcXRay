import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Which paths get an Inspect button: a file whose first bytes are a Mach-O, fat or archive header, or a
/// bundle (an .app, .framework, .xpc, .appex, .dext…), which counts as its main executable. Cached per path
/// and modification time, so rows that redraw don't reread the file.
enum MachOProbe {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (mtime: Int, target: String?)] = [:]

    /// The Mach-O file to open for `path`, or nil if it isn't one.
    static func target(_ path: String) -> String? {
        var st = stat()
        guard path.hasPrefix("/"), stat(path, &st) == 0 else { return nil }
        let mtime = st.st_mtimespec.tv_sec
        lock.lock()
        if let c = cache[path], c.mtime == mtime { lock.unlock(); return c.target }
        lock.unlock()
        let t: String?
        if st.st_mode & S_IFMT == S_IFDIR {
            let ext = (path as NSString).pathExtension
            if ext == "framework" || NSWorkspace.shared.isFilePackage(atPath: path),
               let exe = Bundle(path: path)?.executablePath, isMachO(exe) { t = exe } else { t = nil }
        } else if st.st_mode & S_IFMT == S_IFREG, st.st_size >= 8 {
            t = isMachO(path) ? path : nil
        } else {
            t = nil
        }
        lock.lock(); cache[path] = (mtime, t); lock.unlock()
        return t
    }

    static func isMachO(_ path: String) -> Bool {
        guard let h = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? h.close() }
        return MachOParser.looksLikeMachO([UInt8](h.readData(ofLength: 8)))
    }
}

/// Opening a binary's inspector window, from SwiftUI (with its openWindow) or AppKit (the one kept in
/// AppRouter by every main and inspector window).
enum MachOOpen {
    static let symbol = "doc.viewfinder"
    static let help = "Inspect binary"

    /// Files opened before any window could open one (a launch from Open With or a Dock drop).
    @MainActor static var pending: [MachORef] = []

    @MainActor static func open(_ path: String, executable: String? = nil, _ openWindow: OpenWindowAction? = nil) {
        guard let open = openWindow ?? AppRouter.openWindow else { pending.append(MachORef(path: path, executable: executable)); return }
        // openWindow calls close together (several files opened at once) drop all but the last, so they are
        // spaced out.
        let now = Date()
        let at = max(now, nextOpen)
        nextOpen = at.addingTimeInterval(0.15)
        let go = {
            AppActivation.willShowWindow()
            open(id: MachOWindow.id, value: MachORef(path: path, executable: executable))
            NSApp.activate(ignoringOtherApps: true)
        }
        if at <= now { go() } else { DispatchQueue.main.asyncAfter(deadline: .now() + at.timeIntervalSince(now)) { go() } }
    }
    @MainActor private static var nextOpen = Date.distantPast
    /// No window opens for `seconds` (another one is being opened outside MachOOpen).
    @MainActor static func holdOpens(_ seconds: TimeInterval) { nextOpen = max(nextOpen, Date().addingTimeInterval(seconds)) }

    /// File ▸ Open Binary…: any file; a bundle opens its executable.
    @MainActor static func openPanel(_ openWindow: OpenWindowAction? = nil) {
        let p = NSOpenPanel()
        p.title = "Open Binary"
        p.message = "Choose a Mach-O file, an app or a framework to inspect."
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.treatsFilePackagesAsDirectories = false
        p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return }
        for u in p.urls { openAny(u.path, openWindow) }
    }

    /// Opens what `path` names if it's a Mach-O (or a bundle with one); otherwise says why not.
    @MainActor static func openAny(_ path: String, _ openWindow: OpenWindowAction? = nil) {
        // Files opened with the app all come here: a saved trace opens in its own window.
        if SavedTraceFiles.isTrace(path) { SavedTraceFiles.open(path, openWindow); return }
        if let t = MachOProbe.target(path) { open(t, executable: nil, openWindow); return }
        let a = NSAlert()
        a.messageText = "Not a Mach-O file"
        a.informativeText = "\(path) isn't a Mach-O, universal or static-archive file, or a bundle with an executable."
        a.runModal()
    }

    /// An AppKit button with the Inspect look, for the process table and the info bubble.
    @MainActor static func button(target: AnyObject?, action: Selector?) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: help) ?? NSImage(), target: target, action: action)
        b.isBordered = false
        b.imageScaling = .scaleProportionallyDown
        b.contentTintColor = .secondaryLabelColor
        b.setAccessibilityLabel(help)
        b.toolTip = help
        return b
    }
}

/// The button next to a path: shown only when the path is (or is a bundle with) a Mach-O.
struct InspectBinaryButton: View {
    let path: String
    /// The main executable, when the binary is a library of a known process (for @executable_path).
    var executable: String? = nil
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let target = MachOProbe.target(path) {
            Button { MachOOpen.open(target, executable: executable, openWindow) } label: { Image(systemName: MachOOpen.symbol) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(target == path ? MachOOpen.help : "\(MachOOpen.help): \(target)")
                .accessibilityLabel(MachOOpen.help)
        }
    }
}

/// File ▸ Open Binary… (⇧⌘O).
struct OpenBinaryCommand: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Binary…") { MachOOpen.openPanel(openWindow) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
    }
}

/// Keeps AppRouter.openWindow set from any window, so AppKit code and the app delegate can open windows
/// whether or not the menu bar item exists.
struct KeepOpenWindow: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        let _ = AppRouter.openWindow = openWindow
        content.onAppear {
            let refs = MachOOpen.pending
            MachOOpen.pending = []
            for r in refs { MachOOpen.open(r.path, executable: r.executable, openWindow) }
        }
    }
}
