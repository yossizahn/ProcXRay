import AppKit
import SwiftUI

/// A trace as one lane per thread on a shared time line: each call a bar from its entry to its return.
struct SyscallLanes: Sendable {
    struct Lane: Sendable {
        let tid: UInt64
        /// By start. `starts` and `ends` are the calls' spans in ns since the trace started: a call entered before
        /// the trace starts at 0, one still in the kernel at the stop ends where the trace does.
        var calls: [SyscallRecord] = []
        var starts: [UInt64] = []
        var ends: [UInt64] = []
        /// The latest end among calls 0...i, which only grows: the first call that reaches a time is found by bisection
        /// even with calls nested in others (dyld's dlopen around the syscalls it makes).
        var reach: [UInt64] = []

        /// The first call that ends at `t` or later.
        func firstReaching(_ t: UInt64) -> Int {
            var lo = 0, hi = reach.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if reach[mid] < t { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }

        /// The call at time `t`, give or take `tolerance` ns: one that spans it (the innermost), else the nearest.
        func call(at t: UInt64, tolerance: UInt64) -> Int? {
            var best: (i: Int, distance: UInt64, length: UInt64)?
            var i = firstReaching(t > tolerance ? t - tolerance : 0)
            while i < starts.count, starts[i] <= t + tolerance {
                let s = starts[i], e = ends[i]
                let d = s > t ? s - t : e < t ? t - e : 0
                if d <= tolerance, best == nil || d < best!.distance || (d == best!.distance && e - s < best!.length) {
                    best = (i, d, e - s)
                }
                i += 1
            }
            return best?.i
        }
    }

    var lanes: [Lane] = []
    /// The trace's span: from 0 to the last time any call shows.
    var end: UInt64 = 0
    /// New for each build, so the view redraws only when the lanes changed.
    var id = UUID()

    var callCount: Int { lanes.reduce(0) { $0 + $1.calls.count } }

    static func build(_ records: [SyscallRecord], threadNames: [UInt64: String] = [:]) -> SyscallLanes {
        var out = SyscallLanes()
        for r in records { out.end = max(out.end, r.end ?? r.start ?? 0) }
        let byThread = Dictionary(grouping: records, by: \.thread)
        // The main thread first, then by thread id (about the order threads were made).
        let tids = byThread.keys.sorted { a, b in
            let ma = threadNames[a]?.hasPrefix("main thread") ?? false, mb = threadNames[b]?.hasPrefix("main thread") ?? false
            return ma != mb ? ma : a < b
        }
        for tid in tids {
            var lane = Lane(tid: tid)
            lane.calls = byThread[tid]!.sorted { ($0.start ?? 0, $0.id) < ($1.start ?? 0, $1.id) }
            lane.starts.reserveCapacity(lane.calls.count)
            lane.ends.reserveCapacity(lane.calls.count)
            lane.reach.reserveCapacity(lane.calls.count)
            var reach: UInt64 = 0
            for r in lane.calls {
                let s = r.start ?? 0
                let e = max(r.end ?? out.end, s)
                lane.starts.append(s)
                lane.ends.append(e)
                reach = max(reach, e)
                lane.reach.append(reach)
            }
            out.lanes.append(lane)
        }
        return out
    }

    /// Each thread's calls under its own heading, in time order.
    func text(context: SyscallActivity.Context) -> String {
        lanes.map { lane in
            let head = SyscallActivityView.threadLabel(lane.tid, lane.calls.count, name: context.threadNames[lane.tid])
            return ([head] + lane.calls.map { "    " + SyscallTraceView.line($0, context: context) }).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

/// The Lanes view: zoom buttons and a legend over the lanes.
struct SyscallLanesPane: View {
    let lanes: SyscallLanes
    let context: SyscallActivity.Context
    var threadColors: [UInt64: NSColor] = [:]
    let followed: Set<UInt64>
    let follow: (Set<UInt64>) -> Void
    @Binding var selected: SyscallRecord?
    @State private var commands = LaneCommands()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 2) {
                    Button { commands.zoom(0.5) } label: { Image(systemName: "minus.magnifyingglass") }
                        .help("Zoom out (−)")
                    Button { commands.zoom(2) } label: { Image(systemName: "plus.magnifyingglass") }
                        .help("Zoom in (+)")
                    Button("Fit") { commands.fit() }
                        .help("Show the whole trace (0). While tracing, it keeps growing with the trace.")
                }
                .buttonStyle(.borderless)
                Spacer(minLength: 8)
                ForEach(LanesCanvas.legend, id: \.0) { name, color in
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: color)).frame(width: 10, height: 8)
                        Text(name)
                    }
                }
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: .systemBlue).opacity(LanesCanvas.blockedAlpha))
                        .frame(width: 10, height: 8)
                    Text("Faint: the thread waited")
                }
                .help("The thread gave up its CPU during the call (blocked): waiting for a message, an event or I/O. Calls already under way when the trace started are faint too, drawn from its start.")
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            Divider()
            LanesRepresentable(lanes: lanes, context: context, threadColors: threadColors, followed: followed, follow: follow, commands: commands,
                               selected: $selected)
        }
    }
}

