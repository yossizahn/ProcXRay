import AppKit
import SwiftUI

/// Finder, for every path the app shows: a small button next to the path. A file (or a bundle, which Finder
/// shows as one) is revealed, selected in its folder; a folder is gone to, opened in Finder.
enum Reveal {
    static let symbol = "magnifyingglass.circle"
    static let help = "Reveal in Finder"
    static let folderSymbol = "arrow.forward.circle"
    static let folderHelp = "Open in Finder"

    static func reveal(_ paths: [String]) {
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
    }

    /// A plain folder: not a file, and not a package (an .app opened with NSWorkspace.open would launch).
    static func isFolder(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
            && !NSWorkspace.shared.isFilePackage(atPath: path)
    }

    /// Opens a folder in Finder, reveals anything else. selectFile(nil, …) only ever shows a Finder window.
    static func go(_ path: String) {
        if isFolder(path) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) } else { reveal([path]) }
    }

    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    /// The file a displayed value names: an absolute path or a file URL, possibly quoted, to something that
    /// exists. For generic key/value text, where most values aren't paths; nil for anything else.
    static func path(in value: String) -> String? {
        var s = value.trimmingCharacters(in: .whitespaces)
        if s.count >= 2, s.first == "\"", s.last == "\"" { s = String(s.dropFirst().dropLast()) }
        if s.hasPrefix("file://") { s = URL(string: s)?.path ?? "" }
        guard s.count > 1, s.hasPrefix("/"), !s.contains("\n"), exists(s) else { return nil }
        return s
    }

    /// An AppKit button with the same look, for the process table and the info bubble (executables: files).
    @MainActor static func button(target: AnyObject?, action: Selector?) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: help) ?? NSImage(),
                         target: target, action: action)
        b.isBordered = false
        b.imageScaling = .scaleProportionallyDown
        b.contentTintColor = .secondaryLabelColor
        b.setAccessibilityLabel(help)
        b.toolTip = help
        return b
    }
}

/// The button on its own: go to a folder, reveal anything else. A path that doesn't exist (a deleted
/// executable, a moved plist) keeps the button, disabled, so the row doesn't change shape.
struct RevealButton: View {
    let path: String
    var body: some View {
        let exists = Reveal.exists(path)
        let folder = exists && Reveal.isFolder(path)
        let help = folder ? Reveal.folderHelp : Reveal.help
        Button { Reveal.go(path) } label: {
            Image(systemName: folder ? Reveal.folderSymbol : Reveal.symbol)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(!exists)
        .help(exists ? help : "Doesn't exist any more: \(path)")
        .accessibilityLabel(help)
    }
}

/// A path as selectable monospaced text with its reveal button.
struct PathText: View {
    let path: String
    var font: Font = .system(.body, design: .monospaced)
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(verbatim: path).font(font).textSelection(.enabled)
            RevealButton(path: path)
        }
    }
}
