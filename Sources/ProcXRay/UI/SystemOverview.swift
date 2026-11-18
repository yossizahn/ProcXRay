import IOKit.pwr_mgt
import SwiftUI

/// What a dashboard shows: panels of metrics, built each tick from counter readings (`Dashboards`).
struct Metric: Identifiable, Hashable {
    /// History key: a metric keeps its graph across ticks by id.
    var id: String
    var title: String
    /// Graphed (nil: text only).
    var value: Double?
    var text: String
    var sub: String = ""
    var help: String = ""
    /// The counter it comes from, for "Show in All Counters".
    var counter: String?
    /// Scale for bars and graphs (nil: the largest value).
    var max: Double?
}

struct TableRow: Identifiable, Hashable {
    var id: String
    var cells: [String]
    var help: String = ""
    var pid: pid_t?
}

struct Panel: Identifiable {
    enum Kind {
        case tiles([Metric])
        case bars([Metric])
        case facts([Metric])
        /// The first `leading` columns are text, aligned left; the rest are numbers, aligned right.
        case table(columns: [String], rows: [TableRow], leading: Int)
        case note(String)
    }
    var id: String
    var title: String
    var help: String = ""
    var kind: Kind
}

/// Readings that aren't counters, taken with each tick for the tabs that use them.
struct OverviewExtras: Sendable {
    var thermal: Int32?
    var assertions: [Assertion] = []
    var swapUsed: UInt64?, swapTotal: UInt64?
    var pressure: Int32?

    struct Assertion: Sendable, Hashable { var pid: pid_t; var process: String; var type: String; var name: String }

    static func read(for tab: SystemOverview.Tab) -> OverviewExtras {
        var x = OverviewExtras()
        switch tab {
        case .thermal, .cpu:
            x.thermal = SystemStats.thermalPressure()
        case .power:
            var u: Unmanaged<CFDictionary>?
            if IOPMCopyAssertionsByProcess(&u) == kIOReturnSuccess, let d = u?.takeRetainedValue() as NSDictionary? {
                for case let (pid as NSNumber, list as [NSDictionary]) in d {
                    let p = pid.int32Value
                    let name = Native.process(p)?.comm ?? "pid \(p)"
                    for a in list {
                        // Level 0 is an assertion that was created but isn't held right now.
                        if let level = a["AssertLevel"] as? NSNumber, level.intValue == 0 { continue }
                        x.assertions.append(Assertion(pid: p, process: name, type: a["AssertType"] as? String ?? "?",
                                                      name: a["AssertName"] as? String ?? ""))
                    }
                }
            }
            x.assertions.sort { ($0.type, $0.process) < ($1.type, $1.process) }
        case .memory:
            var swap = xsw_usage()
            var size = MemoryLayout<xsw_usage>.size
            if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { x.swapUsed = swap.xsu_used; x.swapTotal = swap.xsu_total }
            var level: Int32 = 0
            size = MemoryLayout<Int32>.size
            if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 { x.pressure = level }
        default:
            break
        }
        return x
    }
}

/// System ▸ Overview: curated dashboards over the counter catalog. While shown, it reads the open tab's groups
/// once a second and rebuilds its panels; each metric keeps two minutes of history for its graph.
@Observable @MainActor
final class SystemOverview {
    static let shared = SystemOverview()
    static let historyLength = 120

