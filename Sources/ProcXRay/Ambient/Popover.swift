import AppKit
import SwiftUI

/// The menu bar dropdown, laid out like ProcessSpy's: system tiles with a detail tile that follows the
/// picked tile (a click cycles it), a filter tab bar with a triage switch on its left, the process list sorted by the chosen metric (each
/// row with its graph), and a toolbar. In triage mode the list gives way to the top consumers of the chosen
/// metric and an Ended / Launched / Alerts switch.
struct MenuBarPopover: View {
    @State private var monitor = AmbientMonitor.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    /// The metric the tiles select: the list's sort and the top consumers.
    @AppStorage("popover.metric") private var metric: AmbientMetric = .cpu
    @AppStorage("popover.detail") private var detail: AmbientMetric = .cpu
    @AppStorage("popover.triage") private var triage = false
    @AppStorage("popover.filter") private var filter: PopoverFilter = .all
    @AppStorage("popover.secondary") private var secondary: RowField = .none
    @AppStorage("popover.inline") private var inline: RowField = .pid
    @AppStorage("popover.triageTab") private var triageTab: TriageTab = .alerts

    static let width: CGFloat = 420

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                tiles
                DetailTile(area: detail, system: monitor.system, history: monitor.systemHistory)
                    .onTapGesture { detail = AmbientMetric.allCases[(AmbientMetric.allCases.firstIndex(of: detail)! + 1) % AmbientMetric.allCases.count] }
                    .help("Follows the tile picked above. Click to cycle CPU, GPU, memory, disk and network details")
            }
            .padding([.horizontal, .top], 10).padding(.bottom, 8)
            tabBar
            Divider()
            Group {
                if triage { triageBody } else { processList }
            }
            .frame(height: 380)
            Divider()
            toolbar
        }
        .frame(width: Self.width)
        // Opaque: the MenuBarExtra window's own background is a translucent material.
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        // The detail tile follows the metric picked in the tiles (or the Sort by menu).
        .onChange(of: metric) { _, m in detail = m }
        .onAppear { detail = metric }
        // Opened from one of the menu bar's widgets: show that one (MenuBarHit sets it as the window becomes key).
        .onChange(of: MenuBarHit.shared.opens) { _, _ in if let m = MenuBarHit.shared.metric { metric = m } }
    }

    // MARK: Tiles

    private var tiles: some View {
        let s = monitor.system, h = monitor.systemHistory
        return HStack(spacing: 5) {
            tile(.cpu, "CPU", Compact.percent(s.cpuPercent), h[.cpu] ?? [], max: 100)
            tile(.memory, "RAM", s.memory.map { Compact.bytes(Double($0.used)) } ?? "–", h[.memory] ?? [], max: 100)
            tile(.gpu, "GPU", Compact.percent(s.gpuPercent), h[.gpu] ?? [], max: 100)
            tile(.disk, "Disk I/O", s.disk.map { Compact.bytes($0) + "/s" } ?? "–", h[.disk] ?? [], max: nil)
            tile(.network, "Net I/O", s.net.map { Compact.bytes($0) + "/s" } ?? "–", h[.network] ?? [], max: nil)
        }
    }

    private func tile(_ m: AmbientMetric, _ title: String, _ value: String, _ values: [Double], max: Double?) -> some View {
        let on = metric == m
        return Button { metric = m } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Text(verbatim: value).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                MiniGraph(values: values, maxValue: max, color: on ? .accentColor : .secondary).frame(height: 16)
            }
            .padding(5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(.quaternary.opacity(0.45)),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? Color.accentColor.opacity(0.7) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(triage ? "Top consumers by \(m.title.lowercased())" : "Sort the list by \(m.title.lowercased())")
    }

    // MARK: Tab bar

    private var tabBar: some View {
        HStack(spacing: 4) {
            Button { triage.toggle() } label: {
                Image(systemName: "square.grid.2x2").frame(width: 24, height: 20)
                    .foregroundStyle(triage ? Color.white : .primary)
                    .background(triage ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary.opacity(0.6)), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(alignment: .topTrailing) {
                        if monitor.attentionCount > 0 && !triage { Circle().fill(.orange).frame(width: 7, height: 7).offset(x: 2, y: -2) }
                    }
            }
            .buttonStyle(.plain)
            .help(triage ? "Back to the process list" : "Triage: top consumers, what launched, what ended, alerts")
            if triage {
                Text("Process Triage").font(.subheadline.weight(.semibold)).padding(.leading, 4)
                Spacer()
            } else {
                ForEach(PopoverFilter.allCases) { f in
                    Button { filter = f } label: {
                        Text(f.title).font(.system(size: 11, weight: filter == f ? .semibold : .regular))
                            .padding(.horizontal, 8).frame(height: 20)
                            .foregroundStyle(filter == f ? Color.white : .primary)
                            .background(filter == f ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(f.help)
                }
                Spacer()
                Menu {
                    Picker("Sort by", selection: $metric) { ForEach(AmbientMetric.allCases) { Text($0.title).tag($0) } }
                    Picker("Secondary line", selection: $secondary) { ForEach(RowField.allCases) { Text($0.title).tag($0) } }
                    Picker("Inline value", selection: $inline) { ForEach(RowField.allCases) { Text($0.title).tag($0) } }
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Sort, secondary line and inline value")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
    }

    // MARK: Process list

    private var shown: [AmbientProc] {
        let me = getuid()
        return monitor.procs.filter { filter.matches($0, me: me) }
            .sorted { (metric.value($0) ?? -1, $1.pid) > (metric.value($1) ?? -1, $0.pid) }
    }

    private var processList: some View {
        let list = shown
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(list.prefix(150).enumerated()), id: \.element.id) { i, p in
                    PopoverRow(proc: p, metric: metric, history: monitor.procHistory[p.key]?.values(metric) ?? [],
                               secondary: secondary, inline: inline, striped: i % 2 == 1)
                }
                if list.isEmpty {
                    Text(monitor.procs.isEmpty ? "Reading…" : "No processes").foregroundStyle(.secondary).padding(.top, 40)
                }
            }
        }
    }

    // MARK: Triage

    private var triageBody: some View {
        let top = monitor.top[metric] ?? []
        let peak = top.compactMap { metric.value($0) }.max() ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Top consumers · \(metric.title)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                if top.isEmpty { Text("No readings yet").font(.caption).foregroundStyle(.secondary) }
                ForEach(top) { p in
                    ProcRow(proc: p, detail: metric.value(p).map(metric.format) ?? "–",
                            fraction: (metric.value(p) ?? 0) / max(peak, 1e-9))
                }
                if let best = peakOverHistory(top) {
                    Text(verbatim: "Peak over the last \(Int(Double(ProcHistory.length) * UserDefaults.standard.double(forKey: AmbientPrefs.interval) / 60 + 0.5)) min: \(best.name) \(metric.format(best.value))")
                        .font(.caption2).foregroundStyle(.secondary).padding(.top, 2)
                }
            }
            .padding(10)
            Picker("", selection: $triageTab) {
                ForEach(TriageTab.allCases) { t in Text(verbatim: "\(t.title) \(count(t))").tag(t) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 10)
            .shadow(color: monitor.attentionCount > 0 ? .orange.opacity(0.9) : .clear, radius: 5)
            .help(monitor.attentionCount == 0 ? "" : "\(monitor.attentionCount) live alert\(monitor.attentionCount == 1 ? "" : "s")")
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch triageTab {
                    case .ended:
                        if monitor.ended.isEmpty { empty("Nothing ended recently") }
                        ForEach(monitor.ended) { e in
                            ProcRow(proc: e.proc, detail: "ran \(duration(e.at.timeIntervalSince(e.proc.start))) · \(Fmt.age(e.at)) ago", running: false)
                        }
                    case .launched:
                        if monitor.launched.isEmpty { empty("Nothing new") }
                        ForEach(monitor.launched) { e in ProcRow(proc: e.proc, detail: "\(Fmt.age(e.at)) ago") }
                    case .alerts:
                        if monitor.attentionCount == 0 && monitor.cleared.isEmpty { empty("Nothing needs attention") }
                        ForEach(monitor.conditions) { c in ConditionRow(condition: c) }
                        ForEach(monitor.alerts) { a in AlertRow(alert: a) }
                        if !monitor.cleared.isEmpty {
                            HStack {
                                Text("Cleared").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Spacer()
                                Button("Clear") { monitor.clearEnded() }.buttonStyle(.borderless).font(.caption)
                            }
                            .padding(.top, 6)
                            ForEach(monitor.cleared) { a in AlertRow(alert: a) }
                        }
                    }
                }
                .padding(10)
            }
        }
    }

    private func count(_ t: TriageTab) -> Int {
        switch t {
        case .ended: monitor.ended.count
        case .launched: monitor.launched.count
        case .alerts: monitor.attentionCount + monitor.cleared.count
        }
    }

    private func peakOverHistory(_ list: [AmbientProc]) -> (name: String, value: Double)? {
        var best: (String, Double)?
        for p in list {
            if let v = monitor.procHistory[p.key]?.values(metric).max(), v > (best?.1 ?? 0) { best = (p.name, v) }
        }
        return best
    }

    private func empty(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 30)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit Proc X-Ray")
            Text(verbatim: "\(min(shown.count, 150)) / \(monitor.procs.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .help("Processes shown / running" + (shown.count > 150 ? " (the list shows the first 150 of \(shown.count))" : ""))
            Spacer()
            Button {
                WindowPicker.start { pid in
                    guard let k = Native.process(pid) else { return }
                    AppRouter.inspect(ProcessRef(pid: pid, start: k.start.timeIntervalSince1970), openWindow)
                }
            } label: { Image(systemName: "scope") }.help("Pick a window on screen to inspect its process")
            Button { AppActivation.willShowWindow(); openSettings(); NSApp.activate(ignoringOtherApps: true) } label: { Image(systemName: "gearshape") }
                .help("Settings")
            Button { AppRouter.openMain(openWindow) } label: { Image(systemName: "macwindow") }.help("Open the main window")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 7)
    }
}

