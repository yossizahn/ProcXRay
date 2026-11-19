import AppKit
import SwiftUI

/// Requests from outside the main window (the menu bar popover, the window picker) to show a process in
/// the process list.
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()
    struct Reveal: Equatable { var pid: pid_t; var gen: Int }
    private(set) var reveal: Reveal?
    func show(_ pid: pid_t) { reveal = Reveal(pid: pid, gen: (reveal?.gen ?? 0) + 1) }

    /// Opens the process list sorted by a column (descending), or with a predicate.
    static func showProcessList(sortedBy column: String? = nil, predicate: String? = nil) {
        let d = UserDefaults.standard
        d.set("Processes", forKey: "section")
        if let predicate { d.set(predicate, forKey: "processes.predicate") }
        if let column {
            ColumnPrefs.set(column, shown: true)   // a sort by a hidden column is dropped
            d.set("\(column),desc", forKey: "processes.columnSort")
        }
        if let w = openWindow { openMain(w) }
    }
    /// For the app delegate, which has no SwiftUI environment: kept by the menu bar label, which is always there
    /// when "Start in the menu bar" can be on.
    static var openWindow: OpenWindowAction?

    /// Brings the main window forward, opening one if none is open.
    static func openMain(_ openWindow: OpenWindowAction) {
        closeMenuBarPopover()
        AppActivation.willShowWindow()
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.styleMask.contains(.titled) }) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The menu bar popover stays open over the window it just brought forward unless it's closed. Closed as
    /// Escape closes it: `close()` leaves MenuBarExtra thinking it's still shown (the next click on the item is
    /// spent "closing" it), and clicking the status button programmatically does nothing.
    static func closeMenuBarPopover() {
        for w in NSApp.windows where w.isVisible && String(describing: type(of: w)).hasPrefix("MenuBarExtraWindow") {
            w.cancelOperation(nil)
        }
    }

    static func inspect(_ ref: ProcessRef, _ openWindow: OpenWindowAction) {
        closeMenuBarPopover()
        AppActivation.willShowWindow()
        openWindow(id: ProcessWindow.id, value: ref)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: Menu bar label

/// Compact numbers for the menu bar: "512K", "1.2M", "34M".
enum Compact {
    static func bytes(_ v: Double) -> String {
        let units = ["", "K", "M", "G", "T"]
        var x = max(0, v), i = 0
        while x >= 1000 && i < units.count - 1 { x /= 1024; i += 1 }
        if i == 0 { return String(format: "%.0f", x) }
        return x < 10 ? String(format: "%.1f%@", x, units[i]) : String(format: "%.0f%@", x, units[i])
    }
    static func percent(_ v: Double?) -> String { v.map { String(format: "%.0f%%", $0) } ?? "–" }
}

/// Text for the system figures beyond the tiles' headline numbers: clocks, GPU detail, swap and pressure.
extension SystemStats.Rates {
    static func clock(_ mhz: Double) -> String { mhz >= 1000 ? String(format: "%.2f GHz", mhz / 1000) : String(format: "%.0f MHz", mhz) }

    /// "2.06 GHz · 31 % active", "idle", or the share alone when the chip's DVFS table didn't fit.
    static func cluster(_ c: ClusterStats.Cluster, short: Bool = false) -> String {
        if c.active < 0.005 { return "idle" }
        let share = String(format: short ? "%.0f %%" : "%.0f %% active", c.active * 100)
        return c.mhz.map { clock($0) + " · " + share } ?? share
    }

    /// One line per CPU cluster, for tooltips.
    var cpuClusterLines: [String] {
        (clusters?.cpu ?? []).map { c in "\(c.title): \(Self.cluster(c))" + (c.maxMHz.map { " (max \(Self.clock($0)))" } ?? "") }
    }

    var gpuDetailLines: [String] {
        var out: [String] = []
        if let g = clusters?.gpu { out.append("Clock: \(Self.cluster(g))" + (g.maxMHz.map { " (max \(Self.clock($0)))" } ?? "")) }
        if let w = clusters?.gpuWatts { out.append(String(format: "Power: %.2f W", w)) }
        if let r = gpu?.renderer { out.append(String(format: "Renderer %.0f %%", r) + (gpu?.tiler.map { String(format: ", tiler %.0f %%", $0) } ?? "")) }
        if let m = gpu?.memoryInUse { out.append("Memory in use: \(Fmt.bytes(m))") }
        return out
    }

    var swapText: String? {
        guard let m = memory, let used = m.swapUsed else { return nil }
        return used == 0 ? "no swap in use" : "\(Fmt.bytes(used)) swapped" + (m.swapTotal.map { " (swap files \(Fmt.bytes($0)))" } ?? "")
    }

    var thermalText: String? { thermal.map { "Thermal pressure: " + SystemStats.thermalLevelName($0) } }
}

/// What the menu bar shows: the chosen widgets, drawn into one template image so the system tints it for
/// the menu bar's appearance; a warning sign first while any alert is live.
struct MenuBarLabel: View {
    @State private var monitor = AmbientMonitor.shared
    @State private var appearance = MenuBarAppearance.shared
    @AppStorage(AmbientPrefs.widgets) private var widgets = "cpu,memory"
    @AppStorage(AmbientPrefs.widgetGraphs) private var graphs = true
    @AppStorage(AmbientPrefs.widgetColors) private var colors = true
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let _ = AppRouter.openWindow = openWindow
        let list = widgets.split(separator: ",").compactMap { AmbientMetric(rawValue: String($0)) }
        let alert = monitor.attentionCount > 0
        if list.isEmpty {
            Image(systemName: alert ? "exclamationmark.triangle.fill" : "waveform.path.ecg")
        } else {
            Image(nsImage: render(list, alert: alert))
        }
    }

    @MainActor
    private func render(_ list: [AmbientMetric], alert: Bool) -> NSImage {
        // Colored graphs can't go in a template image (the system draws a template in one color), so the text is
        // drawn in the menu bar's own color: white on a dark menu bar, black on a light one.
        let colored = colors && graphs
        if colored { appearance.attachSoon() }
        let ink: Color = colored && appearance.dark ? .white : .black
        func widgets(_ ms: [AmbientMetric], alert: Bool) -> MenuBarWidgets {
            MenuBarWidgets(metrics: ms, alert: alert, graphs: graphs, system: monitor.system, history: monitor.systemHistory,
                           io: monitor.ioHistory, ink: ink, colored: colored)
        }
        let r = ImageRenderer(content: widgets(list, alert: alert))
        r.scale = NSScreen.main?.backingScaleFactor ?? 2
        let img = r.nsImage ?? NSImage()
        img.isTemplate = !colored
        MenuBarHit.shared.layout({ Self.ranges(list, alert: alert, widgets: widgets) }, imageWidth: img.size.width)
        return img
    }

    /// Each widget's x range in the label, for telling which one a click hit: each widget rendered on its own
    /// (the alert sign too), laid end to end with the HStack's spacing.
    @MainActor
    private static func ranges(_ list: [AmbientMetric], alert: Bool,
                               widgets: ([AmbientMetric], Bool) -> MenuBarWidgets) -> [(AmbientMetric, ClosedRange<CGFloat>)] {
        func width(_ v: MenuBarWidgets) -> CGFloat { ImageRenderer(content: v).nsImage?.size.width ?? 0 }
        var x: CGFloat = alert ? width(widgets([], true)) + MenuBarWidgets.spacing : 0
        var out: [(AmbientMetric, ClosedRange<CGFloat>)] = []
        for m in list {
            let w = width(widgets([m], false))
            out.append((m, x...(x + w)))
            x += w + MenuBarWidgets.spacing
        }
        return out
    }
}

