import SwiftUI

/// The All Counters browser's state: the catalog, the latest readings, and which groups to read. While a view
/// shows it, it reads the groups on screen and the pinned counters' groups once a second; a "what changes" pass
/// (two full readings) runs when it opens and on request.
@Observable @MainActor
final class CounterBrowser {
    static let shared = CounterBrowser()
    static let historyLength = 120
    static let pinnedID = "pinned"

    private(set) var groups: [CounterGroup] = []
    private(set) var counters: [String: CounterInfo] = [:]
    private(set) var groupByID: [String: CounterGroup] = [:]
    private(set) var loading = false
    /// Counters that changed during the last "what changes" pass; nil before it has run.
    private(set) var changing: Set<String>?
    private(set) var discovering = false
    private(set) var latest: [String: CounterValue] = [:]
    private(set) var previous: [String: CounterValue] = [:]
    /// Change per second between the last two readings.
    private(set) var rates: [String: Double] = [:]
    /// Value and rate series for counters on screen or pinned, oldest first.
    private(set) var valueHistory: [String: [Double]] = [:]
    private(set) var rateHistory: [String: [Double]] = [:]
    private(set) var lastReadMillis: Double?
    private(set) var pinned: [String] = UserDefaults.standard.stringArray(forKey: "counters.pinned") ?? []

    var selectedGroup: String = UserDefaults.standard.string(forKey: "counters.group") ?? "" {
        didSet { UserDefaults.standard.set(selectedGroup, forKey: "counters.group"); tick() }
    }
    var search = "" { didSet { if search != oldValue { tick() } } }
    var changingOnly = UserDefaults.standard.object(forKey: "counters.changingOnly") as? Bool ?? true {
        didSet { UserDefaults.standard.set(changingOnly, forKey: "counters.changingOnly") }
    }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var readAt: [String: UInt64] = [:]

    // MARK: What's on screen

