import AppKit
import SwiftUI

/// Vertical split whose divider position is a stored fraction of the available height.
/// Unlike VSplitView, swapping the bottom view (empty state ↔ inspector) never moves the divider,
/// because the layout depends only on the fraction, not on the children's ideal sizes.
struct SplitPane<Top: View, Bottom: View>: View {
    @AppStorage private var fraction: Double
    @State private var dragStartTop: CGFloat?
    private let minPane: CGFloat = 120
    private let top: Top
    private let bottom: Bottom
    private let showsBottom: Bool

    /// With `showsBottom` false the top view fills the pane. It keeps its identity either way, so
    /// toggling the bottom pane doesn't rebuild (or lose the state of) the top view.
    init(id: String, defaultFraction: Double = 0.5, showsBottom: Bool = true,
         @ViewBuilder top: () -> Top, @ViewBuilder bottom: () -> Bottom) {
        _fraction = AppStorage(wrappedValue: defaultFraction, "splitPane.\(id)")
        self.showsBottom = showsBottom
        self.top = top()
        self.bottom = bottom()
    }

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.height
            let topHeight = showsBottom ? clamp(total * fraction, total) : total
            VStack(spacing: 0) {
                top.frame(width: geo.size.width, height: topHeight)
                if showsBottom {
                    divider(total: total, topHeight: topHeight)
                    bottom.frame(width: geo.size.width, height: max(0, total - topHeight - 1))
                }
            }
        }
    }

    private func clamp(_ h: CGFloat, _ total: CGFloat) -> CGFloat {
        guard total > minPane * 2 else { return total / 2 }
        return min(max(h, minPane), total - minPane)
    }

    private func divider(total: CGFloat, topHeight: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .overlay {
                // Larger invisible grab area centred on the 1pt line.
                Color.clear
                    .frame(height: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { v in
                                let start = dragStartTop ?? topHeight
                                if dragStartTop == nil { dragStartTop = start }
                                fraction = Double(clamp(start + v.translation.height, total) / total)
                            }
                            .onEnded { _ in dragStartTop = nil }
                    )
                    // Without a pointer: VoiceOver adjusts it like a native splitter, and with keyboard
                    // focus (Full Keyboard Access, or Tab when "Keyboard navigation" is on) ↑/↓ move it.
                    // Exposed as a slider (top pane's share of the height), which VoiceOver reads with
                    // its value and adjusts with VO-↑/↓; a bare adjustable element came out as AXUnknown.
                    .accessibilityRepresentation {
                        Slider(value: Binding(get: { Double(topHeight / max(total, 1) * 100).rounded() },
                                              set: { fraction = Double(clamp(total * $0 / 100, total) / max(total, 1)) }),
                               in: 0...100, step: 5) { Text("Split") }
                    }
                    // `.activate` = focusable only through keyboard navigation, so a click/drag doesn't
                    // take focus and draw a focus ring around the grab area.
                    .focusable(interactions: .activate)
                    .onKeyPress(.upArrow) { nudge(-1, total: total, topHeight: topHeight); return .handled }
                    .onKeyPress(.downArrow) { nudge(1, total: total, topHeight: topHeight); return .handled }
            }
            .zIndex(1)
    }

    /// One step of 5% of the height (positive moves the divider down).
    private func nudge(_ steps: Int, total: CGFloat, topHeight: CGFloat) {
        guard total > 0 else { return }
        fraction = Double(clamp(topHeight + CGFloat(steps) * total * 0.05, total) / total)
    }
}