/// The menu bar's appearance, which follows the wallpaper as well as Dark Mode: the status item window's
/// effectiveAppearance (the app's own appearance doesn't follow the menu bar). Watched with KVO once that window
/// exists, which is after the first label render.
@MainActor
@Observable
final class MenuBarAppearance {
    static let shared = MenuBarAppearance()
    private(set) var dark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var pending = false

    /// Looks for the status item's window after the current render (state can't change during one).
    func attachSoon() {
        guard observation == nil, !pending else { return }
        pending = true
        DispatchQueue.main.async { MainActor.assumeIsolated { self.attach() } }
    }

    private func attach() {
        pending = false
        guard observation == nil,
              let w = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("StatusBarWindow") }) else { return }
        update(w.effectiveAppearance)
        observation = w.observe(\.effectiveAppearance, options: [.new]) { w, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { MenuBarAppearance.shared.update(w.effectiveAppearance) } }
        }
    }

    private func update(_ a: NSAppearance) {
        let d = a.bestMatch(from: [.aqua, .darkAqua, .vibrantDark, .vibrantLight]).map { $0 == .darkAqua || $0 == .vibrantDark } ?? false
        if d != dark { dark = d }
    }
}

/// The widgets as one view (rendered to an image by MenuBarLabel). Black on clear when the image is a template;
/// with colored graphs, text in the menu bar's color and each graph in its metric's color.
struct MenuBarWidgets: View {
    let metrics: [AmbientMetric]
    let alert: Bool
    let graphs: Bool
    let system: SystemStats.Rates
    let history: [AmbientMetric: [Double]]
    var io: [IOSeries: [Double]] = [:]
    /// Black for the menu bar's template image; the Settings preview draws in the label color.
    var ink: Color = .black
    var colored = false

