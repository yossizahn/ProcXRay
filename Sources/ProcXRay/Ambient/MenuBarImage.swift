import AppKit

/// The menu bar item's picture: the chosen widgets (a small graph and a figure each), after a warning sign while
/// an alert is live. Drawn with AppKit straight into an image.
///
/// It was a SwiftUI view rendered to an image on every reading (ImageRenderer), plus one more render per widget
/// to find where each one sits; with every window closed that was most of what the app did. Here a reading lays
/// the widgets out with a few string measurements and draws them when the image is drawn, and a reading that
/// would draw the same picture gets the same image back, so nothing downstream redraws.
@MainActor
enum MenuBarImage {
    static let height: CGFloat = 18
    /// Between widgets, and after the alert sign.
    static let spacing: CGFloat = 6
    private static let graphSize = NSSize(width: 22, height: 14)

    struct Result {
        var image: NSImage
        /// Each widget's x range in the image, for telling which one a click hit (MenuBarHit).
        var ranges: [(AmbientMetric, ClosedRange<CGFloat>)]
    }

    /// Everything the picture depends on.
    private struct Key: Equatable {
        var metrics: [AmbientMetric]
        var alert: Bool, graphs: Bool, colored: Bool
        var ink: NSColor
        var texts: [[String]]
        var series: [[[Double]]]
        var pressure: Int32
    }
    private static var last: (key: Key, result: Result)?

    /// `ink`: the text's color. `colored`: each graph in its metric's color on white (the image is then not a
    /// template, and `ink` must suit the menu bar); otherwise everything in `ink`, for a template image.
    static func render(metrics: [AmbientMetric], alert: Bool, graphs: Bool, system: SystemStats.Rates,
                       history: [AmbientMetric: [Double]], io: [IOSeries: [Double]], ink: NSColor, colored: Bool) -> Result {
        let texts = metrics.map { lines($0, system) }
        let series: [[[Double]]] = graphs ? metrics.map { m in
            switch m {
            case .disk: [io[.diskRead] ?? [], io[.diskWrite] ?? []]
            case .network: [io[.netIn] ?? [], io[.netOut] ?? []]
            default: [history[m] ?? []]
            }
        } : []
        let key = Key(metrics: metrics, alert: alert, graphs: graphs, colored: colored, ink: ink, texts: texts, series: series,
                      pressure: system.memory?.pressure ?? 1)
        if let last, last.key == key { return last.result }

        // Layout: where each piece goes, left to right.
        var ops: [(NSRect) -> Void] = []
        var x: CGFloat = 0
        if alert, let sign = alertSign(colored ? NSColor(red: 1, green: 0.62, blue: 0.04, alpha: 1) : ink) {
            let s = sign.size, at = NSPoint(x: x, y: (height - s.height) / 2)
            ops.append { _ in sign.draw(at: at, from: .zero, operation: .sourceOver, fraction: 1) }
            x += s.width + spacing
        }
        var ranges: [(AmbientMetric, ClosedRange<CGFloat>)] = []
        for (i, m) in metrics.enumerated() {
            let start = x
            if graphs {
                let rect = NSRect(x: x, y: (height - graphSize.height) / 2, width: graphSize.width, height: graphSize.height)
                let s = series[i], colors = graphColors(m, pressure: key.pressure, ink: ink, colored: colored)
                ops.append { _ in drawGraph(s, in: rect, colors: colors, ink: ink, colored: colored) }
                x += graphSize.width + 3
            }
            let io = m == .disk || m == .network
            let fonts: [NSFont] = io ? [ioFont, ioFont] : [labelFont, valueFont]
            let strings = zip(texts[i], fonts).map { NSAttributedString(string: $0, attributes: [.font: $1, .foregroundColor: ink]) }
            let sizes = strings.map { $0.size() }
            let width = max(io ? 34 : 26, ceil(sizes.map(\.width).max() ?? 0))
            // Two lines, overlapping by two points, centred in the height.
            let total = sizes[0].height + sizes[1].height - 2
            let bottom = (height - total) / 2
            let x0 = x
            ops.append { _ in
                // Disk and network figures are right-aligned, the others left-aligned.
                strings[1].draw(at: NSPoint(x: io ? x0 + width - sizes[1].width : x0, y: bottom))
                strings[0].draw(at: NSPoint(x: io ? x0 + width - sizes[0].width : x0, y: bottom + sizes[1].height - 2))
            }
            x += width
            ranges.append((m, start...x))
            if i < metrics.count - 1 { x += spacing }
        }
        let image = NSImage(size: NSSize(width: max(1, ceil(x)), height: height), flipped: false) { rect in
            for op in ops { op(rect) }
            return true
        }
        image.isTemplate = !colored
        let result = Result(image: image, ranges: ranges)
        last = (key, result)
        return result
    }

