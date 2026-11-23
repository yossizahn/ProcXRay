import AppKit
import SwiftUI

/// The strip over every view of a trace (TraceOverview): one line saying what the process did, the kinds of call
/// as buttons that narrow the views to theirs, and a graph of the calls over time to drag a stretch out of.
struct TraceOverviewBar: NSViewRepresentable {
    let overview: TraceOverview
    @Binding var kinds: Set<TraceKind>
    @Binding var range: ClosedRange<UInt64>?

    static let height: CGFloat = 76

    func makeNSView(context: Context) -> TraceOverviewView {
        let v = TraceOverviewView()
        update(v)
        return v
    }

    func updateNSView(_ v: TraceOverviewView, context: Context) { update(v) }

    private func update(_ v: TraceOverviewView) {
        v.onKinds = { if kinds != $0 { kinds = $0 } }
        v.onRange = { if range != $0 { range = $0 } }
        v.set(overview, kinds: kinds, range: range)
    }
}

extension TraceKind {
    /// The kind's colour in the overview's graph and on its button; the waits aren't drawn.
    var color: NSColor? {
        switch self {
        case .files: .systemBlue
        case .network: .systemGreen
        case .messages: .systemPurple
        case .other: .systemGray
        case .waits: nil
        }
    }

    var help: String {
        let what = switch self {
        case .files: "file calls: lookups, opens, reads, writes, directory listings"
        case .network: "socket calls: connections and what was sent and received"
        case .messages: "Mach messages to other processes and to the kernel"
        case .other: "everything else: memory, threads, launches, library loading"
        case .waits: "waits, sleeps and event polls (not drawn in the graph)"
        }
        return "Show only " + what + ". Click again for every kind; several can be on."
    }
}

final class TraceOverviewView: NSView {
    var onKinds: (Set<TraceKind>) -> Void = { _ in }
    var onRange: (ClosedRange<UInt64>?) -> Void = { _ in }

    private var overview = TraceOverview()
    private var kinds: Set<TraceKind> = []
    private let sentence = NSTextField(labelWithString: "")
    private let whole = NSButton(title: "Whole Trace", target: nil, action: nil)
    private var chips: [NSButton] = []
    private let timeline = TraceTimelineView()

    init() {
        super.init(frame: .zero)
        sentence.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        sentence.textColor = .secondaryLabelColor
        sentence.lineBreakMode = .byTruncatingTail
        sentence.allowsExpansionToolTips = true
        sentence.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sentence.setContentHuggingPriority(.defaultLow, for: .horizontal)

        whole.target = self
        whole.action = #selector(showWhole)
        whole.bezelStyle = .recessed
        whole.controlSize = .small
        whole.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        whole.imagePosition = .imageLeading
        whole.toolTip = "The views show only the stretch selected in the graph. Show the whole trace again (or click the graph)."
        whole.isHidden = true

        for kind in TraceKind.allCases {
            let b = NSButton(title: kind.title, target: self, action: #selector(chip(_:)))
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .recessed
            b.controlSize = .small
            b.tag = kind.rawValue
            b.toolTip = kind.help
            chips.append(b)
        }
        let row = NSStackView(views: [sentence, whole] + chips)
        row.orientation = .horizontal
        row.spacing = 4
        row.setCustomSpacing(8, after: sentence)
        for v in [whole] + chips {
            v.setContentCompressionResistancePriority(.required, for: .horizontal)
            v.setContentHuggingPriority(.required, for: .horizontal)
        }
        timeline.onRange = { [weak self] in self?.onRange($0) }

        for v in [row, timeline] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.heightAnchor.constraint(equalToConstant: 20),
            timeline.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 4),
            timeline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            timeline.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            timeline.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: TraceOverviewBar.height) }

    func set(_ o: TraceOverview, kinds k: Set<TraceKind>, range: ClosedRange<UInt64>?) {
        if sentence.stringValue != o.sentence { sentence.stringValue = o.sentence }
        if whole.isHidden != (range == nil) { whole.isHidden = range == nil }
        if o.counts != overview.counts || k != kinds || chips[0].attributedTitle.length == 0 {
            for (b, kind) in zip(chips, TraceKind.allCases) {
                let title = NSMutableAttributedString()
                let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
                if let c = kind.color { title.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: c, .font: font])) }
                title.append(NSAttributedString(string: kind.title + " ", attributes: [.foregroundColor: NSColor.labelColor, .font: font]))
                title.append(NSAttributedString(string: o.counts[kind.rawValue].formatted(), attributes: [
                    .foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)]))
                b.attributedTitle = title
                b.state = k.contains(kind) ? .on : .off
                b.setAccessibilityLabel("\(kind.title), \(o.counts[kind.rawValue]) calls")
            }
        }
        kinds = k
        overview = o
        timeline.set(o, range: range)
    }

    @objc private func chip(_ sender: NSButton) {
        guard let kind = TraceKind(rawValue: sender.tag) else { return }
        onKinds(kinds.symmetricDifference([kind]))
    }

    @objc private func showWhole() { onRange(nil) }
}