    /// Fixed colors (not dynamic system colors: the image is rendered outside any appearance). Memory follows
    /// the kernel's pressure level.
    private func graphColor(_ m: AmbientMetric) -> Color {
        guard colored else { return ink }
        switch m {
        case .cpu: return Color(red: 0.20, green: 0.78, blue: 0.35)
        case .gpu: return Color(red: 0.69, green: 0.32, blue: 0.87)
        case .memory:
            let p = system.memory?.pressure ?? 1
            return p >= 4 ? Color(red: 1, green: 0.27, blue: 0.23) : p >= 2 ? Color(red: 1, green: 0.62, blue: 0.04) : Color(red: 0.04, green: 0.52, blue: 1)
        case .disk, .network: return ink
        }
    }

    /// Incoming (disk read, network received) up from the middle in blue, outgoing (written, sent) down in red,
    /// as Activity Monitor colors them.
    private func ioColors() -> (Color, Color) {
        colored ? (Color(red: 0.04, green: 0.52, blue: 1), Color(red: 1, green: 0.27, blue: 0.23)) : (ink, ink)
    }

    /// Between widgets (and after the alert sign); MenuBarLabel.ranges lays them out with it too.
    static let spacing: CGFloat = 6

    var body: some View {
        HStack(spacing: Self.spacing) {
            if alert {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(colored ? Color(red: 1, green: 0.62, blue: 0.04) : ink)
            }
            ForEach(metrics) { m in widget(m) }
        }
        .foregroundStyle(ink)
        .frame(height: 18)
        .fixedSize()
    }

    @ViewBuilder
    private func widget(_ m: AmbientMetric) -> some View {
        HStack(spacing: 3) {
            if graphs {
                Group {
                    if m == .disk || m == .network {
                        let (up, down) = ioColors()
                        MirrorGraph(up: io[m == .disk ? .diskRead : .netIn] ?? [], down: io[m == .disk ? .diskWrite : .netOut] ?? [],
                                    upColor: up, downColor: down)
                    } else {
                        MiniGraph(values: history[m] ?? [], maxValue: 100, color: graphColor(m), filled: true)
                    }
                }
                .frame(width: 22, height: 14)
                // White behind colored graphs (a template image can't have one: it would draw as a solid block).
                .background(colored ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 1.5))
                .overlay(RoundedRectangle(cornerRadius: 1.5).stroke(ink.opacity(0.5), lineWidth: 0.75))
            }
            switch m {
            case .disk, .network:
                let (a, b): (Double?, Double?) = m == .disk ? (system.diskRead, system.diskWrite) : (system.netIn, system.netOut)
                VStack(alignment: .trailing, spacing: -2) {
                    Text(verbatim: (m == .disk ? "R " : "↓ ") + (a.map(Compact.bytes) ?? "–"))
                    Text(verbatim: (m == .disk ? "W " : "↑ ") + (b.map(Compact.bytes) ?? "–"))
                }
                .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                .frame(minWidth: 34, alignment: .trailing)
            default:
                VStack(alignment: .leading, spacing: -2) {
                    Text(verbatim: m.short).font(.system(size: 7, weight: .bold))
                    Text(verbatim: Compact.percent(value(m))).font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
                .frame(minWidth: 26, alignment: .leading)
            }
        }
    }

