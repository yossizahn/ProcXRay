import AppKit
import SwiftUI

/// What one inspector (the pane, or a process window) has shown, newest last, like a browser's
/// history. Entries keep the last snapshot of their process, so going back to one that has exited
/// still shows what it was.
@MainActor
@Observable
final class InspectorNavigation {
    struct Entry {
        var proc: ProcInfo
        /// Signing details seen while it ran; the store drops them once the process is gone.
        var sign: SignInfo?
    }

    private(set) var entries: [Entry] = []
    private(set) var index = -1
    static let limit = 100

    var current: Entry? { entries.indices.contains(index) ? entries[index] : nil }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index < entries.count - 1 }
    var backTitle: String? { canGoBack ? entries[index - 1].proc.name : nil }
    var forwardTitle: String? { canGoForward ? entries[index + 1].proc.name : nil }

    /// Shows `p`, dropping anything forward of the current entry. Showing the current process again is a no-op.
    func push(_ p: ProcInfo) {
        if current?.proc.key == p.key { return }
        if index + 1 < entries.count { entries.removeSubrange((index + 1)...) }
        entries.append(Entry(proc: p))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        index = entries.count - 1
    }

    func back() { if canGoBack { index -= 1 } }
    func forward() { if canGoForward { index += 1 } }

    /// Keeps the current entry's snapshot (and signature) up to date while its process runs.
    func update(_ p: ProcInfo, sign: SignInfo?) {
        guard entries.indices.contains(index), entries[index].proc.key == p.key else { return }
        // A changed codeKey means the process exec'd: its old signature no longer applies.
        if entries[index].proc.codeKey != p.codeKey { entries[index].sign = nil }
        if entries[index].proc != p { entries[index].proc = p }
        if let sign { entries[index].sign = sign }
    }
}

extension Store {
    /// `p`'s process if it's still running: same pid *and* start time (a pid can be reused).
    func live(_ p: ProcInfo) -> ProcInfo? {
        procs[p.pid].flatMap { $0.start == p.start ? $0 : nil }
    }
}

/// How links inside an inspector act: follow one, or move through the history. Set by the view that
/// hosts the inspector; the pane also selects the shown process in the tree.
@MainActor
struct InspectorLinks {
    let nav: InspectorNavigation
    /// Runs after the inspector moved to another process (the pane selects it in the tree).
    var onShow: (ProcInfo) -> Void = { _ in }

    func open(_ p: ProcInfo) { nav.push(p); onShow(p) }
    func back() { nav.back(); if let p = nav.current?.proc { onShow(p) } }
    func forward() { nav.forward(); if let p = nav.current?.proc { onShow(p) } }
}

private struct InspectorLinksKey: EnvironmentKey {
    static let defaultValue: InspectorLinks? = nil
}

extension EnvironmentValues {
    var inspectorLinks: InspectorLinks? {
        get { self[InspectorLinksKey.self] }
        set { self[InspectorLinksKey.self] = newValue }
    }
}

/// Shows the history's current process: live while it runs, its last snapshot (with a banner) once
/// it has exited. Owns the snapshot bookkeeping shared by the pane and process windows.
struct InspectorHost<Placeholder: View>: View {
    @Environment(Store.self) var store
    let links: InspectorLinks
    @ViewBuilder var placeholder: () -> Placeholder

    var body: some View {
        if let e = links.nav.current {
            let live = store.live(e.proc)
            VStack(spacing: 0) {
                if live == nil {
                    Text("This process has exited. Showing its last known state.")
                        .font(.callout).frame(maxWidth: .infinity).padding(6)
                        .background(.orange.opacity(0.2))
                }
                InspectorView(proc: live ?? e.proc, exited: live == nil, lastSign: e.sign)
            }
            .environment(\.inspectorLinks, links)
            .onChange(of: live, initial: true) { _, p in
                if let p { links.nav.update(p, sign: store.signInfo(for: p)) }
            }
            // Signing details load a moment after the process appears.
            .onChange(of: live.map { "\($0.codeKey)|\(store.signInfo(for: $0) != nil)" }) { _, _ in
                if let p = live { links.nav.update(p, sign: store.signInfo(for: p)) }
            }
        } else {
            placeholder()
        }
    }
}