/// The overview's graph: the calls over the trace as stacked areas by kind (SeriesGraphView), a line under them
/// where the process was on a CPU, the time scale, and the stretch dragged out of it.
final class TraceTimelineView: NSView {
    var onRange: (ClosedRange<UInt64>?) -> Void = { _ in }

    private var overview = TraceOverview()
    private var range: ClosedRange<UInt64>?
    /// The stretch being dragged, as x positions, until the mouse lets go.
    private var drag: (from: CGFloat, to: CGFloat)?
    private let graph = SeriesGraphView()
    private let selection = SelectionView()

    private static let track: CGFloat = 4, scale: CGFloat = 12

    init() {
        super.init(frame: .zero)
        addSubview(graph)
        addSubview(selection)
        toolTip = "Calls over the trace by kind (the waits left out); the height grows with the square root of the count, so a few calls still show beside a burst. The line underneath: when the process's threads were on a CPU (from the kernel's context switches; darker the more, full at one core's worth). Drag across a stretch to see only its calls in every view; click to see the whole trace again."
        setAccessibilityLabel("Calls over the trace")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        graph.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - Self.track - Self.scale - 1))
        selection.frame = bounds
        showSelection()
    }

    func set(_ o: TraceOverview, range r: ClosedRange<UInt64>?) {
        let changed = o != overview
        if changed {
            overview = o
            graph.content = Self.content(o)
            needsDisplay = true
        }
        if changed || r != range {
            range = r
            showSelection()
        }
    }

    /// The kinds stacked: each series is the count of its kind and of those under it, the topmost drawn first.
    private static func content(_ o: TraceOverview) -> SeriesGraphView.Content {
        var c = SeriesGraphView.Content(capacity: TraceOverview.bins)
        guard !o.bars.isEmpty else { return c }
        var levels = [[Double]](repeating: [Double](repeating: 0, count: TraceOverview.bins), count: o.bars.count)
        for j in 0..<TraceOverview.bins {
            var sum = 0
            for k in o.bars.indices { sum += o.bars[k][j]; levels[k][j] = Double(sum) }
            guard sum > 0 else { continue }
            let squash = Double(sum).squareRoot() / Double(sum)
            for k in o.bars.indices { levels[k][j] *= squash }
        }
        for k in o.bars.indices.reversed() {
            c.series.append(.init(values: levels[k], color: TraceOverview.drawn[k].color ?? .systemGray, fill: 0.85, line: 0))
        }
        return c
    }

    private func x(_ t: UInt64) -> CGFloat {
        guard !overview.isEmpty else { return 0 }
        return CGFloat(Double(min(max(t, overview.lo), overview.hi) - overview.lo) / Double(overview.hi - overview.lo)) * bounds.width
    }

    private func time(_ x: CGFloat) -> UInt64 {
        guard bounds.width > 0 else { return overview.lo }
        return overview.lo + UInt64(Double(min(max(x, 0), bounds.width) / bounds.width) * Double(overview.hi - overview.lo))
    }

    private func showSelection() {
        if let d = drag {
            selection.span = min(d.from, d.to)...max(d.from, d.to)
        } else if let r = range, !overview.isEmpty {
            selection.span = x(r.lowerBound)...max(x(r.upperBound), x(r.lowerBound) + 1)
        } else {
            selection.span = nil
        }
    }

    override func draw(_ dirty: NSRect) {
        guard !overview.isEmpty, bounds.width > 0 else { return }
        let top = graph.frame.maxY + 1
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: top + Self.track - 1, width: bounds.width, height: 1).fill()
        // On a CPU: darker the more of the column, full at one core's worth.
        let w = bounds.width / CGFloat(TraceOverview.bins)
        for (k, share) in overview.cpu.enumerated() where share > 0.005 {
            NSColor.labelColor.withAlphaComponent(0.2 + 0.7 * min(1, share)).setFill()
            NSRect(x: CGFloat(k) * w, y: top, width: w, height: Self.track - 1).fill()
        }
        // About one label every 80 points, on round times.
        let span = Double(overview.hi - overview.lo) / 1e9
        let steps: [Double] = [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 30, 60, 120, 300, 600]
        let step = steps.first { span / $0 <= Double(bounds.width / 80) } ?? 600
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor]
        var t = (Double(overview.lo) / 1e9 / step).rounded(.up) * step
        while t <= Double(overview.hi) / 1e9 {
            let px = x(UInt64(t * 1e9))
            NSColor.tertiaryLabelColor.setFill()
            NSRect(x: px, y: top + Self.track, width: 1, height: 3).fill()
            let text = step < 0.1 ? String(format: "%g ms", (t * 1000).rounded()) : String(format: "%g s", (t * 1000).rounded() / 1000)
            let size = text.size(withAttributes: attributes)
            if px + 3 + size.width <= bounds.width { text.draw(at: NSPoint(x: px + 3, y: top + Self.track), withAttributes: attributes) }
            t += step
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with e: NSEvent) {
        guard !overview.isEmpty else { return }
        let p = convert(e.locationInWindow, from: nil).x
        drag = (p, p)
    }

    override func mouseDragged(with e: NSEvent) {
        guard let d = drag else { return }
        drag = (d.from, min(max(convert(e.locationInWindow, from: nil).x, 0), bounds.width))
        showSelection()
    }

    override func mouseUp(with e: NSEvent) {
        guard let d = drag else { return }
        drag = nil
        // A click, not a drag: the whole trace again.
        if abs(d.to - d.from) < 3 { onRange(nil) } else { onRange(time(min(d.from, d.to))...time(max(d.from, d.to))) }
        showSelection()
    }

    /// The selected stretch, drawn over the graph.
    private final class SelectionView: NSView {
        var span: ClosedRange<CGFloat>? { didSet { if span != oldValue { needsDisplay = true } } }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirty: NSRect) {
            guard let span else { return }
            // What is left out fades; the stretch keeps its colours between two edges.
            NSColor.windowBackgroundColor.withAlphaComponent(0.6).setFill()
            NSRect(x: 0, y: 0, width: span.lowerBound, height: bounds.height).fill(using: .sourceOver)
            NSRect(x: span.upperBound, y: 0, width: bounds.width - span.upperBound, height: bounds.height).fill(using: .sourceOver)
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            NSRect(x: span.lowerBound, y: 0, width: span.upperBound - span.lowerBound, height: bounds.height).fill(using: .sourceOver)
            NSColor.controlAccentColor.setFill()
            NSRect(x: span.lowerBound, y: 0, width: 1, height: bounds.height).fill()
            NSRect(x: span.upperBound - 1, y: 0, width: 1, height: bounds.height).fill()
        }
    }
}