    enum Tab: String, CaseIterable, Identifiable {
        case cpu = "CPU", memory = "Memory", power = "Power", thermal = "Thermal", storage = "Storage", network = "Network", gpu = "GPU"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .cpu: "cpu"
            case .memory: "memorychip"
            case .power: "bolt"
            case .thermal: "thermometer.medium"
            case .storage: "internaldrive"
            case .network: "network"
            case .gpu: "rectangle.3.group"
            }
        }
    }

    var tab: Tab = Tab(rawValue: UserDefaults.standard.string(forKey: "overview.tab") ?? "") ?? .cpu {
        didSet {
            UserDefaults.standard.set(tab.rawValue, forKey: "overview.tab")
            if tab != oldValue { panels = []; tick() }
        }
    }
    private(set) var panels: [Panel] = []
    private(set) var history: [String: [Double]] = [:]
    /// Each history sample's text and time, for the graph's hover.
    @ObservationIgnored private(set) var historyText: [String: [String]] = [:]
    @ObservationIgnored private(set) var historyAt: [String: [Date]] = [:]
    /// The busiest app per metric at each tick (AmbientMonitor's top accounting groups), for the graph's hover.
    @ObservationIgnored private var leaders: [(at: Date, top: [AmbientMetric: String])] = []
    private(set) var lastReadMillis: Double?
    private(set) var loading = false

    @ObservationIgnored private var catalog: [String: CounterGroup] = [:]
    @ObservationIgnored private var latest: [String: CounterValue] = [:]
    @ObservationIgnored private var previous: [String: CounterValue] = [:]
    @ObservationIgnored private var rates: [String: Double] = [:]
    @ObservationIgnored private var readAt: [String: UInt64] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var reading = false

    func addViewer() {
        viewers += 1
        // The menu bar's monitor ranks apps per metric; it keeps sampling while this view is open (the
        // graphs' hover names the busiest app at each moment).
        AmbientMonitor.shared.addViewer()
        if catalog.isEmpty && !loading {
            loading = true
            let engine = CounterEngine.shared
            engine.queue.async {
                let g = engine.catalog()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    catalog = Dictionary(g.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    loading = false
                    tick()
                }
            }
        }
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func removeViewer() {
        if viewers > 0 { AmbientMonitor.shared.removeViewer() }
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    func tick() {
        guard viewers > 0, !reading, !catalog.isEmpty else { return }
        let tab = tab
        let want = Dashboards.groups(for: tab, in: catalog)
        reading = true
        let engine = CounterEngine.shared
        engine.queue.async {
            let t = DispatchTime.now().uptimeNanoseconds
            let r = engine.read(want)
            let extras = OverviewExtras.read(for: tab)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
            Task { @MainActor [weak self] in
                guard let self else { return }
                reading = false
                apply(r)
                lastReadMillis = ms
                guard tab == self.tab else { tick(); return }
                let ctx = DashContext(groups: catalog, values: latest, previous: previous, rates: rates, extras: extras)
                let built = Dashboards.build(tab, ctx)
                let now = Date()
                for p in built {
                    switch p.kind {
                    case .tiles(let m), .bars(let m): for x in m { if let v = x.value { push(x.id, v, x.text, now) } }
                    default: break
                    }
                }
                recordLeaders(now)
                panels = built
            }
        }
    }

    private func apply(_ r: CounterReading) {
        for (id, v) in r.values {
            if let old = latest[id], let at = readAt[id], r.at > at {
                previous[id] = old
                rates[id] = v.delta(from: old).map { $0 / (Double(r.at - at) / 1e9) }
            }
            latest[id] = v
            readAt[id] = r.at
        }
    }

    private func push(_ id: String, _ v: Double, _ text: String, _ at: Date) {
        func add<T>(_ h: inout [String: [T]], _ x: T) {
            var a = h[id] ?? []
            a.append(x)
            if a.count > Self.historyLength { a.removeFirst(a.count - Self.historyLength) }
            h[id] = a
        }
        add(&history, v)
        add(&historyText, text)
        add(&historyAt, at)
    }

    private func recordLeaders(_ at: Date) {
        var top: [AmbientMetric: String] = [:]
        for (m, list) in AmbientMonitor.shared.topGroups {
            guard let g = list.first, let v = m.value(g.sums), v > 0 else { continue }
            top[m] = "\(g.name) \(g.sums.prefix(m))\(m.format(v))"
        }
        leaders.append((at, top))
        if leaders.count > Self.historyLength { leaders.removeFirst(leaders.count - Self.historyLength) }
    }

    /// The metric whose busiest app explains a tile: CPU for CPU, power and heat, and the obvious one elsewhere.
    static func leaderMetric(for id: String) -> AmbientMetric {
        switch id.prefix { $0 != "." } {
        case "mem": .memory
        case "st": .disk
        case "net": .network
        case "gpu": .gpu
        default: .cpu
        }
    }

    /// Sample `i` of a metric's history: its text, how long ago, and the busiest app then.
    func sample(_ id: String, _ i: Int) -> (text: String, ago: TimeInterval, leader: String?)? {
        guard let texts = historyText[id], let dates = historyAt[id], texts.indices.contains(i), dates.indices.contains(i) else { return nil }
        let at = dates[i]
        let m = Self.leaderMetric(for: id)
        // The monitor ticks on its own interval: take the last ranking made by then.
        let leader = leaders.last { $0.at <= at.addingTimeInterval(0.5) }?.top[m]
        return (texts[i], -at.timeIntervalSinceNow, leader.map { "top: \($0)" })
    }
}

// MARK: Views

struct SystemOverviewView: View {
    @State private var m = SystemOverview.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var m = m
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if m.panels.isEmpty {
                    ProgressView(m.loading ? "Listing counters…" : "Reading…").frame(maxWidth: .infinity).padding(.top, 60)
                }
                ForEach(m.panels) { p in panel(p) }
            }
            .padding(16)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("System Overview")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Area", selection: $m.tab) {
                    ForEach(SystemOverview.Tab.allCases) { t in Text(t.rawValue).tag(t) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let ms = m.lastReadMillis {
                Text(String(format: "Read once a second, last in %.1f ms", ms)).font(.caption).foregroundStyle(.secondary)
                    .padding(6).frame(maxWidth: .infinity, alignment: .trailing)
                    .help("Only the open tab's counters are read")
            }
        }
        .onAppear { m.addViewer() }
        .onDisappear { m.removeViewer() }
    }

    @ViewBuilder private func panel(_ p: Panel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !p.title.isEmpty {
                Text(p.title).font(.headline).help(p.help)
            }
            switch p.kind {
            case .tiles(let list):
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(list) { tile($0) }
                }
            case .bars(let list):
                let top = list.compactMap { $0.max ?? $0.value }.max() ?? 1
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(list) { barRow($0, top: top) }
                }
            case .facts(let list):
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    ForEach(list) { f in
                        GridRow {
                            Text(f.title).foregroundStyle(.secondary).help(f.help)
                            Text(f.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        .contextMenu { reveal(f) }
                    }
                }
                .font(.callout)
            case .table(let columns, let rows, let leading):
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        ForEach(Array(columns.enumerated()), id: \.offset) { i, c in
                            Text(c).gridColumnAlignment(i < leading ? .leading : .trailing)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    ForEach(rows) { r in
                        GridRow {
                            ForEach(Array(r.cells.enumerated()), id: \.offset) { i, c in
                                Text(c).monospacedDigit().lineLimit(1).truncationHelp(c)
                                    .gridColumnAlignment(i < leading ? .leading : .trailing)
                            }
                        }
                        .help(r.help)
                        .contextMenu {
                            if let pid = r.pid, let k = Native.process(pid) {
                                Button("Inspect \(k.comm)") {
                                    AppRouter.inspect(ProcessRef(pid: pid, start: k.start.timeIntervalSince1970), openWindow)
                                }
                            }
                        }
                    }
                }
                .font(.callout)
            case .note(let s):
                Text(s).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tile(_ x: Metric) -> some View {
        MetricTile(metric: x, values: m.history[x.id] ?? []).contextMenu { reveal(x) }
    }

    private func barRow(_ x: Metric, top: Double) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text(x.title).lineLimit(1).truncationHelp(x.title)
                if !x.sub.isEmpty { Text(x.sub).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationHelp(x.sub) }
            }
            .frame(width: 230, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(.quaternary.opacity(0.5))
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.75))
                        .frame(width: max(0, min(1, (x.value ?? 0) / max(top, 1e-12))) * g.size.width)
                }
            }
            .frame(height: 9)
            Text(x.text).monospacedDigit().frame(width: 110, alignment: .trailing).lineLimit(1)
            MiniGraph(values: m.history[x.id] ?? [], maxValue: nil, capacity: SystemOverview.historyLength)
                .frame(width: 80, height: 16)
        }
        .font(.callout)
        .help(x.help)
        .contextMenu { reveal(x) }
    }

    @ViewBuilder private func reveal(_ x: Metric) -> some View {
        if let id = x.counter {
            Button("Show in All Counters") { CounterBrowser.shared.reveal(id) }
        }
    }
}