// MARK: - Process chip

/// A link to a process: icon, name and pid. Click shows it in this inspector (and, in the pane,
/// selects it in the tree); ⌘-click opens it in its own window. Hovering shows its path, user, CPU
/// and memory. A process that has exited (or whose pid now belongs to another) is struck through and
/// does nothing.
struct ProcessChip: View {
    @Environment(Store.self) var store
    @Environment(\.inspectorLinks) private var links
    @Environment(\.openWindow) private var openWindow
    /// The process as last seen; it's live only while the same pid and start time are running.
    let proc: ProcInfo

    var body: some View {
        let live = store.live(proc)
        let p = live ?? proc
        Button {
            guard let live else { return }
            if NSEvent.modifierFlags.contains(.command) || links == nil {
                openWindow(id: ProcessWindow.id, value: ProcessRef(live))
            } else {
                links?.open(live)
            }
        } label: {
            HStack(spacing: 4) {
                Group {
                    if let img = IconCache.icon(for: p) { Image(nsImage: img).resizable() } else { Image(systemName: "terminal") }
                }
                .frame(width: 14, height: 14)
                Text(verbatim: p.name).lineLimit(1).strikethrough(live == nil)
                Text(verbatim: "\(p.pid)").monospacedDigit().foregroundStyle(.secondary).strikethrough(live == nil)
            }
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(live == nil ? Color.clear : Color.accentColor.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(live == nil ? 0.35 : 0), style: StrokeStyle(lineWidth: 1, dash: [2])))
            .foregroundStyle(live == nil ? Color.secondary : Color.primary)
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help(Self.card(p, live: live != nil))
        .accessibilityLabel("\(p.name), pid \(p.pid)")
        .accessibilityHint(live == nil ? "Exited" : "Shows this process. Command-click opens it in a new window.")
        .contextMenu {
            if let live {
                Button("Show") { links.map { $0.open(live) } ?? openWindow(id: ProcessWindow.id, value: ProcessRef(live)) }
                Button("Open in New Window") { openWindow(id: ProcessWindow.id, value: ProcessRef(live)) }
                Divider()
            }
            Button("Copy PID") { ProcessOutline.Coordinator.copy("\(p.pid)") }
            if let path = p.path {
                Button("Copy Path") { ProcessOutline.Coordinator.copy(path) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
        }
    }

    /// The hover card: a tooltip, so it never covers what the pointer is moving towards.
    static func card(_ p: ProcInfo, live: Bool) -> String {
        var lines = ["\(p.name) (pid \(p.pid))", p.path ?? p.comm, "user \(p.user)"]
        if live {
            var usage: [String] = []
            if let c = p.cpuPercent { usage.append("CPU \(Fmt.pct(c)) %") }
            if let f = p.footprint { usage.append("memory \(Fmt.bytes(f))") }
            if !usage.isEmpty { lines.append(usage.joined(separator: " · ")) }
            lines.append("Click to show · ⌘-click for a new window")
        } else {
            lines.append("Exited")
        }
        return lines.joined(separator: "\n")
    }
}

/// Back and forward through the inspector's history (⌘[ and ⌘]).
struct HistoryButtons: View {
    let links: InspectorLinks

    var body: some View {
        let nav = links.nav
        HStack(spacing: 0) {
            Button { links.back() } label: { Image(systemName: "chevron.left").frame(width: 20, height: 20).contentShape(Rectangle()) }
                .disabled(!nav.canGoBack)
                .keyboardShortcut("[", modifiers: .command)
                .help(nav.backTitle.map { "Back to \($0) (⌘[)" } ?? "Back (⌘[)")
                .accessibilityLabel("Back")
            Button { links.forward() } label: { Image(systemName: "chevron.right").frame(width: 20, height: 20).contentShape(Rectangle()) }
                .disabled(!nav.canGoForward)
                .keyboardShortcut("]", modifiers: .command)
                .help(nav.forwardTitle.map { "Forward to \($0) (⌘])" } ?? "Forward (⌘])")
                .accessibilityLabel("Forward")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}