    private func value(_ m: AmbientMetric) -> Double? {
        switch m {
        case .cpu: system.cpuPercent
        case .gpu: system.gpuPercent
        case .memory: system.memory.map { $0.usedFraction * 100 }
        case .disk, .network: nil
        }
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
        Canvas { ctx, size in
            let peak = max(up.max() ?? 0, down.max() ?? 0, 1)
            let mid = size.height / 2
            let step = size.width / CGFloat(max(capacity - 1, 1))
            func draw(_ values: [Double], _ color: Color, _ sign: CGFloat) {
                guard values.count > 1 else { return }
                let start = size.width - CGFloat(values.count - 1) * step
                var area = Path()
                area.move(to: CGPoint(x: start, y: mid))
                for (i, v) in values.enumerated() {
                    area.addLine(to: CGPoint(x: start + CGFloat(i) * step, y: mid - sign * CGFloat(min(v / peak, 1)) * mid))
                }
                area.addLine(to: CGPoint(x: size.width, y: mid))
                area.closeSubpath()
                ctx.fill(area, with: .color(color.opacity(0.85)))
            }
            draw(up, upColor, 1)
            draw(down, downColor, -1)
        }
    }
}

/// A small area or line graph of the last readings, newest on the right; `maxValue` nil scales to the peak.
struct MiniGraph: View {
    let values: [Double]
    var maxValue: Double?
    var color: Color = .accentColor
    var filled = true
    var capacity = AmbientMonitor.historyLength

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let top = max(maxValue ?? (values.max() ?? 1), 1e-9)
            let step = size.width / CGFloat(max(capacity - 1, 1))
            let start = size.width - CGFloat(values.count - 1) * step
            var line = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: start + CGFloat(i) * step, y: size.height - CGFloat(min(v / top, 1)) * size.height)
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            if filled {
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: start, y: size.height))
                area.closeSubpath()
                ctx.fill(area, with: .color(color.opacity(0.55)))
            }
            ctx.stroke(line, with: .color(color), lineWidth: 1)
        }
    }
}

// MARK: Triage