    private static let labelFont = NSFont.systemFont(ofSize: 7, weight: .bold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    private static let ioFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold)

    /// A widget's two lines, top first: "CPU" over "34%", or read over written, received over sent.
    private static func lines(_ m: AmbientMetric, _ s: SystemStats.Rates) -> [String] {
        switch m {
        case .cpu: [m.short, Compact.percent(s.cpuPercent)]
        case .gpu: [m.short, Compact.percent(s.gpuPercent)]
        case .memory: [m.short, Compact.percent(s.memory.map { $0.usedFraction * 100 })]
        case .disk: ["R " + (s.diskRead.map(Compact.bytes) ?? "–"), "W " + (s.diskWrite.map(Compact.bytes) ?? "–")]
        case .network: ["↓ " + (s.netIn.map(Compact.bytes) ?? "–"), "↑ " + (s.netOut.map(Compact.bytes) ?? "–")]
        }
    }

    private static func alertSign(_ color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold).applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Alert")?.withSymbolConfiguration(config)
    }

    /// Fixed colors, not dynamic system ones: the image is drawn outside any view's appearance. CPU green, GPU
    /// purple, memory by the kernel's pressure level; disk and network in two: incoming (read, received) blue,
    /// outgoing (written, sent) red, as Activity Monitor colors them.
    private static func graphColors(_ m: AmbientMetric, pressure: Int32, ink: NSColor, colored: Bool) -> [NSColor] {
        guard colored else { return [ink, ink] }
        let blue = NSColor(red: 0.04, green: 0.52, blue: 1, alpha: 1), red = NSColor(red: 1, green: 0.27, blue: 0.23, alpha: 1)
        switch m {
        case .cpu: return [NSColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1)]
        case .gpu: return [NSColor(red: 0.69, green: 0.32, blue: 0.87, alpha: 1)]
        case .memory: return [pressure >= 4 ? red : pressure >= 2 ? NSColor(red: 1, green: 0.62, blue: 0.04, alpha: 1) : blue]
        case .disk, .network: return [blue, red]
        }
    }

    /// One series as an area under a line, scaled to 100; two as areas up and down from the middle, scaled to the
    /// larger one's peak. Newest reading at the right edge.
    private static func drawGraph(_ series: [[Double]], in rect: NSRect, colors: [NSColor], ink: NSColor, colored: Bool) {
        let frame = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
        // White behind colored graphs (a template image can't have one: it would draw as a solid block).
        if colored { NSColor.white.setFill(); frame.fill() }
        NSGraphicsContext.saveGraphicsState()
        frame.addClip()
        let step = rect.width / CGFloat(max(AmbientMonitor.historyLength - 1, 1))
        if series.count == 2 {
            let peak = max(series[0].max() ?? 0, series[1].max() ?? 0, 1), mid = rect.midY
            for (values, sign) in zip(series, [CGFloat(1), -1]) where values.count > 1 {
                let start = rect.maxX - CGFloat(values.count - 1) * step
                let area = NSBezierPath()
                area.move(to: NSPoint(x: start, y: mid))
                for (i, v) in values.enumerated() {
                    area.line(to: NSPoint(x: start + CGFloat(i) * step, y: mid + sign * CGFloat(min(v / peak, 1)) * rect.height / 2))
                }
                area.line(to: NSPoint(x: rect.maxX, y: mid))
                area.close()
                colors[sign > 0 ? 0 : min(1, colors.count - 1)].withAlphaComponent(0.85).setFill()
                area.fill()
            }
        } else if let values = series.first, values.count > 1 {
            let start = rect.maxX - CGFloat(values.count - 1) * step
            let line = NSBezierPath()
            for (i, v) in values.enumerated() {
                let p = NSPoint(x: start + CGFloat(i) * step, y: rect.minY + CGFloat(min(max(v, 0) / 100, 1)) * rect.height)
                if i == 0 { line.move(to: p) } else { line.line(to: p) }
            }
            let area = line.copy() as! NSBezierPath
            area.line(to: NSPoint(x: rect.maxX, y: rect.minY))
            area.line(to: NSPoint(x: start, y: rect.minY))
            area.close()
            colors[0].withAlphaComponent(0.55).setFill()
            area.fill()
            colors[0].setStroke()
            line.lineWidth = 1
            line.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        ink.withAlphaComponent(0.5).setStroke()
        frame.lineWidth = 0.75
        frame.stroke()
    }
}