/// How the pane's buttons reach the canvas.
@MainActor final class LaneCommands {
    weak var canvas: LanesCanvas?
    func zoom(_ factor: Double) { canvas?.zoom(factor) }
    func fit() { canvas?.fit() }
}

private struct LanesRepresentable: NSViewRepresentable {
    let lanes: SyscallLanes
    let context: SyscallActivity.Context
    let threadColors: [UInt64: NSColor]
    let followed: Set<UInt64>
    let follow: (Set<UInt64>) -> Void
    let commands: LaneCommands
    @Binding var selected: SyscallRecord?

    func makeNSView(context ctx: Context) -> LanesContainer {
        let v = LanesContainer()
        update(v)
        return v
    }

    func updateNSView(_ v: LanesContainer, context ctx: Context) { update(v) }

    private func update(_ v: LanesContainer) {
        let c = v.canvas
        commands.canvas = c
        c.followed = followed
        if c.threadColors != threadColors { c.threadColors = threadColors }
        c.onFollow = follow
        c.onSelect = { r in if r?.id != selected?.id { selected = r } }
        if c.context.threadNames != context.threadNames || c.lanes.id != lanes.id { c.context = context }
        if c.lanes.id != lanes.id { c.set(lanes, selected: selected?.id) }
    }
}

/// The canvas over a line naming the call under the pointer (or the selected one).
final class LanesContainer: NSView {
    let canvas = LanesCanvas()
    private let info = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        info.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        info.textColor = .secondaryLabelColor
        info.lineBreakMode = .byTruncatingTail
        info.isSelectable = true
        info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let sep = NSBox()
        sep.boxType = .separator
        for v in [canvas, sep, info] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvas.topAnchor.constraint(equalTo: topAnchor),
            sep.leadingAnchor.constraint(equalTo: leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            sep.topAnchor.constraint(equalTo: canvas.bottomAnchor),
            info.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            info.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            info.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 4),
            info.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        canvas.onInfo = { [weak self] r in self?.show(r) }
        show(nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func show(_ r: SyscallRecord?) {
        if let r {
            info.stringValue = SyscallTraceView.line(r, context: canvas.context)
            info.textColor = r.failed ? .systemRed : .labelColor
        } else {
            info.stringValue = "Point at a call to read it, click to select it (its stack shows below), double-click to zoom to it · pinch or ⌥-scroll to zoom · drag or scroll sideways to move"
            info.textColor = .secondaryLabelColor
        }
    }
}

/// Draws the lanes: the time axis on top, thread names on the left, calls as bars. Only what shows is drawn, and
/// calls narrower than a pixel merge, so a trace of 200,000 calls draws in a few milliseconds.
final class LanesCanvas: NSView, NSUserInterfaceValidations {
    private(set) var lanes = SyscallLanes()
    var context = SyscallActivity.Context() { didSet { needsDisplay = true } }
    /// Each thread's colour (ThreadColors), as Activity's graph shows it: a mark before the thread's name.
    var threadColors: [UInt64: NSColor] = [:] { didSet { needsDisplay = true } }
    var followed: Set<UInt64> = []
    var onFollow: ((Set<UInt64>) -> Void)?
    var onSelect: ((SyscallRecord?) -> Void)?
    /// The call to name under the lanes: the one under the pointer, else the selected one.
    var onInfo: ((SyscallRecord?) -> Void)?

    private var selected: (lane: Int, index: Int)?
    private var selectedID: Int?
    private var hovered: (lane: Int, index: Int)?
    private var mouse: NSPoint?
    /// The time shown: `v0` to `v0 + span`, ns.
    private var v0: Double = 0
    private var span: Double = 1_000_000
    /// Showing the whole trace, and so growing with it.
    private var fitted = true
    private var scrollY: CGFloat = 0
    private var drag: (from: NSPoint, v0: Double, y: CGFloat)?
    private var dragged = false