/// The triage dashboard: system figures, what needs attention, top consumers, and what started and ended
/// lately. In the menu bar popover (compact) and the main window's Triage section.
struct TriageView: View {
    var compact = false
    @State private var monitor = AmbientMonitor.shared
    @AppStorage("triage.topMetric") private var topMetric: AmbientMetric = .cpu
    @AppStorage(AmbientPrefs.thirdPartyOnly) private var thirdPartyOnly = true
    @AppStorage(AmbientPrefs.alertsOn) private var alertsOn = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            tiles
            systemLine
            section("Needs attention", count: monitor.attentionCount, symbol: "exclamationmark.triangle") {
                ForEach(monitor.conditions) { c in ConditionRow(condition: c) }
                if !alertsOn {
                    empty("Alerts are off (Settings ▸ Alerts)")
                } else if monitor.attentionCount == 0 {
                    empty("Nothing needs attention")
                }
                ForEach(monitor.alerts) { a in AlertRow(alert: a) }
            }
            section("Top \(topMetric.title.lowercased())", count: nil, symbol: topMetric.symbol, trailing: {
                if let col = topMetric.columnID {
                    Button("Show All") { AppRouter.showProcessList(sortedBy: col) }
                        .buttonStyle(.borderless).font(.caption)
                        .help("Open the process list sorted by \(topMetric.title)")
                }
            }) {
                let list = monitor.topGroups[topMetric] ?? []
                if list.isEmpty { empty("No readings yet") }
                let peak = list.compactMap { topMetric.value($0.sums) }.max() ?? 1
                ForEach(list) { g in TopGroupRow(group: g, metric: topMetric, peak: peak) }
            }
            section("Just launched", count: monitor.launched.count, symbol: "sparkle", trailing: {
                Button("Show All") { AppRouter.showProcessList(predicate: FilterChip.recent.source) }
                    .buttonStyle(.borderless).font(.caption)
                    .help("Open the process list with Started < 5 min")
            }) {
                if monitor.launched.isEmpty { empty(thirdPartyOnly ? "No third-party process started lately" : "Nothing started lately") }
                ForEach(monitor.launched.prefix(compact ? 5 : 30)) { e in
                    ProcRow(proc: e.proc, detail: "\(Fmt.age(e.at)) ago", running: true)
                }
            }
            section("Recently ended", count: monitor.ended.count, symbol: "xmark.circle") {
                if monitor.ended.isEmpty { empty(thirdPartyOnly ? "No third-party process ended lately" : "Nothing ended lately") }
                ForEach(monitor.ended.prefix(compact ? 5 : 30)) { e in
                    ProcRow(proc: e.proc, detail: "ran \(duration(e.at.timeIntervalSince(e.proc.start))), \(Fmt.age(e.at)) ago", running: false)
                }
            }
            if !monitor.cleared.isEmpty {
                section("Earlier alerts", count: monitor.cleared.count, symbol: "clock.arrow.circlepath", trailing: {
                    Button("Clear") { monitor.clearEnded() }.buttonStyle(.borderless).font(.caption)
                }) {
                    ForEach(monitor.cleared.prefix(compact ? 5 : 30)) { a in AlertRow(alert: a) }
                }
            }
        }
    }

    private var tiles: some View {
        let s = monitor.system
        let h = monitor.systemHistory
        let mem = s.memory
        return HStack(spacing: 6) {
            tile(.cpu, Compact.percent(s.cpuPercent), h[.cpu] ?? [], max: 100,
                 help: (["Whole machine, all cores. Per core now: " + s.perCore.map { String(format: "%.0f", $0) }.joined(separator: " ")]
                        + s.cpuClusterLines + [s.thermalText].compactMap { $0 }).joined(separator: "\n"))
            tile(.gpu, Compact.percent(s.gpuPercent), h[.gpu] ?? [], max: 100,
                 help: (["GPU utilization (IOAccelerator)."] + s.gpuDetailLines).joined(separator: "\n"))
            tile(.memory, mem.map { Fmt.bytes($0.used) } ?? "–", h[.memory] ?? [], max: 100,
                 help: mem.map { "Used \(Fmt.bytes($0.used)) of \(Fmt.bytes($0.total)): app \(Fmt.bytes($0.app)), wired \(Fmt.bytes($0.wired)), compressed \(Fmt.bytes($0.compressed)); cached files \(Fmt.bytes($0.cached)). Pressure: \($0.pressure == 4 ? "critical" : $0.pressure == 2 ? "warning" : "normal")" + ($0.level.map { ", \($0) % available" } ?? "") + "." + (s.swapText.map { "\nSwap: \($0)." } ?? "") } ?? "")
            tile(.disk, s.disk.map { Compact.bytes($0) + "/s" } ?? "–", h[.disk] ?? [], max: nil,
                 help: "Read \(Fmt.bytes(s.diskRead.map { UInt64($0) }))/s, written \(Fmt.bytes(s.diskWrite.map { UInt64($0) }))/s, every disk.")
            tile(.network, s.net.map { Compact.bytes($0) + "/s" } ?? "–", h[.network] ?? [], max: nil,
                 help: "Received \(Fmt.bytes(s.netIn.map { UInt64($0) }))/s, sent \(Fmt.bytes(s.netOut.map { UInt64($0) }))/s, every interface but loopback.")
        }
    }

    /// Clocks, GPU power, swap and thermal pressure in one line under the tiles; parts with no reading are left out.
    @ViewBuilder
    private var systemLine: some View {
        let s = monitor.system
        let parts: [(String, String, Bool)] = (s.clusters?.cpu ?? []).map { ($0.title, SystemStats.Rates.cluster($0, short: true), false) }
            + [s.clusters?.gpu.map { ("GPU", SystemStats.Rates.cluster($0, short: true) + (s.clusters?.gpuWatts.map { String(format: " · %.2f W", $0) } ?? ""), false) },
               s.memory?.swapUsed.map { ("Swap", $0 == 0 ? "none" : Fmt.bytes($0), false) },
               s.thermal.map { ("Thermal", SystemStats.thermalLevelName($0), $0 >= 1) }].compactMap { $0 }
        if !parts.isEmpty {
            HStack(spacing: 12) {
                ForEach(parts, id: \.0) { p in
                    HStack(spacing: 3) {
                        Text(verbatim: p.0).foregroundStyle(.secondary)
                        Text(verbatim: p.1).monospacedDigit().foregroundStyle(p.2 ? .orange : .primary)
                    }
                }
            }
            .font(.caption).lineLimit(1)
            .help("CPU clusters and GPU: average clock while running, and the share of the time spent running, from IOReport. GPU power from IOReport's energy model. Swap from vm.swapusage. Thermal pressure from the kernel's notify(3) level.")
        }
    }

    private func tile(_ m: AmbientMetric, _ value: String, _ values: [Double], max: Double?, help: String) -> some View {
        let on = topMetric == m
        let tint: Color = m == .memory && (monitor.system.memory?.pressure ?? 1) >= 2 ? .orange : .accentColor
        return Button { topMetric = m } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(m.title).font(.caption2).foregroundStyle(.secondary)
                Text(verbatim: value).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                MiniGraph(values: values, maxValue: max, color: tint).frame(height: 18)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? AnyShapeStyle(Color.accentColor.opacity(0.15)) : AnyShapeStyle(.quaternary.opacity(0.5)), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? Color.accentColor.opacity(0.6) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help + " Click to list the top processes by \(m.title.lowercased()).")
    }

    private func section<C: View, T: View>(_ title: String, count: Int?, symbol: String,
                                           @ViewBuilder trailing: () -> T = { EmptyView() },
                                           @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 14)
                Text(title).font(.subheadline.weight(.semibold))
                if let count, count > 0 {
                    Text(verbatim: "\(count)").font(.caption).monospacedDigit().padding(.horizontal, 5)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                trailing()
            }
            content()
        }
    }

    private func empty(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary).padding(.leading, 19)
    }
}

