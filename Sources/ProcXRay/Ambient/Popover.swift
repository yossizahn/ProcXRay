import AppKit
import SwiftUI

/// The menu bar dropdown, laid out like ProcessSpy's: system tiles with a detail tile that follows the
/// picked tile (a click cycles it), a filter tab bar with a triage switch on its left, the process list sorted by the chosen metric (each
/// row with its graph), and a toolbar. In triage mode the list gives way to the top consumers of the chosen
/// metric and an Ended / Launched / Alerts switch.
struct MenuBarPopover: View {
    /// The monitor's state as of the popover's last time on screen (AmbientShown).
    @State private var monitor = AmbientMonitor.shared.popover
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
    /// Accounting groups (resource coalitions) or single processes.
    @AppStorage("popover.grouped") private var grouped = true
    /// Expanded groups ("g<id>") and sub-groups ("g<id>/<kind>"), for the life of the popover.
    @State private var expanded: Set<String> = []

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
        .background(WindowVisibility { w, visible in
            AmbientMonitor.shared.popover.window = w
            AmbientMonitor.shared.popover.live = visible
        })
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
                Picker("", selection: $grouped) {
                    Image(systemName: "square.stack.3d.up").help("Groups: accounting groups (resource coalitions), each named after its leader").tag(true)
                    Image(systemName: "list.bullet").help("Processes: one row per process").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Groups (accounting groups, from the kernel's resource coalitions) or single processes")
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
        let pins = Pins.shared
        let list = monitor.procs.filter { filter.matches($0, me: me) }
            .sorted { (metric.value($0) ?? -1, $1.pid) > (metric.value($1) ?? -1, $0.pid) }
        guard !pins.isEmpty else { return list }
        // Pinned processes first, in the order they were pinned (a stable sort keeps the rest as they were).
        return list.map { (pins.rank(Pins.process($0)), $0) }.enumerated()
            .sorted { ($0.element.0 ?? .max, $0.offset) < ($1.element.0 ?? .max, $1.offset) }.map(\.element.1)
    }

    private var shownGroups: [AmbientGroup] {
        let me = getuid()
        let pins = Pins.shared
        let list = monitor.groups.filter { filter.matches($0.leader, me: me) }
            .sorted { (metric.value($0.sums) ?? -1, $1.leader.pid) > (metric.value($1.sums) ?? -1, $0.leader.pid) }
        guard !pins.isEmpty else { return list }
        // Pinned groups, and groups holding a pinned process, first, in the order they were pinned.
        func rank(_ g: AmbientGroup) -> Int? {
            ([pins.rank(Pins.group(leader: g.leader))] + g.members.map { pins.rank(Pins.process($0)) }).compactMap { $0 }.min()
        }
        return list.map { (rank($0), $0) }.enumerated()
            .sorted { ($0.element.0 ?? .max, $0.offset) < ($1.element.0 ?? .max, $1.offset) }.map(\.element.1)
    }

    /// A member's place inside an expanded group: pinned ones first, in pin order, then by the metric.
    private func memberOrder(_ x: (Int?, Double), _ y: (Int?, Double)) -> Bool {
        x.0 != y.0 ? (x.0 ?? .max) < (y.0 ?? .max) : x.1 > y.1
    }

    @ViewBuilder
    private var processList: some View {
        if grouped { groupList } else {
            let list = shown
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(list.prefix(150).enumerated()), id: \.element.id) { i, p in
                        PopoverRow(subject: .proc(p), metric: metric, history: monitor.procHistory[p.key]?.values(metric) ?? [],
                                   secondary: secondary, inline: inline, striped: i % 2 == 1)
                    }
                    if list.isEmpty {
                        Text(monitor.procs.isEmpty ? "Reading…" : "No processes").foregroundStyle(.secondary).padding(.top, 40)
                    }
                }
            }
        }
    }

    /// One line of the grouped list.
    private struct Line: Identifiable {
        var id: String
        var subject: PopoverRow.Subject
        var depth: Int
        var history: [Double]
        /// nil: nothing to expand.
        var open: Bool?
    }

    private func lines(_ groups: [AmbientGroup]) -> [Line] {
        let v: (AmbientProc) -> Double = { metric.value($0) ?? -1 }
        var out: [Line] = []
        for g in groups.prefix(150) {
            let gid = "g\(g.id)"
            let open = expanded.contains(gid)
            out.append(Line(id: gid, subject: g.single ? .proc(g.leader) : .group(g), depth: 0,
                            history: monitor.groupHistory[g.id]?.values(metric) ?? [], open: g.single ? nil : open))
            guard open, !g.single else { continue }
            // The leader first, then sub-groups and the other members by the metric.
            enum Child { case sub(AmbientSubgroup), proc(AmbientProc) }
            let pins = Pins.shared
            let pin: (AmbientProc) -> Int? = { pins.rank(Pins.process($0)) }
            var kids: [((Int?, Double), Child)] = g.plain.dropFirst().map { ((pin($0), v($0)), .proc($0)) }
            kids += g.subgroups.map { (($0.members.compactMap(pin).min(), metric.value($0.sums) ?? -1), .sub($0)) }
            kids.sort { memberOrder($0.0, $1.0) }
            out.append(procLine(g.leader, depth: 1))
            for (_, k) in kids {
                switch k {
                case .proc(let p): out.append(procLine(p, depth: 1))
                case .sub(let sg):
                    let sid = "\(gid)/\(sg.id)"
                    let sopen = expanded.contains(sid)
                    out.append(Line(id: sid, subject: .sub(sg), depth: 1, history: summed(sg.members), open: sopen))
                    if sopen { out += sg.members.sorted { memberOrder((pin($0), v($0)), (pin($1), v($1))) }.map { procLine($0, depth: 2) } }
                }
            }
        }
        return out
    }

    private func procLine(_ p: AmbientProc, depth: Int) -> Line {
        Line(id: "p\(p.pid).\(p.start.timeIntervalSince1970)", subject: .proc(p), depth: depth,
             history: monitor.procHistory[p.key]?.values(metric) ?? [], open: nil)
    }

    /// A sub-group's graph: its members' readings added up, aligned on the newest.
    private func summed(_ ms: [AmbientProc]) -> [Double] {
        var out: [Double] = []
        for m in ms {
            let h = monitor.procHistory[m.key]?.values(metric) ?? []
            if h.count > out.count { out.insert(contentsOf: repeatElement(0, count: h.count - out.count), at: 0) }
            let off = out.count - h.count
            for (i, x) in h.enumerated() { out[off + i] += x }
        }
        return out
    }

    private var groupList: some View {
        let list = lines(shownGroups)
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, l in
                    PopoverRow(subject: l.subject, metric: metric, history: l.history, secondary: secondary, inline: inline,
                               striped: i % 2 == 1, depth: l.depth, open: l.open, chevronRoom: true) {
                        if expanded.contains(l.id) { expanded.remove(l.id) } else { expanded.insert(l.id) }
                    }
                }
                if list.isEmpty {
                    Text(monitor.procs.isEmpty ? "Reading…" : "No processes").foregroundStyle(.secondary).padding(.top, 40)
                }
            }
        }
    }

    // MARK: Triage

    private var triageBody: some View {
        let top = monitor.topGroups[metric] ?? []
        let peak = top.compactMap { metric.value($0.sums) }.max() ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Top consumers · \(metric.title)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                if top.isEmpty { Text("No readings yet").font(.caption).foregroundStyle(.secondary) }
                ForEach(top) { g in TopGroupRow(group: g, metric: metric, peak: peak) }
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

    private func peakOverHistory(_ list: [AmbientGroup]) -> (name: String, value: Double)? {
        var best: (String, Double)?
        for g in list {
            if let v = monitor.groupHistory[g.id]?.values(metric).max(), v > (best?.1 ?? 0) { best = (g.name, v) }
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
            let n = grouped && !triage ? shownGroups.count : shown.count
            Text(verbatim: "\(min(n, 150)) / \(monitor.procs.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .help((grouped && !triage ? "Groups shown / processes running" : "Processes shown / running")
                      + (n > 150 ? " (the list shows the first 150 of \(n))" : ""))
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

/// One row of the dropdown: a process, an accounting group, or a sub-group inside one. Icon, name, inline value,
/// optional second line, its graph, its value. A click shows the process (a group's leader) in the main window's
/// process list; the context menu has the rest. Groups and sub-groups have a disclosure chevron.
struct PopoverRow: View {
    enum Subject {
        case proc(AmbientProc), group(AmbientGroup), sub(AmbientSubgroup)
    }
    let subject: Subject
    let metric: AmbientMetric
    let history: [Double]
    let secondary: RowField
    let inline: RowField
    let striped: Bool
    var depth = 0
    /// Expanded or not; nil when there's nothing to expand.
    var open: Bool? = nil
    /// In the grouped list every row keeps the chevron's room, so icons line up; the flat list has none.
    var chevronRoom = false
    var toggle: () -> Void = {}
    @Environment(\.openWindow) private var openWindow
    @State private var hover = false

    /// The process the row's click and menu act on.
    private var target: AmbientProc? {
        switch subject {
        case .proc(let p): p
        case .group(let g): g.leader
        case .sub(let s): s.lead
        }
    }
    private var title: String {
        switch subject {
        case .proc(let p): p.name
        case .group(let g): g.name
        case .sub(let s): s.title
        }
    }
    private var sums: AmbientSums? {
        switch subject {
        case .proc: nil
        case .group(let g): g.sums
        case .sub(let s): s.sums
        }
    }
    private var value: String {
        if let s = sums {
            guard let v = metric.value(s) else { return "–" }
            return s.prefix(metric) + metric.format(v)
        }
        return target.flatMap { metric.value($0) }.map(metric.format) ?? "–"
    }
    private var inlineText: String? {
        switch subject {
        case .proc(let p): inline.text(p)
        case .group(let g): "\(g.count) processes"
        case .sub(let s):
            switch s.id {
            case .name: nil   // the title already says ×N
            // Several sub-groups can share a name (four `claude` sessions): the pid tells them apart.
            case .responsible(let pid): "\(pid) · \(s.members.count) processes"
            case .terminal, .xpc: "\(s.members.count) processes"
            }
        }
    }
    private var secondText: String? {
        switch subject {
        case .proc(let p): secondary.text(p)
        case .group(let g): secondary == .path ? g.leader.path : nil
        case .sub: nil
        }
    }
    private var notResponding: Bool {
        switch subject {
        case .proc(let p): p.notResponding
        case .group(let g): g.leader.notResponding
        case .sub: false
        }
    }
    private var helpText: String {
        switch subject {
        case .proc(let p):
            return "\(p.path ?? p.name)\nClick to show it in the process list."
        case .group(let g):
            return "Accounting group (resource coalition) of \(g.count) processes, named after \(g.name) (pid \(g.leader.pid)), the one the others are run for."
                + (g.sums.coverageNote.map { "\n\($0): the others belong to another user and the helper isn't running." } ?? "")
                + "\nClick to show \(g.name) in the process list; the chevron lists its members."
        case .sub(let s):
            let why: String
            switch s.id {
            case .responsible: why = "Processes \(s.title) is responsible for (macOS's responsible process)."
            case .terminal: why = "Processes in one terminal session (controlling terminal)."
            case .xpc: why = "XPC services (from .xpc bundles) running for this group."
            case .name: why = "Processes with the same name."
            }
            return why + (s.sums.coverageNote.map { "\n\($0)." } ?? "") + (s.lead != nil ? "\nClick to show \(s.title) in the process list." : "\nClick to list them.")
        }
    }
    private var iconPath: String? {
        switch subject {
        case .proc(let p): p.path
        case .group(let g): g.leader.path
        case .sub(let s):
            switch s.id {
            case .responsible, .name: s.lead?.path ?? s.members.first?.path
            case .terminal, .xpc: nil
            }
        }
    }
    /// What pinning this row pins: a process, or an accounting group (by its leader, as the main window pins
    /// an app's row). Sub-groups don't pin.
    private var pinKey: String? {
        switch subject {
        case .proc(let p): Pins.process(p)
        case .group(let g): Pins.group(leader: g.leader)
        case .sub: nil
        }
    }

    private var fallbackSymbol: String {
        if case .sub(let s) = subject, case .xpc = s.id { return "shippingbox" }
        return "terminal"
    }

    var body: some View {
        HStack(spacing: 7) {
            if chevronRoom || open != nil {
                Group {
                if let open {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 12, height: 16).contentShape(Rectangle())
                        .onTapGesture(perform: toggle)
                        .help(open ? "Hide the members" : "Show the members")
                } else {
                    Color.clear.frame(width: 12, height: 16)
                }
            }
            .padding(.leading, CGFloat(depth) * 14)
            }
            if let i = PathIcon.icon(iconPath) { Image(nsImage: i).resizable().frame(width: 16, height: 16) }
            else { Image(systemName: fallbackSymbol).font(.system(size: 11)).frame(width: 16, height: 16).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    if Pins.shared.isPinned(pinKey) {
                        Image(systemName: "pin.fill").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.accentColor)
                            .help("Pinned to the top")
                    }
                    Text(verbatim: title).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(notResponding ? Color.red : .primary)
                    if let t = inlineText {
                        Text(verbatim: t).font(.caption2).foregroundStyle(.tertiary).monospacedDigit().lineLimit(1)
                    }
                    if notResponding {
                        Text("NOT RESPONDING").font(.system(size: 8, weight: .bold)).foregroundStyle(.red)
                            .padding(.horizontal, 3).background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 2))
                    }
                }
                if let t = secondText {
                    Text(verbatim: t).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            MiniGraph(values: history, maxValue: metric == .cpu || metric == .gpu ? max(100, history.max() ?? 0) : nil,
                      color: .accentColor, capacity: ProcHistory.length)
                .frame(width: 56, height: 16)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 3))
            Text(verbatim: value)
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 66, alignment: .trailing).lineLimit(1)
        }
        .font(.system(size: 12))
        .padding(.leading, chevronRoom ? 4 : 10).padding(.trailing, 10).frame(minHeight: 26)
        .background(hover ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : striped ? AnyShapeStyle(.quaternary.opacity(0.3)) : AnyShapeStyle(.clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            if let p = target { AppRouter.openMain(openWindow); AppRouter.shared.show(p.pid) } else { toggle() }
        }
        .help(helpText)
        .contextMenu {
            if let p = target {
                Button("Show in Process List") { AppRouter.openMain(openWindow); AppRouter.shared.show(p.pid) }
                Button("Inspect") { AppRouter.inspect(p.ref, openWindow) }
                if let path = p.path {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
                Button("Copy PID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("\(p.pid)", forType: .string) }
            }
            if let k = pinKey {
                if target != nil { Divider() }
                Button(Pins.shared.isPinned(k) ? "Unpin" : "Pin to Top") { Pins.shared.toggle(k) }
            }
            if let open {
                if target != nil { Divider() }
                Button(open ? "Hide Members" : "Show Members", action: toggle)
            }
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

/// Reports whether the window holding it is on screen: true as it becomes key (a MenuBarExtra window does as it
/// opens, before it's drawn), and checked again as it resigns key, closes or changes occlusion. MenuBarExtra orders
/// its window out with no notification of its own, so AmbientMonitor also checks the window on every tick.
struct WindowVisibility: NSViewRepresentable {
    let changed: (NSWindow?, Bool) -> Void

    func makeNSView(context: Context) -> Watcher { Watcher(changed) }
    func updateNSView(_ v: Watcher, context: Context) { v.changed = changed }

    final class Watcher: NSView {
        var changed: (NSWindow?, Bool) -> Void
        private var observers: [NSObjectProtocol] = []
        init(_ changed: @escaping (NSWindow?, Bool) -> Void) { self.changed = changed; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let w = window else { changed(nil, false); return }
            let nc = NotificationCenter.default
            observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.changed(w, true) }
            })
            for name in [NSWindow.didResignKeyNotification, NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
                observers.append(nc.addObserver(forName: name, object: w, queue: .main) { [weak self] n in
                    let closing = n.name == NSWindow.willCloseNotification
                    // After the run loop turn that orders the window out.
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.report(closing: closing) } }
                })
            }
            report(closing: false)
        }

        private func report(closing: Bool) {
            guard let w = window else { return }
            changed(w, !closing && w.isVisible && (w.occlusionState.contains(.visible) || w.isKeyWindow))
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