    /// The table's counters: search results across every group, the pinned ones, or the selected group's.
    var visible: [CounterInfo] {
        let list: [CounterInfo]
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            list = groups.lazy.flatMap { g in
                g.counters.lazy.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.sub.localizedCaseInsensitiveContains(q)
                    || g.name.localizedCaseInsensitiveContains(q) }
            }
            .prefix(1000).map { $0 }
        } else if selectedGroup == Self.pinnedID {
            return pinned.compactMap { counters[$0] }
        } else {
            list = groupByID[selectedGroup]?.counters ?? []
        }
        guard changingOnly, let changing else { return list }
        return list.filter { changing.contains($0.id) }
    }

    func isChanging(_ id: String) -> Bool { changing?.contains(id) ?? true }

    func changingCount(_ g: CounterGroup) -> Int? {
        changing.map { c in g.counters.reduce(0) { $0 + (c.contains($1.id) ? 1 : 0) } }
    }

    private var watchedGroups: Set<String> {
        Set(visible.prefix(1000).map(\.group)).union(pinned.compactMap { counters[$0]?.group })
    }

    // MARK: Pins

    func isPinned(_ id: String) -> Bool { pinned.contains(id) }

    /// The counter the browser should select next time it shows (set by "Show in All Counters").
    var pendingSelection: String?

    /// Opens the browser on one counter: its group, with it selected, from anywhere in the app.
    func reveal(_ id: String) {
        guard let gid = CounterEngine.groupID(of: id) else { return }
        search = ""
        selectedGroup = gid
        if let changing, !changing.contains(id) { changingOnly = false }
        pendingSelection = id
        UserDefaults.standard.set(Section.counters.rawValue, forKey: "section")
    }

    func togglePin(_ id: String) {
        if let i = pinned.firstIndex(of: id) { pinned.remove(at: i) } else { pinned.append(id) }
        UserDefaults.standard.set(pinned, forKey: "counters.pinned")
    }

    // MARK: Life cycle

    func addViewer() {
        viewers += 1
        if groups.isEmpty && !loading { load() }
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func removeViewer() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    private func load() {
        loading = true
        let engine = CounterEngine.shared
        engine.queue.async { [weak self] in
            let g = engine.catalog()
            Task { @MainActor [weak self] in
                guard let self else { return }
                groups = g
                groupByID = Dictionary(g.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                counters = Dictionary(g.flatMap { $0.counters.map { ($0.id, $0) } }, uniquingKeysWith: { a, _ in a })
                if groupByID[selectedGroup] == nil && selectedGroup != Self.pinnedID { selectedGroup = g.first?.id ?? "" }
                loading = false
                discover()
            }
        }
    }

    /// Reads everything twice, 1.5 s apart, and keeps what changed.
    func discover() {
        guard !discovering, !groups.isEmpty else { return }
        discovering = true
        let engine = CounterEngine.shared
        engine.queue.async { [weak self] in
            let a = engine.read(nil)
            Thread.sleep(forTimeInterval: 1.5)
            let b = engine.read(nil)
            let changed = CounterEngine.changed(a, b)
            Task { @MainActor [weak self] in
                guard let self else { return }
                apply(a, millis: nil)
                apply(b, millis: nil)
                changing = changed
                discovering = false
            }
        }
    }

    func tick() {
        guard viewers > 0, !reading, !discovering, !groups.isEmpty else { return }
        let want = watchedGroups
        guard !want.isEmpty else { return }
        reading = true
        let engine = CounterEngine.shared
        engine.queue.async { [weak self] in
            let t = DispatchTime.now().uptimeNanoseconds
            let r = engine.read(want)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
            Task { @MainActor [weak self] in
                self?.apply(r, millis: ms)
                self?.reading = false
            }
        }
    }

    private func apply(_ r: CounterReading, millis: Double?) {
        if let millis { lastReadMillis = millis }
        let keep = Set(visible.prefix(1000).map(\.id)).union(pinned)
        for (id, v) in r.values {
            let old = latest[id]
            if let old, let at = readAt[id], r.at > at {
                previous[id] = old
                if let d = v.delta(from: old) { rates[id] = d / (Double(r.at - at) / 1e9) } else { rates[id] = nil }
            }
            latest[id] = v
            readAt[id] = r.at
            guard keep.contains(id) else { continue }
            if let x = v.number {
                push(&valueHistory, id, x)
                if let rate = rates[id] { push(&rateHistory, id, rate) }
            }
        }
        // Drop the series of counters no longer on screen.
        if valueHistory.count > keep.count * 2 + 50 {
            valueHistory = valueHistory.filter { keep.contains($0.key) }
            rateHistory = rateHistory.filter { keep.contains($0.key) }
        }
    }

    private func push(_ h: inout [String: [Double]], _ id: String, _ v: Double) {
        var a = h[id] ?? []
        a.append(v)
        if a.count > Self.historyLength { a.removeFirst(a.count - Self.historyLength) }
        h[id] = a
    }
}

// MARK: Views

/// System ▸ All Counters: every counter the four sources expose.
struct SystemCountersView: View {
    @State private var b = CounterBrowser.shared
    @State private var selection: String?
    @State private var sort = [KeyPathComparator(\CounterRow.order)]

    var body: some View {
        @Bindable var b = b
        // The list, the status line and the table are views of their own: the once-a-second readings then
        // update the table and status only, instead of re-diffing the whole group list with them.
        HSplitView {
            CounterGroupList().frame(minWidth: 220, idealWidth: 280, maxWidth: 420)
            SplitPane(id: "counters", defaultFraction: 0.6, showsBottom: selection.flatMap { b.counters[$0] } != nil) {
                CounterTable(selection: $selection, sort: $sort)
            } bottom: {
                if let id = selection, let c = b.counters[id] {
                    CounterDetail(info: c).id(id)
                }
            }
            .frame(minWidth: 420)
        }
        .navigationTitle("System Counters")
        .searchable(text: $b.search, placement: .toolbar, prompt: "Search every counter")
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $b.changingOnly) { Label("Changing Only", systemImage: "waveform.path.ecg") }
                    .help("Show only counters whose value changed during the last check (most sysctl nodes are settings that never change)")
                Button { b.discover() } label: { Label("Check Again", systemImage: "arrow.clockwise") }
                    .disabled(b.discovering || b.loading)
                    .help("Read every counter twice, 1.5 s apart, to find which ones change now")
                Button { exportSnapshot() } label: { Label("Export Snapshot…", systemImage: "square.and.arrow.up") }
                    .disabled(b.loading)
                    .help("Read every counter now and save them all as JSON, for comparing two moments or two Macs (ProcXRay --counters --json does the same)")
            }
        }
        .onAppear { b.addViewer(); takePending() }
        .onDisappear { b.removeViewer() }
        .onChange(of: b.pendingSelection) { _, _ in takePending() }
    }

    private func exportSnapshot() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        panel.nameFieldStringValue = "Counters \(f.string(from: Date())).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let engine = CounterEngine.shared
        engine.queue.async {
            let data = CounterEngine.snapshot(engine.catalog(), engine.read(nil))
            try? data.write(to: url, options: .atomic)
        }
    }

    private func takePending() {
        guard let id = b.pendingSelection else { return }
        selection = id
        b.pendingSelection = nil
    }
}

/// System ▸ All Counters' group list.
private struct CounterGroupList: View {
    @State private var b = CounterBrowser.shared

    var body: some View {
        ScrollViewReader { proxy in groupListBody(proxy) }
    }