enum TriageTab: String, CaseIterable, Identifiable {
    case ended, launched, alerts
    var id: String { rawValue }
    var title: String { self == .ended ? "Ended" : self == .launched ? "Launched" : "Alerts" }
}

/// The popover's filter tabs.
enum PopoverFilter: String, CaseIterable, Identifiable {
    case all, apps, thirdParty, mine
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .apps: "Apps"
        case .thirdParty: "3rd party"
        case .mine: "Mine"
        }
    }
    var help: String {
        switch self {
        case .all: "Every process"
        case .apps: "Apps with a Dock icon"
        case .thirdParty: "Not Apple's (by path: outside /System, /usr, /bin, /sbin, /Library/Apple)"
        case .mine: "Processes running as you"
        }
    }
    func matches(_ p: AmbientProc, me: uid_t) -> Bool {
        switch self {
        case .all: true
        case .apps: p.isApp
        case .thirdParty: !p.apple
        case .mine: p.uid == me
        }
    }
}

/// What a row can show besides its name and metric.
enum RowField: String, CaseIterable, Identifiable {
    case none, pid, memory, cpu, path
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "None"
        case .pid: "PID"
        case .memory: "Memory"
        case .cpu: "CPU"
        case .path: "Path"
        }
    }
    func text(_ p: AmbientProc) -> String? {
        switch self {
        case .none: nil
        case .pid: "\(p.pid)"
        case .memory: p.footprint.map { Fmt.bytes($0) }
        case .cpu: p.cpu.map { AmbientMetric.cpu.format($0) }
        case .path: p.path
        }
    }
}