/// A dashboard tile: the metric now, and its last two minutes. Hovering the graph shows the value at that point,
/// when, and the busiest app then.
private struct MetricTile: View {
    let metric: Metric
    let values: [Double]
    @State private var hover: Int?

    var body: some View {
        let sample = hover.flatMap { SystemOverview.shared.sample(metric.id, $0) }
        VStack(alignment: .leading, spacing: 2) {
            Text(metric.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            Text(sample?.text ?? metric.text).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
                .foregroundStyle(sample == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.accentColor))
            let sub = sample.map { s in [String(format: "%.0f s ago", s.ago), s.leader].compactMap { $0 }.joined(separator: " · ") } ?? metric.sub
            Text(sub.isEmpty ? " " : sub).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationHelp(sub)
            MiniGraph(values: values, maxValue: metric.max, capacity: SystemOverview.historyLength)
                .frame(height: 30)
                .overlay { marker }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): hover = index(at: p.x)
                    case .ended: hover = nil
                    }
                }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
        .help(sample == nil ? metric.help : "")
    }

    @State private var width: CGFloat = 1

    /// MiniGraph's geometry: samples spaced width / (capacity − 1) apart, the newest at the right edge.
    private func index(at x: CGFloat) -> Int? {
        guard values.count > 1 else { return nil }
        let step = width / CGFloat(SystemOverview.historyLength - 1)
        let start = width - CGFloat(values.count - 1) * step
        let i = Int(((x - start) / step).rounded())
        return values.indices.contains(i) ? i : nil
    }

    private var marker: some View {
        GeometryReader { g in
            Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w }
            if let i = hover, values.count > 1 {
                let step = g.size.width / CGFloat(SystemOverview.historyLength - 1)
                let x = g.size.width - CGFloat(values.count - 1 - i) * step
                Rectangle().fill(Color.accentColor).frame(width: 1).position(x: x, y: g.size.height / 2).frame(height: g.size.height)
            }
        }
    }
}