    private func groupListBody(_ proxy: ScrollViewProxy) -> some View {
        @Bindable var b = b
        return List(selection: $b.selectedGroup) {
            if !b.pinned.isEmpty {
                Label("Pinned", systemImage: "pin").badge(b.pinned.count).tag(CounterBrowser.pinnedID)
            }
            ForEach(CounterSourceKind.allCases, id: \.self) { s in
                let list = b.groups.filter { $0.source == s && (!b.changingOnly || (b.changingCount($0) ?? 1) > 0) }
                if !list.isEmpty {
                    SwiftUI.Section {
                        ForEach(list) { g in
                            HStack {
                                Text(g.name).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(verbatim: countText(g)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .help(g.note)
                            .tag(g.id)
                        }
                    } header: {
                        Text(s.title).help(s.help)
                    }
                }
            }
        }
        .overlay {
            if b.loading { ProgressView("Listing counters…") }
        }
        // The remembered group may be far down the list: show it once the catalog is in, and again once the
        // "what changes" check has trimmed the list.
        .onChange(of: [b.groups.isEmpty, b.changing == nil], initial: true) { _, _ in
            if !b.groups.isEmpty { DispatchQueue.main.async { proxy.scrollTo(b.selectedGroup, anchor: .center) } }
        }
        .safeAreaInset(edge: .bottom) { CounterStatus().padding(8).frame(maxWidth: .infinity, alignment: .leading) }
    }

    private func countText(_ g: CounterGroup) -> String {
        guard let n = b.changingCount(g) else { return "\(g.counters.count)" }
        return b.changingOnly ? "\(n)" : "\(n)/\(g.counters.count)"
    }
}

/// The status line under the group list: totals and the last reading's time, which changes every second.
private struct CounterStatus: View {
    @State private var b = CounterBrowser.shared

    var body: some View {
        let total = b.counters.count
        var parts = ["\(total.formatted()) counters"]
        if let c = b.changing { parts.append("\(c.count.formatted()) changing") }
        if let ms = b.lastReadMillis { parts.append(String(format: "read in %.1f ms", ms)) }
        return HStack(spacing: 6) {
            if b.discovering { ProgressView().controlSize(.small) }
            Text(b.discovering ? "Checking which counters change…" : parts.joined(separator: " · "))
        }
        .font(.caption).foregroundStyle(.secondary)
        .help("The groups on screen and the pinned counters are read once a second; \"read in\" is the last reading's time")
    }
}

/// System ▸ All Counters' table of the selected group's counters.
private struct CounterTable: View {
    @State private var b = CounterBrowser.shared
    @Binding var selection: String?
    @Binding var sort: [KeyPathComparator<CounterRow>]

    var body: some View { table(rows) }

    private var rows: [CounterRow] {
        let searching = !b.search.trimmingCharacters(in: .whitespaces).isEmpty || b.selectedGroup == CounterBrowser.pinnedID
        return b.visible.enumerated().map { i, c in
            let rate = b.rates[c.id]
            var sub = c.sub
            if searching, let g = b.groupByID[c.group] { sub = [g.name, c.sub].filter { !$0.isEmpty }.joined(separator: " · ") }
            return CounterRow(id: c.id, order: i, name: c.name, sub: sub,
                              value: CounterText.value(b.latest[c.id], unit: c.unit),
                              rate: rate.map { $0 == 0 ? "" : CounterText.rate($0, unit: c.unit) } ?? "",
                              rateSort: abs(rate ?? 0), pinned: b.isPinned(c.id))
        }
        .sorted(using: sort)
    }

    private func table(_ rows: [CounterRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sort) {
            TableColumn("Counter", value: \.order) { r in
                HStack(spacing: 4) {
                    if r.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                    Text(r.name).truncationHelp(r.name)
                    if !r.sub.isEmpty { Text(r.sub).foregroundStyle(.secondary).lineLimit(1).truncationHelp(r.sub) }
                }
            }
            .width(min: 180, ideal: 340)
            TableColumn("Value") { r in Text(r.value).monospacedDigit().truncationHelp(r.value) }
                .width(min: 90, ideal: 200)
            TableColumn("Change /s", value: \.rateSort) { r in Text(r.rate).monospacedDigit() }
                .width(min: 70, ideal: 100)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first {
                Button(b.isPinned(id) ? "Unpin" : "Pin") { b.togglePin(id) }
                Button("Copy Value") { copy(CounterText.value(b.latest[id], unit: b.counters[id]?.unit ?? "")) }
                Button("Copy ID") { copy(id) }
            }
        }
        .overlay {
            if !b.loading && rows.isEmpty {
                Text(b.discovering ? "Checking which counters change…" : b.changingOnly ? "No counter here changed during the last check" : "No counters")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}


struct CounterRow: Identifiable {
    var id: String
    var order: Int
    var name: String
    var sub: String
    var value: String
    var rate: String
    var rateSort: Double
    var pinned: Bool
}

/// The selected counter: where it comes from, its value, a graph, and its states or buckets.
private struct CounterDetail: View {
    let info: CounterInfo
    @State private var b = CounterBrowser.shared
    @State private var graphRate: Bool?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    row("Value", CounterText.value(b.latest[info.id], unit: info.unit))
                    if let r = b.rates[info.id] { row("Change per second", CounterText.rate(r, unit: info.unit)) }
                    if !info.unit.isEmpty { row("Unit", info.unit) }
                    if let g = b.groupByID[info.group] { row("Source", g.note) }
                    if !b.isChanging(info.id) { row("", "Didn't change during the last check") }
                }
                .font(.callout)
                graph
                switch b.latest[info.id] {
                case .states(let s)?: states(s)
                case .histogram(let h)?: buckets(h)
                default: EmptyView()
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                Text([b.groupByID[info.group]?.name ?? "", info.sub].filter { !$0.isEmpty }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                Text(info.id).font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
            }
            Spacer()
            Button { b.togglePin(info.id) } label: {
                Label(b.isPinned(info.id) ? "Unpin" : "Pin", systemImage: b.isPinned(info.id) ? "pin.slash" : "pin")
            }
            .help("Pinned counters are listed under Pinned and keep their history while the browser is open")
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Graph

    @ViewBuilder private var graph: some View {
        let values = b.valueHistory[info.id] ?? []
        let rates = b.rateHistory[info.id] ?? []
        if values.count > 1 {
            // A counter that only ever grew reads best as its rate; anything else as its value.
            let rising = zip(values, values.dropFirst()).allSatisfy { $0 <= $1 } && rates.contains { $0 != 0 }
            let showRate = graphRate ?? rising
            let series = showRate ? rates : values
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Picker("", selection: Binding(get: { showRate }, set: { graphRate = $0 })) {
                        Text("Value").tag(false)
                        Text("Change per second").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                    if let lo = series.min(), let hi = series.max() {
                        Text("\(label(lo, rate: showRate)) – \(label(hi, rate: showRate))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                MiniGraph(values: offset(series), maxValue: nil, capacity: CounterBrowser.historyLength)
                    .frame(height: 90)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
                Text("Last \(series.count) s").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func label(_ v: Double, rate: Bool) -> String {
        rate ? CounterText.rate(v, unit: info.unit) : CounterText.value(.double(v), unit: info.unit)
    }

    /// Values that sit far from zero (a page count around 200,000) would draw as a flat line at the top: graph
    /// them from their minimum when they don't cross zero.
    private func offset(_ s: [Double]) -> [Double] {
        guard let lo = s.min(), let hi = s.max() else { return s }
        if lo >= 0 && lo > (hi - lo) * 4 { return s.map { $0 - lo + (hi - lo) * 0.05 } }
        if lo < 0 { return s.map { $0 - lo } }
        return s
    }

    // MARK: States and buckets

    private func states(_ s: [CounterState]) -> some View {
        let total = Double(s.reduce(Int64(0)) { $0 &+ max(0, $1.residency) })
        var recent: [String: Double] = [:]
        if case .states(let p)? = b.previous[info.id], p.count == s.count {
            let d = zip(p, s).map { max(0, $1.residency &- $0.residency) }
            let sum = Double(d.reduce(0, +))
            if sum > 0 { for (st, x) in zip(s, d) { recent[st.name] = Double(x) / sum } }
        }
        return VStack(alignment: .leading, spacing: 3) {
            Text("Time in each state").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                GridRow {
                    Text("State"); Text("Last second"); Text("Since boot")
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(s.enumerated()), id: \.offset) { _, st in
                    GridRow {
                        Text(st.name.trimmingCharacters(in: .whitespaces)).monospaced()
                        bar(recent[st.name] ?? 0)
                        bar(total > 0 ? Double(max(0, st.residency)) / total : 0)
                    }
                }
            }
            .font(.callout)
        }
    }

    private func bar(_ f: Double, percent: Bool = true) -> some View {
        HStack(spacing: 4) {
            GeometryReader { g in
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.7))
                    .frame(width: max(f > 0 ? 1 : 0, g.size.width * f))
            }
            .frame(width: 90, height: 8)
            if percent { Text(String(format: "%.1f %%", f * 100)).monospacedDigit().frame(width: 52, alignment: .trailing) }
        }
    }

    private func buckets(_ h: [CounterBucket]) -> some View {
        let peak = Double(h.map(\.hits).max() ?? 1)
        return VStack(alignment: .leading, spacing: 3) {
            Text("Buckets").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                ForEach(Array(h.enumerated()), id: \.offset) { _, x in
                    GridRow {
                        Text("\(x.min.formatted()) – \(x.max.formatted())").monospacedDigit()
                        bar(peak > 0 ? Double(x.hits) / peak : 0, percent: false)
                        Text(x.hits.formatted()).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)
        }
    }
}