func duration(_ s: TimeInterval) -> String {
    let s = max(0, Int(s))
    if s < 60 { return "\(s) s" }
    if s < 3600 { return "\(s / 60) m \(s % 60) s" }
    return "\(s / 3600) h \(s % 3600 / 60) m"
}

/// Icons for paths, cached (NSWorkspace.icon is slow enough to notice in a list redrawn every tick).
@MainActor
enum PathIcon {
    private static var cache: [String: NSImage] = [:]
    static func icon(_ path: String?) -> NSImage? {
        guard let path else { return nil }
        let key = path.range(of: ".app/", options: .backwards).map { String(path[..<$0.lowerBound]) + ".app" } ?? path
        if let i = cache[key] { return i }
        let i = NSWorkspace.shared.icon(forFile: key)
        i.size = NSSize(width: 16, height: 16)
        cache[key] = i
        return i
    }
}

/// One process in the triage lists. A click inspects it; the context menu has the rest.
struct ProcRow: View {
    let proc: AmbientProc
    let detail: String
    var fraction: Double? = nil
    var running = true
    var reason: String? = nil
    var tint: Color = .primary
    /// For a group's row: its process count, shown in place of the pid.
    var count: Int? = nil
    /// "· Firefox" after the name when the process belongs to a group it doesn't lead.
    var showGroup = true
    /// Replaces the path-and-click tooltip.
    var help: String? = nil
    @Environment(\.openWindow) private var openWindow
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            if let i = PathIcon.icon(proc.path) { Image(nsImage: i).resizable().frame(width: 16, height: 16) }
            else { Image(systemName: "terminal").frame(width: 16, height: 16).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(verbatim: proc.name).lineLimit(1).truncationMode(.middle).foregroundStyle(running ? tint : .secondary)
                        .layoutPriority(1)
                    if showGroup, let g = proc.groupName {
                        Text(verbatim: "· \(g)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                            .help("In the accounting group (resource coalition) of \(g)")
                    }
                    if let count {
                        Text(verbatim: "\(count) processes").font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    } else {
                        Text(verbatim: "\(proc.pid)").font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    }
                    if proc.notResponding {
                        Text("NOT RESPONDING").font(.system(size: 8, weight: .bold)).foregroundStyle(.red)
                            .padding(.horizontal, 3).background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 2))
                    }
                }
                if let reason { Text(verbatim: reason).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            Text(verbatim: detail).font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
        }
        .font(.callout)
        .padding(.vertical, 2).padding(.horizontal, 4)
        .background(alignment: .leading) {
            if let fraction {
                GeometryReader { g in
                    RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.13))
                        .frame(width: g.size.width * min(max(fraction, 0), 1))
                }
            }
        }
        .background(hover ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { inspect() }
        .help(help ?? (running ? "\(proc.path ?? proc.name)\nClick to inspect." : "\(proc.path ?? proc.name)\nExited; click to see its last state if Proc X-Ray still has it."))
        .contextMenu {
            Button("Inspect") { inspect() }
            Button("Show in Process List") { AppRouter.openMain(openWindow); AppRouter.shared.show(proc.pid) }.disabled(!running)
            if let path = proc.path {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
            Button("Copy PID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("\(proc.pid)", forType: .string) }
            if running {
                Divider()
                if proc.isApp { Button("Quit…") { signal(.quit, "Quit") } }
                Button(proc.isApp ? "Terminate (SIGTERM)…" : "Quit (SIGTERM)…") { signal(.unix(SIGTERM), proc.isApp ? "Terminate" : "Quit") }
                Button("Force Quit (SIGKILL)…") { signal(.unix(SIGKILL), "Force Quit") }
            }
        }
    }

    private func inspect() { AppRouter.inspect(proc.ref, openWindow) }

    private func signal(_ sig: ProcSignal, _ verb: String) {
        let a = NSAlert()
        a.messageText = "\(verb) \(proc.name) (pid \(proc.pid))?"
        a.informativeText = switch sig {
        case .quit: "The app is asked to quit, as ⌘Q does; it may ask to save first."
        case .unix(SIGKILL): "The process ends at once and loses anything unsaved."
        default: "The process is asked to quit."
        }
        a.addButton(withTitle: verb)
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        // The pid must still be this process: pids are reused.
        guard let live = Native.process(proc.pid), live.start.timeIntervalSince1970 == proc.start.timeIntervalSince1970 else {
            NSSound.beep(); return
        }
        if case .quit = sig {
            if NSRunningApplication(processIdentifier: proc.pid)?.terminate() != true {
                let e = NSAlert()
                e.messageText = "Couldn't quit \(proc.name)"
                e.informativeText = "It didn't accept the request to quit."
                e.runModal()
            }
        } else if case .unix(let n) = sig, kill(proc.pid, n) != 0 {
            let e = NSAlert()
            e.messageText = "Couldn't \(verb.lowercased()) \(proc.name)"
            e.informativeText = errno == EPERM ? "It belongs to another user or is protected by macOS." : String(cString: strerror(errno))
            e.runModal()
        }
        AmbientMonitor.shared.tick()
    }
}

/// A group in the top-consumer lists: its leader, process count and sum, with a chevron (for more than one
/// process) that lists the members contributing most.
struct TopGroupRow: View {
    let group: AmbientGroup
    let metric: AmbientMetric
    let peak: Double
    @State private var open = false

    var body: some View {
        let v = metric.value(group.sums)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                if group.single {
                    Color.clear.frame(width: 12, height: 14)
                } else {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 12, height: 14).contentShape(Rectangle())
                        .onTapGesture { open.toggle() }
                        .help(open ? "Hide the members" : "Show the members that use the most")
                }
                ProcRow(proc: group.leader, detail: v.map { group.sums.prefix(metric) + metric.format($0) } ?? "–",
                        fraction: (v ?? 0) / max(peak, 1e-9), count: group.single ? nil : group.count,
                        help: group.single ? nil
                          : "Accounting group (resource coalition) of \(group.count) processes, named after \(group.name)."
                            + (group.sums.coverageNote.map { " \($0)." } ?? "") + "\nClick to inspect \(group.name).")
            }
            if open {
                let top = group.members.filter { (metric.value($0) ?? 0) > 0 }
                    .sorted { (metric.value($0) ?? 0) > (metric.value($1) ?? 0) }.prefix(5)
                if top.isEmpty {
                    Text("No member has a reading above zero").font(.caption).foregroundStyle(.secondary).padding(.leading, 36)
                }
                ForEach(Array(top)) { m in
                    ProcRow(proc: m, detail: metric.value(m).map(metric.format) ?? "–", showGroup: false).padding(.leading, 24)
                }
                if group.count > top.count {
                    Text(verbatim: "\(group.count - top.count) more").font(.caption2).foregroundStyle(.tertiary).padding(.leading, 36)
                }
            }
        }
    }
}