/// One process in the dropdown: icon, name, inline value, optional second line, its graph, its value.
/// A click shows it in the main window's process list; the context menu has the rest.
struct PopoverRow: View {
    let proc: AmbientProc
    let metric: AmbientMetric
    let history: [Double]
    let secondary: RowField
    let inline: RowField
    let striped: Bool
    @Environment(\.openWindow) private var openWindow
    @State private var hover = false

    var body: some View {
        HStack(spacing: 7) {
            if let i = PathIcon.icon(proc.path) { Image(nsImage: i).resizable().frame(width: 16, height: 16) }
            else { Image(systemName: "terminal").font(.system(size: 11)).frame(width: 16, height: 16).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(verbatim: proc.name).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(proc.notResponding ? Color.red : .primary)
                    if let t = inline.text(proc) {
                        Text(verbatim: t).font(.caption2).foregroundStyle(.tertiary).monospacedDigit().lineLimit(1)
                    }
                    if proc.notResponding {
                        Text("NOT RESPONDING").font(.system(size: 8, weight: .bold)).foregroundStyle(.red)
                            .padding(.horizontal, 3).background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 2))
                    }
                }
                if let t = secondary.text(proc) {
                    Text(verbatim: t).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            MiniGraph(values: history, maxValue: metric == .cpu || metric == .gpu ? max(100, history.max() ?? 0) : nil,
                      color: .accentColor, capacity: ProcHistory.length)
                .frame(width: 56, height: 16)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 3))
            Text(verbatim: metric.value(proc).map(metric.format) ?? "–")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 66, alignment: .trailing).lineLimit(1)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10).frame(minHeight: 26)
        .background(hover ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : striped ? AnyShapeStyle(.quaternary.opacity(0.3)) : AnyShapeStyle(.clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { AppRouter.openMain(openWindow); AppRouter.shared.show(proc.pid) }
        .help("\(proc.path ?? proc.name)\nClick to show it in the process list.")
        .contextMenu {
            Button("Show in Process List") { AppRouter.openMain(openWindow); AppRouter.shared.show(proc.pid) }
            Button("Inspect") { AppRouter.inspect(proc.ref, openWindow) }
            if let path = proc.path {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
            Button("Copy PID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("\(proc.pid)", forType: .string) }
        }
    }
}

/// The tile under the metric tiles: more about one area, cycled by clicking it.
struct DetailTile: View {
    let area: AmbientMetric
    let system: SystemStats.Rates
    let history: [AmbientMetric: [Double]]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: area.symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 3) {
                    ForEach(AmbientMetric.allCases) { m in
                        Circle().fill(m == area ? Color.accentColor : Color.secondary.opacity(0.35)).frame(width: 4, height: 4)
                    }
                }
            }
            content.frame(height: 38)
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    private var title: String {
        switch area {
        case .cpu:
            let k = SystemStats.coreKinds
            let clusters = system.clusters?.cpu ?? []
            // With the clusters' clocks there's no room for the words "per-core usage" (measured: 351 pt of ~330).
            var t = k.performance > 0 ? "\(clusters.isEmpty ? "Per-core usage · " : "")\(k.efficiency)E + \(k.performance)P" : "Per-core usage"
            // Each cluster's clock while running.
            for c in clusters {
                t += " · \(c.kind) " + (c.active < 0.005 ? "idle" : c.mhz.map(SystemStats.Rates.clock) ?? String(format: "%.0f%%", c.active * 100))
            }
            if let th = system.thermal, th >= 1 { t += " · thermal \(SystemStats.thermalLevelName(th))" }
            return t
        case .gpu: return "GPU busy share"
        case .memory:
            var t = "Memory"
            if let m = system.memory, let u = m.swapUsed { t += " · swap " + (u == 0 ? "none" : Compact.bytes(Double(u))) }
            if let l = system.memory?.level { t += " · \(l)% available" }
            return t
        case .disk: return "Disk read and written"
        case .network: return "Network received and sent"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch area {
        case .cpu:
            let e = SystemStats.coreKinds.efficiency
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(system.perCore.enumerated()), id: \.offset) { i, v in
                    VStack(spacing: 1) {
                        GeometryReader { g in
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(i < e ? Color.teal : Color.accentColor)
                                    .frame(height: max(1, g.size.height * min(v, 100) / 100))
                            }
                        }
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 1.5))
                        Text(verbatim: i < e ? "E" : "P").font(.system(size: 7)).foregroundStyle(.secondary)
                    }
                    .help(String(format: "Core %d (%@): %.0f %%", i, i < e ? "efficiency" : "performance", v))
                }
            }
        case .gpu:
            HStack(spacing: 10) {
                Text(verbatim: Compact.percent(system.gpuPercent)).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                let lines = gpuLines
                if !lines.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(lines, id: \.self) { Text(verbatim: $0) }
                    }
                    .font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                }
                MiniGraph(values: history[.gpu] ?? [], maxValue: 100)
            }
        case .memory:
            if let m = system.memory {
                VStack(alignment: .leading, spacing: 3) {
                    GeometryReader { g in
                        HStack(spacing: 1) {
                            seg(m.wired, m.total, .orange, g.size.width)
                            seg(m.app, m.total, .accentColor, g.size.width)
                            seg(m.compressed, m.total, .purple, g.size.width)
                            seg(m.cached, m.total, .gray.opacity(0.6), g.size.width)
                            Spacer(minLength: 0)
                        }
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 2))
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                    }
                    .frame(height: 12)
                    HStack(spacing: 8) {
                        legend("Wired", m.wired, .orange); legend("App", m.app, .accentColor)
                        legend("Compr.", m.compressed, .purple); legend("Cached", m.cached, .gray)
                        Spacer(minLength: 0)
                        Text(m.pressure == 4 ? "critical" : m.pressure == 2 ? "pressure" : "normal")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(m.pressure >= 2 ? .orange : .green)
                    }
                }
            }
        case .disk:
            inOut("Read", system.diskRead, "Written", system.diskWrite)
        case .network:
            inOut("In", system.netIn, "Out", system.netOut)
        }
    }

    /// At most three short lines: clock and power, renderer and tiler, memory in use.
    private var gpuLines: [String] {
        var out: [String] = []
        let c = system.clusters
        let clock = c?.gpu.map { $0.active < 0.005 ? "idle" : $0.mhz.map(SystemStats.Rates.clock) ?? String(format: "%.0f%% active", $0.active * 100) }
        let power = c?.gpuWatts.map { String(format: "%.2f W", $0) }
        if clock != nil || power != nil { out.append([clock, power].compactMap { $0 }.joined(separator: " · ")) }
        if let g = system.gpu, let r = g.renderer { out.append(String(format: "render %.0f%%", r) + (g.tiler.map { String(format: " · tiler %.0f%%", $0) } ?? "")) }
        if let m = system.gpu?.memoryInUse { out.append("mem " + Compact.bytes(Double(m))) }
        return out
    }

    private func seg(_ v: UInt64, _ total: UInt64, _ c: Color, _ width: CGFloat) -> some View {
        Rectangle().fill(c).frame(width: max(0, width * CGFloat(Double(v) / Double(max(total, 1))) - 1))
    }

    private func legend(_ t: String, _ v: UInt64, _ c: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text(verbatim: "\(t) \(Compact.bytes(Double(v)))").font(.system(size: 9)).monospacedDigit()
        }
    }

    private func inOut(_ a: String, _ av: Double?, _ b: String, _ bv: Double?) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(a) \(av.map { Compact.bytes($0) + "/s" } ?? "–")").foregroundStyle(Color.accentColor)
                Text(verbatim: "\(b) \(bv.map { Compact.bytes($0) + "/s" } ?? "–")").foregroundStyle(.orange)
            }
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .frame(width: 110, alignment: .leading)
            MiniGraph(values: history[area] ?? [], maxValue: nil)
        }
    }
}
