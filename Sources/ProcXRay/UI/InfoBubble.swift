import AppKit
import SwiftUI

/// A transient bubble of labelled sections: the process list's row info, and every field name's "what and from where".
@MainActor
final class InfoBubble: NSObject, NSPopoverDelegate {
    struct Section {
        let title: String; let value: String; var mono = false
        /// A path to offer reveal-in-Finder for, next to the title.
        var reveal: String? = nil
    }

    private lazy var popover: NSPopover = {
        let p = NSPopover()
        p.behavior = .transient
        p.delegate = self
        return p
    }()
    private weak var item: AnyObject?
    /// The transient popover closes on the button's mouse-down, before the button's action runs: that
    /// action must not reopen it.
    private weak var justClosed: AnyObject?
    private var closedAt = Date.distantPast

    func toggle(_ item: AnyObject, sections: [Section], from button: NSView) {
        if popover.isShown, self.item === item { close(); return }
        if justClosed === item, Date().timeIntervalSince(closedAt) < 0.5 { justClosed = nil; return }
        self.item = item
        popover.contentViewController = Self.controller(sections)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    /// Opens it over `rect` of `view` (a column's header, say), or closes it if it shows `item` already.
    func toggle(_ item: AnyObject, sections: [Section], relativeTo rect: NSRect, of view: NSView) {
        if popover.isShown, self.item === item { close(); return }
        if justClosed === item, Date().timeIntervalSince(closedAt) < 0.5 { justClosed = nil; return }
        self.item = item
        popover.contentViewController = Self.controller(sections)
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    func close() { if popover.isShown { popover.close() } }

    func popoverDidClose(_ n: Notification) {
        justClosed = item; closedAt = Date()
        item = nil
    }

    nonisolated(unsafe) private static var actionKey = 0

    /// Every bubble is the same width: values wrap at `valueWidth` (inside 12pt insets, 480pt in all), and
    /// scroll past `maxValueHeight` (a renderer's argv runs to 10 KB).
    private static let inset: CGFloat = 12, valueWidth: CGFloat = 456, maxValueHeight: CGFloat = 320

    private static func controller(_ sections: [Section]) -> NSViewController {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: inset, bottom: 10, right: inset)
        for s in sections {
            let title = NSTextField(labelWithString: s.title.uppercased())
            title.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .semibold)
            title.textColor = .secondaryLabelColor
            var heading: NSView = title
            if let path = s.reveal, Reveal.exists(path) {
                let b = Reveal.button(target: nil, action: nil)
                let action = ProcessOutline.MenuAction { Reveal.reveal([path]) }
                b.target = action
                b.action = #selector(ProcessOutline.MenuAction.fire)
                objc_setAssociatedObject(b, &Self.actionKey, action, .OBJC_ASSOCIATION_RETAIN)   // keeps the target alive
                b.widthAnchor.constraint(equalToConstant: 14).isActive = true
                b.heightAnchor.constraint(equalToConstant: 14).isActive = true
                var views: [NSView] = [title, b]
                if let t = MachOProbe.target(path) {
                    let ib = MachOOpen.button(target: nil, action: nil)
                    let ia = ProcessOutline.MenuAction { MachOOpen.open(t) }
                    ib.target = ia
                    ib.action = #selector(ProcessOutline.MenuAction.fire)
                    objc_setAssociatedObject(ib, &Self.actionKey, ia, .OBJC_ASSOCIATION_RETAIN)
                    ib.widthAnchor.constraint(equalToConstant: 14).isActive = true
                    ib.heightAnchor.constraint(equalToConstant: 14).isActive = true
                    views.append(ib)
                }
                let row = NSStackView(views: views)
                row.orientation = .horizontal
                row.spacing = 4
                row.alignment = .centerY
                heading = row
            }
            let group = NSStackView(views: [heading, value(s)])
            group.orientation = .vertical
            group.alignment = .leading
            group.spacing = 2
            stack.addArrangedSubview(group)
        }
        let vc = NSViewController()
        vc.view = stack
        vc.preferredContentSize = NSSize(width: valueWidth + 2 * inset, height: stack.fittingSize.height)
        return vc
    }

    /// The value as selectable text wrapped at valueWidth, in a scroll view when it's taller than maxValueHeight.
    private static func value(_ s: Section) -> NSView {
        let field = NSTextField(wrappingLabelWithString: s.value)
        field.font = s.mono ? .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            : .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.isSelectable = true
        // Pinned to valueWidth: a wrapping field has no intrinsic width of its own, and the scroll view needs
        // the text's real height.
        let height = ceil(field.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: valueWidth, height: .greatestFiniteMagnitude)).height)
        guard height > maxValueHeight else {
            field.preferredMaxLayoutWidth = valueWidth
            field.widthAnchor.constraint(equalToConstant: valueWidth).isActive = true
            return field
        }
        // Overlay scrollers draw over the text's last few points rather than taking a column of their own.
        field.frame = NSRect(x: 0, y: 0, width: valueWidth, height: height)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = field
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: valueWidth),
            scroll.heightAnchor.constraint(equalToConstant: maxValueHeight),
        ])
        return scroll
    }
}

// MARK: - Field names

/// What a field is and where it comes from: the lines of its info bubble.
struct FieldInfo {
    var help: String? = nil
    var source: String
    var via: FactRow.Via = .direct
    var needs: String? = nil

    var sections: [InfoBubble.Section] {
        var s: [InfoBubble.Section] = []
        if let help, !help.isEmpty { s.append(.init(title: "What it is", value: help)) }
        s.append(.init(title: "Source", value: source, mono: true))
        s.append(.init(title: "Read", value: via == .helper ? "as root by the helper" : "directly"))
        if let needs { s.append(.init(title: "Needs", value: needs)) }
        return s
    }

    /// A column's lines, for a row that shows the same value.
    init(column id: String, via: FactRow.Via = .direct) {
        let c = Column.byID[id]!
        self.init(help: c.help, source: c.source, via: via, needs: c.needs)
    }
    init(help: String? = nil, source: String, via: FactRow.Via = .direct, needs: String? = nil) {
        self.help = help; self.source = source; self.via = via; self.needs = needs
    }
}

/// A row's label that is also the handle to its info bubble: hovering shows an ⓘ beside it, and clicking the
/// name or the ⓘ opens the bubble (what it is, source, how it was read, what it needs).
struct FieldName: View {
    let label: String
    let info: FieldInfo?
    @State private var hover = false
    @State private var anchor = BubbleAnchor()

    var body: some View {
        if let info, !info.source.isEmpty {
            Button { anchor.toggle(info.sections) } label: {
                HStack(spacing: 3) {
                    Text(label).foregroundStyle(.secondary)
                    Image(systemName: "info.circle").font(.caption).foregroundStyle(.tertiary).opacity(hover ? 1 : 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(BubbleAnchorView(anchor: anchor))
            .onHover { hover = $0 }
            .accessibilityHint("Shows what this is and where it comes from")
        } else {
            Text(label).foregroundStyle(.secondary)
        }
    }
}

/// The NSView a SwiftUI field name's bubble points at.
@MainActor
final class BubbleAnchor {
    weak var view: NSView?
    private let bubble = InfoBubble()
    func toggle(_ sections: [InfoBubble.Section]) {
        guard let view else { return }
        bubble.toggle(self, sections: sections, from: view)
    }
}

private struct BubbleAnchorView: NSViewRepresentable {
    let anchor: BubbleAnchor
    func makeNSView(context: Context) -> NSView { let v = NSView(); anchor.view = v; return v }
    func updateNSView(_ v: NSView, context: Context) { anchor.view = v }
}