    static let axisH: CGFloat = 22, laneH: CGFloat = 20, gutter: CGFloat = 190, barInset: CGFloat = 4
    static let minSpan: Double = 200
    static let blockedAlpha: CGFloat = 0.3
    static let legend: [(String, NSColor)] = [("Syscall", .systemBlue), ("Mach trap", .systemPurple), ("dyld", .systemTeal),
                                              ("Failed", .systemRed), ("Still running", .systemOrange.withAlphaComponent(0.55))]

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func set(_ l: SyscallLanes, selected id: Int?) {
        lanes = l
        hovered = nil
        selectedID = id
        selected = id.flatMap(locate)
        if fitted { fitTime() } else { clampTime() }
        clampScroll()
        onInfo?(selectedRecord)
        needsDisplay = true
    }

    private func locate(_ id: Int) -> (lane: Int, index: Int)? {
        for (li, lane) in lanes.lanes.enumerated() {
            if let i = lane.calls.firstIndex(where: { $0.id == id }) { return (li, i) }
        }
        return nil
    }

    private func record(_ at: (lane: Int, index: Int)?) -> SyscallRecord? {
        guard let at, at.lane < lanes.lanes.count, at.index < lanes.lanes[at.lane].calls.count else { return nil }
        return lanes.lanes[at.lane].calls[at.index]
    }
    private var selectedRecord: SyscallRecord? { record(selected) }

    // MARK: Time and scrolling

    private var plotWidth: CGFloat { max(bounds.width - Self.gutter, 1) }
    private var nsPerPx: Double { span / Double(plotWidth) }
    private var fullSpan: Double { max(Double(lanes.end) * 1.02, 10_000) }

    private func fitTime() { v0 = 0; span = fullSpan; fitted = true }

    func fit() { fitTime(); needsDisplay = true }

    /// `factor` > 1 zooms in, around `x` (the view's middle when nil).
    func zoom(_ factor: Double, at x: CGFloat? = nil) {
        let px = Double((x ?? Self.gutter + plotWidth / 2) - Self.gutter)
        let t = v0 + px * nsPerPx
        span = min(max(span / factor, Self.minSpan), fullSpan)
        v0 = t - px * span / Double(plotWidth)
        fitted = false
        clampTime()
        needsDisplay = true
    }

    private func zoom(to r: (lane: Int, index: Int)) {
        let lane = lanes.lanes[r.lane]
        let s = Double(lane.starts[r.index]), e = Double(lane.ends[r.index])
        span = min(max((e - s) * 3, 2_000), fullSpan)
        v0 = (s + e) / 2 - span / 2
        fitted = false
        clampTime()
        needsDisplay = true
    }

    private func clampTime() {
        if span >= fullSpan { fitTime(); return }
        v0 = min(max(v0, 0), fullSpan - span)
    }

    private var maxScroll: CGFloat { max(0, CGFloat(lanes.lanes.count) * Self.laneH - (bounds.height - Self.axisH)) }
    private func clampScroll() { scrollY = min(max(scrollY, 0), maxScroll) }

    override func setFrameSize(_ s: NSSize) {
        super.setFrameSize(s)
        clampScroll()
    }

    // MARK: Drawing

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let W = bounds.width, H = bounds.height, g = Self.gutter, axisH = Self.axisH, laneH = Self.laneH
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        let npp = nsPerPx
        let step = Self.niceStep(110 * npp)
        let ticks = stride(from: (v0 / step).rounded(.up) * step, through: v0 + span, by: step).map { $0 }

