import AppKit
import SwiftUI

/// The app's small graph of recent readings, newest on the right: an area or a line per series, or two series
/// mirrored around a middle line. One AppKit view for every such graph (the menu bar widgets, the popover's
/// rows and tiles, the overview): each series is a pair of shape layers, so a new reading replaces two paths
/// and the window server draws them. Nothing is rasterized by the app, and a graph that didn't change costs
/// nothing.
final class SeriesGraphView: NSView {
    struct Series: Equatable {
        var values: [Double]
        var color: NSColor
        /// Area under the line, at this opacity; 0 draws the line only.
        var fill: CGFloat = 0.55
        /// Line width; 0 draws the area only.
        var line: CGFloat = 1
    }

    struct Content: Equatable {
        var series: [Series] = []
        /// The value at the top; nil scales to the largest reading shown.
        var maxValue: Double?
        /// Readings across the full width: fewer leave the left empty, so the time scale doesn't stretch.
        var capacity = 60
        /// Two series around a middle line: the first upward, the second downward, on one scale.
        var mirrored = false
    }

    var content = Content() {
        didSet { if content != oldValue { needsLayout = true } }
    }

    private var shapes: [(fill: CAShapeLayer, line: CAShapeLayer)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var allowsVibrancy: Bool { false }

    override func layout() {
        super.layout()
        rebuild()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    private func rebuild() {
        guard let root = layer else { return }
        while shapes.count < content.series.count {
            let f = CAShapeLayer(), l = CAShapeLayer()
            // A graph that eases to each new reading would animate on every tick.
            f.actions = ["path": NSNull(), "fillColor": NSNull()]
            l.actions = ["path": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull()]
            f.strokeColor = nil
            l.fillColor = nil
            l.lineJoin = .round
            root.addSublayer(f)
            root.addSublayer(l)
            shapes.append((f, l))
        }
        while shapes.count > content.series.count {
            let s = shapes.removeLast()
            s.fill.removeFromSuperlayer()
            s.line.removeFromSuperlayer()
        }
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let peak = content.series.map { $0.values.max() ?? 0 }.max() ?? 0
        let top = max(content.maxValue ?? (content.mirrored ? max(peak, 1) : peak), 1e-9)
        let step = size.width / CGFloat(max(content.capacity - 1, 1))
        let base: CGFloat = content.mirrored ? size.height / 2 : 0
        let span: CGFloat = content.mirrored ? size.height / 2 : size.height
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for (i, s) in content.series.enumerated() {
                let shape = shapes[i]
                shape.fill.frame = bounds
                shape.line.frame = bounds
                guard s.values.count > 1 else { shape.fill.path = nil; shape.line.path = nil; continue }
                let sign: CGFloat = content.mirrored && i == 1 ? -1 : 1
                let start = size.width - CGFloat(s.values.count - 1) * step
                let line = CGMutablePath()
                for (j, v) in s.values.enumerated() {
                    let p = CGPoint(x: start + CGFloat(j) * step, y: base + sign * CGFloat(min(max(v, 0) / top, 1)) * span)
                    if j == 0 { line.move(to: p) } else { line.addLine(to: p) }
                }
                if s.fill > 0 {
                    let area = line.mutableCopy()!
                    area.addLine(to: CGPoint(x: size.width, y: base))
                    area.addLine(to: CGPoint(x: start, y: base))
                    area.closeSubpath()
                    shape.fill.path = area
                    shape.fill.fillColor = s.color.withAlphaComponent(s.fill).cgColor
                } else {
                    shape.fill.path = nil
                }
                if s.line > 0 {
                    shape.line.path = line
                    shape.line.strokeColor = s.color.cgColor
                    shape.line.lineWidth = s.line
                } else {
                    shape.line.path = nil
                }
            }
        }
    }
}

/// SeriesGraphView in a SwiftUI view.
struct SeriesGraph: NSViewRepresentable {
    var content: SeriesGraphView.Content

    func makeNSView(context: Context) -> SeriesGraphView {
        let v = SeriesGraphView()
        v.content = content
        return v
    }
    func updateNSView(_ v: SeriesGraphView, context: Context) { v.content = content }
}

/// A small area or line graph of the last readings, newest on the right; `maxValue` nil scales to the peak.
struct MiniGraph: View {
    let values: [Double]
    var maxValue: Double?
    var color: Color = .accentColor
    var filled = true
    var capacity = AmbientMonitor.historyLength

    var body: some View {
        SeriesGraph(content: .init(series: [.init(values: values, color: NSColor(color), fill: filled ? 0.55 : 0)],
                                   maxValue: maxValue, capacity: capacity))
    }
}

/// Two series around a middle line, newest on the right: `up` drawn upward, `down` downward, both scaled to the
/// larger series' peak so their heights compare.
struct MirrorGraph: View {
    let up: [Double]
    let down: [Double]
    var upColor: Color = .accentColor
    var downColor: Color = .orange
    var capacity = AmbientMonitor.historyLength

    var body: some View {
        SeriesGraph(content: .init(series: [.init(values: up, color: NSColor(upColor), fill: 0.85, line: 0),
                                            .init(values: down, color: NSColor(downColor), fill: 0.85, line: 0)],
                                   capacity: capacity, mirrored: true))
    }
}
