import AppKit
import SwiftUI

/// Which threads a trace's views show: none chosen shows them all.
enum ThreadFollow {
    /// The context menu's thread items for rows on `tids`, each with the threads to show after it.
    static func items(rows tids: Set<UInt64>, shown: Set<UInt64>, names: [UInt64: String]) -> [(title: String, threads: Set<UInt64>)] {
        var out: [(String, Set<UInt64>)] = []
        if tids.count == 1, let t = tids.first {
            let name = SyscallTraceView.thread(t, names)
            if shown.isEmpty {
                out.append(("Follow Thread " + name, [t]))
            } else if shown.count > 1, shown.contains(t) {
                out.append(("Show Only Thread " + name, [t]))
                out.append(("Hide Thread " + name, shown.subtracting([t])))
            }
        }
        if !shown.isEmpty { out.append(("Show All Threads", [])) }
        return out
    }

    /// The Thread button's title: which threads show, short (the header is full).
    static func title(_ shown: Set<UInt64>, names: [UInt64: String]) -> String {
        guard shown.count == 1, let t = shown.first else { return shown.isEmpty ? "All threads" : "\(shown.count) threads" }
        return names[t]?.hasPrefix("main thread") ?? false ? "Main thread" : "Thread " + String(t)
    }
}

/// The trace header's Thread button: a menu of the trace's threads to tick, which stays open while threads are
/// ticked (several show side by side), and All threads.
struct ThreadMenuButton: NSViewRepresentable {
    let title: String
    /// Each thread and its menu row's text.
    let choices: [(tid: UInt64, title: String)]
    let shown: Set<UInt64>
    let enabled: Bool
    let change: (Set<UInt64>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let b = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.open(_:)))
        b.isBordered = false
        b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        b.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        b.imagePosition = .imageTrailing
        b.setContentHuggingPriority(.required, for: .horizontal)
        update(b, context.coordinator)
        return b
    }

    func updateNSView(_ b: NSButton, context: Context) { update(b, context.coordinator) }

    private func update(_ b: NSButton, _ c: Coordinator) {
        c.parent = self
        if b.title != title { b.title = title }
        b.isEnabled = enabled
        b.toolTip = "Choose the threads to follow: every view shows only their calls. Tick several to see them side by side."
    }

    @MainActor final class Coordinator: NSObject {
        var parent: ThreadMenuButton?

        @objc func open(_ sender: NSButton) {
            guard let p = parent else { return }
            // Ticks build on each other while the menu is open; the views follow each one.
            final class Box { var shown: Set<UInt64>; init(_ s: Set<UInt64>) { shown = s } }
            let box = Box(p.shown)
            let menu = NSMenu()
            let all = NSMenuItem(title: "All threads", action: #selector(ProcessOutline.MenuAction.fire), keyEquivalent: "")
            let allAction = ProcessOutline.MenuAction { p.change([]) }
            all.target = allAction
            all.representedObject = allAction
            all.state = p.shown.isEmpty ? .on : .off
            menu.addItem(all)
            menu.addItem(.separator())
            for c in p.choices {
                let item = NSMenuItem()
                item.view = ProcessOutline.MenuToggleView(title: c.title, on: p.shown.contains(c.tid)) {
                    box.shown.formSymmetricDifference([c.tid])
                    all.state = box.shown.isEmpty ? .on : .off
                    p.change(box.shown)
                }
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }
    }
}