struct AlertRow: View {
    let alert: AmbientAlert

    var body: some View {
        let live = alert.until == nil
        let span = (alert.until ?? Date()).timeIntervalSince(alert.since)
        let reason: String = {
            guard let m = alert.kind.metric else {
                return live ? "\(alert.kind.title) for \(duration(span))" : "Was not responding for \(duration(span)), \(Fmt.age(alert.until!)) ago"
            }
            return live ? "\(alert.kind.title) for \(duration(span)) · peak \(m.format(alert.peak))"
                        : "\(alert.kind.title) for \(duration(span)) · peak \(m.format(alert.peak)) · ended \(Fmt.age(alert.until!)) ago"
        }()
        ProcRow(proc: alert.proc, detail: live ? alert.kind.metric.map { $0.format(alert.current) } ?? "" : "",
                running: live || AmbientMonitor.shared.procs.contains { $0.key == alert.proc.key },
                reason: reason, tint: live ? (alert.kind == .notResponding ? .red : .orange) : .primary)
    }
}

/// Thermal or memory pressure, at the top of Needs Attention.
struct ConditionRow: View {
    let condition: SystemCondition

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: condition.symbol).foregroundStyle(.orange).frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: condition.title).foregroundStyle(.orange)
                Text(verbatim: "For \(duration(Date().timeIntervalSince(condition.since)))"
                     + (condition.peak > condition.level ? " · peak \(condition.kind == .thermal ? SystemStats.thermalLevelName(condition.peak) : "critical")" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.vertical, 2).padding(.horizontal, 4)
        .help(condition.explanation)
    }
}

// MARK: Main window

/// The sidebar's Triage section: the popover's dashboard at full size. Keeps the monitor sampling while
/// shown, even with the menu bar item off.
struct TriageSection: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        ScrollView {
            TriageView().padding(16).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
        }
        .navigationTitle("Triage")
        .toolbar {
            Button {
                WindowPicker.start { pid in
                    guard let k = Native.process(pid) else { return }
                    AppRouter.inspect(ProcessRef(pid: pid, start: k.start.timeIntervalSince1970), openWindow)
                }
            } label: { Label("Pick Window", systemImage: "scope") }
            .help("Click any window on screen to inspect the process that owns it (⌥⌘P shows it in the process list)")
        }
        .onAppear { AmbientMonitor.shared.addViewer() }
        .onDisappear { AmbientMonitor.shared.removeViewer() }
    }
}

/// Live alert count next to Triage in the sidebar.
struct TriageBadge: View {
    @State private var monitor = AmbientMonitor.shared
    var body: some View {
        let n = monitor.attentionCount
        if n > 0 {
            Spacer()
            Text(verbatim: "\(n)").font(.caption).padding(.horizontal, 6).background(.orange.opacity(0.3), in: Capsule())
        }
    }
}