        // Rows, grid, bars: below the axis.
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: axisH, width: W, height: H - axisH))
        let count = lanes.lanes.count
        let first = max(0, Int(scrollY / laneH)), last = min(count - 1, Int((scrollY + H - axisH) / laneH))
        if first <= last {
            let alt = NSColor.alternatingContentBackgroundColors.count > 1 ? NSColor.alternatingContentBackgroundColors[1] : NSColor.gridColor
            for i in first...last where i % 2 == 1 {
                alt.setFill()
                CGRect(x: 0, y: axisH + CGFloat(i) * laneH - scrollY, width: W, height: laneH).fill()
            }
        }
        ctx.setFillColor(NSColor.separatorColor.withAlphaComponent(0.35).cgColor)
        for t in ticks {
            ctx.fill(CGRect(x: g + CGFloat((t - v0) / npp), y: axisH, width: 1, height: H - axisH))
        }
        ctx.saveGState()
        ctx.clip(to: CGRect(x: g, y: axisH, width: W - g, height: H - axisH))
        if first <= last {
            for i in first...last { drawBars(ctx, lane: i, y: axisH + CGFloat(i) * laneH - scrollY, npp: npp) }
        }
        if let s = selected, let rect = barRect(s, npp: npp) {
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(rect.insetBy(dx: -2, dy: -2))
        }
        if let h = hovered, let rect = barRect(h, npp: npp) {
            ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.6).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(rect.insetBy(dx: -1.5, dy: -1.5))
        }
        ctx.restoreGState()

        // Thread names.
        NSColor.controlBackgroundColor.setFill()
        CGRect(x: 0, y: axisH, width: g, height: H - axisH).fill()
        if first <= last {
            for i in first...last { drawLabel(lane: i, y: axisH + CGFloat(i) * laneH - scrollY) }
        }
        ctx.setFillColor(NSColor.separatorColor.cgColor)
        ctx.fill(CGRect(x: g - 1, y: 0, width: 1, height: H))
        if maxScroll > 0 {
            // Where the lanes showing are among all of them (no scroller: the view scrolls itself).
            let track = H - axisH - 4, total = CGFloat(count) * laneH
            let h = max(20, track * (H - axisH) / total)
            let y = axisH + 2 + (track - h) * scrollY / maxScroll
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(roundedRect: CGRect(x: W - 6, y: y, width: 4, height: h), xRadius: 2, yRadius: 2).fill()
        }
        ctx.restoreGState()

        // The time axis.
        NSColor.windowBackgroundColor.setFill()
        CGRect(x: 0, y: 0, width: W, height: axisH).fill()
        ctx.setFillColor(NSColor.separatorColor.cgColor)
        ctx.fill(CGRect(x: 0, y: axisH - 1, width: W, height: 1))
        let decimals = min(9, max(0, Int((-log10(step / 1e9)).rounded(.up))))
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                                    .foregroundColor: NSColor.secondaryLabelColor]
        for t in ticks {
            let x = g + CGFloat((t - v0) / npp)
            ctx.fill(CGRect(x: x, y: axisH - 6, width: 1, height: 5))
            (String(format: "%.*f s", decimals, t / 1e9) as NSString).draw(at: NSPoint(x: x + 3, y: 3), withAttributes: small)
        }
        let count1 = lanes.callCount
        let summary = "\(count) thread\(count == 1 ? "" : "s") · \(count1.formatted()) call\(count1 == 1 ? "" : "s")"
        NSColor.windowBackgroundColor.setFill()
        CGRect(x: 0, y: 0, width: g - 1, height: axisH - 1).fill()
        (summary as NSString).draw(at: NSPoint(x: 8, y: 4), withAttributes: small)

        // The pointer's time.
        if let m = mouse, m.x >= g {
            let x = m.x.rounded(.down) + 0.5
            ctx.setStrokeColor(NSColor.secondaryLabelColor.withAlphaComponent(0.6).cgColor)
            ctx.setLineWidth(1)
            ctx.strokeLineSegments(between: [CGPoint(x: x, y: axisH), CGPoint(x: x, y: H)])
            let t = v0 + Double(m.x - g) * npp
            let label = String(format: "+%.*f", min(9, decimals + 2), t / 1e9) as NSString
            let size = label.size(withAttributes: small)
            let box = CGRect(x: min(max(x - size.width / 2 - 4, g), W - size.width - 8), y: 2, width: size.width + 8, height: axisH - 5)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
            var white = small
            white[.foregroundColor] = NSColor.white
            label.draw(at: NSPoint(x: box.minX + 4, y: 4), withAttributes: white)
        }
    }

    /// Colour classes in drawing order: dyld's spans under the syscalls they make, waits under work.
    private static let classColors: [(NSColor, CGFloat)] = [
        (.systemTeal, 0.45), (.systemBlue, blockedAlpha), (.systemPurple, blockedAlpha),
        (.systemBlue, 1), (.systemPurple, 1), (.systemOrange, 0.55), (.systemRed, 1),
    ]

    private static func colorClass(_ r: SyscallRecord) -> Int {
        if r.isLibraryCall { return 0 }
        if r.failed { return 6 }
        // Still in the kernel at the stop: nearly always a parked thread, so lighter than work.
        if r.state == .inProgress { return 5 }
        // Entered before the trace: almost always a thread parked in a wait, and its real start is unknown.
        if r.blocked == true || r.state == .entryMissed { return r.mach ? 2 : 1 }
        return r.mach ? 4 : 3
    }

    private func drawBars(_ ctx: CGContext, lane li: Int, y: CGFloat, npp: Double) {
        let lane = lanes.lanes[li]
        let lo = v0, hi = v0 + span, g = Self.gutter
        let barY = y + Self.barInset, barH = Self.laneH - 2 * Self.barInset
        var open = [CGRect?](repeating: nil, count: Self.classColors.count)
        var rects = [[CGRect]](repeating: [], count: Self.classColors.count)
        var i = lane.firstReaching(UInt64(max(lo, 0)))
        while i < lane.starts.count {
            let s = Double(lane.starts[i])
            if s > hi { break }
            let e = Double(lane.ends[i])
            defer { i += 1 }
            if e < lo { continue }
            let x0 = max(g + CGFloat((s - lo) / npp), g - 2)
            let x1 = max(min(g + CGFloat((e - lo) / npp), bounds.width + 2), x0 + 1)
            let c = Self.colorClass(lane.calls[i])
            // Calls that touch the same pixels as the one before of their colour widen it rather than add a rect.
            if let r = open[c], x0 <= r.maxX + 0.5 {
                open[c] = CGRect(x: r.minX, y: barY, width: max(r.maxX, x1) - r.minX, height: barH)
            } else {
                if let r = open[c] { rects[c].append(r) }
                open[c] = CGRect(x: x0, y: barY, width: x1 - x0, height: barH)
            }
        }
        for c in rects.indices {
            if let r = open[c] { rects[c].append(r) }
            guard !rects[c].isEmpty else { continue }
            let (color, alpha) = Self.classColors[c]
            ctx.setFillColor(color.withAlphaComponent(alpha).cgColor)
            ctx.fill(rects[c])
        }
    }

    private func barRect(_ at: (lane: Int, index: Int), npp: Double) -> CGRect? {
        guard at.lane < lanes.lanes.count else { return nil }
        let lane = lanes.lanes[at.lane]
        guard at.index < lane.starts.count else { return nil }
        let x0 = Self.gutter + CGFloat((Double(lane.starts[at.index]) - v0) / npp)
        let x1 = max(Self.gutter + CGFloat((Double(lane.ends[at.index]) - v0) / npp), x0 + 1)
        let y = Self.axisH + CGFloat(at.lane) * Self.laneH - scrollY
        return CGRect(x: x0, y: y + Self.barInset, width: x1 - x0, height: Self.laneH - 2 * Self.barInset)
    }

    private func drawLabel(lane li: Int, y: CGFloat) {
        let lane = lanes.lanes[li]
        let n = lane.calls.count.formatted() as NSString
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                                    .foregroundColor: NSColor.tertiaryLabelColor]
        let nw = n.size(withAttributes: small).width
        n.draw(at: NSPoint(x: Self.gutter - 8 - nw, y: y + 4), withAttributes: small)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(string: String(lane.tid), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para])
        if let name = context.threadNames[lane.tid] {
            text.append(NSAttributedString(string: " " + name, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor, .paragraphStyle: para]))
        }
        if let color = threadColors[lane.tid] {
            color.setFill()
            NSBezierPath(roundedRect: CGRect(x: 4, y: y + 4, width: 4, height: Self.laneH - 8), xRadius: 2, yRadius: 2).fill()
        }
        text.draw(with: CGRect(x: 12, y: y + 3, width: Self.gutter - 28 - nw, height: Self.laneH - 4),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    static func niceStep(_ target: Double) -> Double {
        guard target > 0, target.isFinite else { return 1 }
        let p = pow(10, (log10(target)).rounded(.down))
        for m in [1.0, 2, 5] where m * p >= target { return m * p }
        return 10 * p
    }

    // MARK: Pointer

    private func lane(at p: NSPoint) -> Int? {
        guard p.y >= Self.axisH else { return nil }
        let i = Int((p.y - Self.axisH + scrollY) / Self.laneH)
        return i < lanes.lanes.count ? i : nil
    }

    private func hit(_ p: NSPoint) -> (lane: Int, index: Int)? {
        guard p.x >= Self.gutter, let li = lane(at: p) else { return nil }
        let t = v0 + Double(p.x - Self.gutter) * nsPerPx
        guard t >= 0 else { return nil }
        return lanes.lanes[li].call(at: UInt64(t), tolerance: UInt64(3 * nsPerPx)).map { (li, $0) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private func hover(_ p: NSPoint?) {
        mouse = p
        let h = p.flatMap(hit)
        if h?.lane != hovered?.lane || h?.index != hovered?.index {
            hovered = h
            onInfo?(record(h) ?? selectedRecord)
        }
        needsDisplay = true
    }

    override func mouseMoved(with e: NSEvent) { hover(convert(e.locationInWindow, from: nil)) }
    override func mouseExited(with e: NSEvent) { hover(nil) }

    override func scrollWheel(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let precise = e.hasPreciseScrollingDeltas
        let dx = e.scrollingDeltaX * (precise ? 1 : 12), dy = e.scrollingDeltaY * (precise ? 1 : Self.laneH)
        if e.modifierFlags.contains(.option) || e.modifierFlags.contains(.command) {
            zoom(exp(Double(dy) * 0.01), at: p.x)
        } else {
            if dx != 0 { v0 -= Double(dx) * nsPerPx; fitted = false; clampTime() }
            if dy != 0 { scrollY -= dy; clampScroll() }
        }
        hover(p)
    }

    override func magnify(with e: NSEvent) {
        zoom(1 + e.magnification, at: convert(e.locationInWindow, from: nil).x)
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(e.locationInWindow, from: nil)
        if e.clickCount == 2, let h = hit(p) { zoom(to: h); return }
        drag = (p, v0, scrollY)
        dragged = false
    }

    override func mouseDragged(with e: NSEvent) {
        guard let d = drag else { return }
        let p = convert(e.locationInWindow, from: nil)
        let dx = p.x - d.from.x, dy = p.y - d.from.y
        if !dragged && abs(dx) + abs(dy) < 3 { return }
        if !dragged { dragged = true; NSCursor.closedHand.push() }
        v0 = d.v0 - Double(dx) * nsPerPx
        if dx != 0 { fitted = false }
        clampTime()
        scrollY = d.y - dy
        clampScroll()
        hover(p)
    }

    override func mouseUp(with e: NSEvent) {
        defer { drag = nil }
        if dragged { NSCursor.pop(); dragged = false; return }
        guard drag != nil else { return }
        select(hit(convert(e.locationInWindow, from: nil)))
    }

    private func select(_ s: (lane: Int, index: Int)?) {
        selected = s
        selectedID = record(s)?.id
        onSelect?(record(s))
        onInfo?(record(hovered) ?? record(s))
        needsDisplay = true
    }

    override func keyDown(with e: NSEvent) {
        switch e.charactersIgnoringModifiers {
        case "=", "+": zoom(2, at: mouse.flatMap { $0.x >= Self.gutter ? $0.x : nil })
        case "-": zoom(0.5, at: mouse.flatMap { $0.x >= Self.gutter ? $0.x : nil })
        case "0": fit()
        default:
            if e.keyCode == 53, selected != nil { select(nil) } else { super.keyDown(with: e) }
        }
    }

    // MARK: Copy and the menu

    @objc func copy(_ sender: Any?) {
        guard let r = selectedRecord else { return }
        Pasteboard.copy(SyscallTraceView.line(r, context: context))
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        item.action == #selector(copy(_:)) ? selectedRecord != nil : true
    }

    override func menu(for e: NSEvent) -> NSMenu? {
        let p = convert(e.locationInWindow, from: nil)
        let menu = NSMenu()
        if let h = hit(p) {
            select(h)
            menu.addItem(item("Copy") { [weak self] in self?.copy(nil) })
            menu.addItem(item("Zoom to Call") { [weak self] in self?.zoom(to: h) })
            menu.addItem(.separator())
        }
        let tids: Set<UInt64> = lane(at: p).map { [lanes.lanes[$0].tid] } ?? []
        for (title, next) in ThreadFollow.items(rows: tids, shown: followed, names: context.threadNames) {
            menu.addItem(item(title) { [weak self] in self?.onFollow?(next) })
        }
        menu.addItem(item("Zoom to Fit") { [weak self] in self?.fit() })
        return menu
    }

    private func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let a = ProcessOutline.MenuAction(action)
        let i = NSMenuItem(title: title, action: #selector(ProcessOutline.MenuAction.fire), keyEquivalent: "")
        i.target = a
        i.representedObject = a   // keeps the target alive while the menu is
        return i
    }
}
