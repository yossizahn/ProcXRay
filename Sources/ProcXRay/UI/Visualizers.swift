import SwiftUI

// Visual renderings of the parsed tool outputs (see Sys/Parsers.swift). Every pane keeps a
// Visual / Raw switch; the choice is shared app-wide through @AppStorage.

// MARK: - Shared bits

struct RawToggle: View {
    @Binding var showRaw: Bool
    var body: some View {
        Picker("", selection: $showRaw) {
            Label("Visual", systemImage: "chart.bar.doc.horizontal").tag(false)
            Label("Raw", systemImage: "text.alignleft").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Switch between the parsed view and the tool's raw text output")
    }
}

/// Header bar + Visual/Raw switch for panes whose text is already in hand.
struct OutputPane<Visual: View>: View {
    let raw: String
    var filterable = false
    let visual: (String) -> Visual
    @AppStorage("showRawOutput") private var showRaw = false
    @State private var filter = ""

    init(raw: String, filterable: Bool = false, @ViewBuilder visual: @escaping (String) -> Visual) {
        self.raw = raw; self.filterable = filterable; self.visual = visual
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                RawToggle(showRaw: $showRaw)
                Spacer()
                if filterable || showRaw {
                    TextField("filter", text: $filter).textFieldStyle(.roundedBorder).frame(width: 180)
                }
            }
            .padding(6)
            Divider()
            if showRaw {
                MonoText(text: filterLines(raw, filter))
            } else {
                visual(filter)
            }
        }
    }
}

func filterLines(_ s: String, _ f: String) -> String {
    f.isEmpty ? s : s.split(separator: "\n").filter { $0.localizedCaseInsensitiveContains(f) }.joined(separator: "\n")
}

struct Pill: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
            .lineLimit(1)
            .fixedSize()
    }
}

/// Inline horizontal bar, `fraction` of a fixed track.
struct MiniBar: View {
    let fraction: Double
    var color: Color = .accentColor
    var width: CGFloat = 70
    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.12))
            Capsule().fill(color.gradient)
                .frame(width: max(fraction > 0 ? 2 : 0, width * min(max(fraction, 0), 1)))
        }
        .frame(width: width, height: 6)
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var sub: String? = nil
    var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: value).font(.system(size: 18, weight: .semibold, design: .rounded)).foregroundStyle(color)
                .monospacedDigit()
            if let sub { Text(verbatim: sub).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(minWidth: 96, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Selectable key/value grid (no scroll view of its own).
struct KVGrid: View {
    let rows: [(String, String)]
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                GridRow {
                    Text(r.0).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    ValueView(key: r.0, value: r.1)
                }
            }
        }
    }
}

/// Renders a launchd / LaunchServices value with a little semantics: states as coloured badges,
/// `a | b | c` flag lists as pills, everything else as selectable monospaced text.
struct ValueView: View {
    let key: String
    let value: String
    var body: some View {
        let k = key.lowercased()
        if k == "state" || k == "job state" {
            Pill(text: value, color: value == "running" || value == "active" ? .green : (value.contains("not") ? .secondary : .orange))
        } else if k == "flag" {
            Pill(text: value, color: .orange)
        } else if value.contains(" | ") {
            FlowPills(items: value.components(separatedBy: " | "))
        } else if k.contains("exit"), value != "0", value != "(never exited)", value != "-" {
            Text(verbatim: value).foregroundStyle(.red).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        } else {
            Text(verbatim: value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
    }
}

struct FlowPills: View {
    let items: [String]
    var color: Color = .accentColor
    var body: some View {
        HStack(spacing: 4) { ForEach(items, id: \.self) { Pill(text: $0, color: color) } }
    }
}

struct Card<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    var trailing: String? = nil
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).foregroundStyle(.secondary) }
                Text(title).font(.headline)
                if let trailing { Text(verbatim: trailing).foregroundStyle(.secondary) }
                Spacer()
            }
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
    }
}

/// Shown in place of a visual view when the parser found nothing (error text, permission notes…).
struct UnparsedNote: View {
    let raw: String
    var body: some View {
        VStack(spacing: 0) {
            Label("Nothing to visualise — showing the tool's output.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(6)
            MonoText(text: raw)
        }
    }
}

private func stableHue(_ s: String) -> Double {
    var h: UInt32 = 5381
    for b in s.utf8 { h = (h &* 33) &+ UInt32(b) }
    return Double(h % 360) / 360
}

func libColor(_ lib: String?) -> Color {
    guard let lib else { return .secondary }
    return Color(hue: stableHue(lib), saturation: 0.55, brightness: 0.8)
}

// MARK: - lsof

extension LsofEntry.Kind: Identifiable {
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .image: .purple
        case .file: .blue
        case .dir: .cyan
        case .tcp: .green
        case .udp: .teal
        case .unix: .indigo
        case .pipe: .orange
        case .device: .gray
        case .kernel: .brown
        case .xpc: .pink
        case .mach: .mint
        case .iokit: .yellow
        case .sharedMemory: Color(hue: 0.8, saturation: 0.45, brightness: 0.8)
        case .taskPort: .red
        case .kobject: Color(white: 0.55)
        case .exception: Color(hue: 0.95, saturation: 0.55, brightness: 0.85)
        }
    }
}

extension LsofEntry {
    var fdSort: Int { Int(fd) ?? (fd == "cwd" ? -3 : fd == "txt" ? -2 : -1) }
    var kindName: String { kind.rawValue }
    var sizeSort: UInt64 { size ?? 0 }
}

/// What lsof's all-process run says about one descriptor's other end.
struct PeerInfo {
    enum Relation { case otherEnd, clients, alsoOpen }
    var relation: Relation
    var ends: [PeerIndex.End]
    /// There is an other end (a peer address, a local TCP endpoint) but no visible process holds it.
    var unresolved = false

    static func resolve(_ e: LsofEntry, pid: Int32, in ix: PeerIndex) -> PeerInfo? {
        switch e.kind {
        case .pipe, .unix:
            guard e.device.hasPrefix("0x") else { return nil }
            let peerAddress = e.name.hasPrefix("->0x") ? String(e.name.dropFirst(2)) : nil
            let ends = ix.peers(address: e.device, peerAddress: peerAddress, pid: pid, fd: e.fd)
            if ends.isEmpty { return peerAddress == nil ? nil : PeerInfo(relation: .otherEnd, ends: [], unresolved: true) }
            return PeerInfo(relation: .otherEnd, ends: ends)
        case .tcp:
            let p = e.endpoints
            if let r = p.remote {
                let ends = ix.tcpPeers(local: p.local, remote: r, pid: pid, fd: e.fd)
                if !ends.isEmpty { return PeerInfo(relation: .otherEnd, ends: ends) }
                // Only a peer on this machine could have been found, and only while the connection is up:
                // a CLOSED or CLOSE_WAIT socket's other end is usually gone already.
                guard p.state == nil || p.state == "ESTABLISHED",
                      let (h, _) = PeerIndex.split(r), ix.localHosts.contains(h) else { return nil }
                return PeerInfo(relation: .otherEnd, ends: [], unresolved: true)
            }
            guard p.state == "LISTEN" else { return nil }
            let ends = ix.tcpClients(listening: p.local)
            return ends.isEmpty ? nil : PeerInfo(relation: .clients, ends: ends)
        case .file, .dir:
            let pids = ix.alsoOpen(e.name, except: pid)
            return pids.isEmpty ? nil : PeerInfo(relation: .alsoOpen, ends: pids.map { .init(pid: $0, fd: "") })
        default:
            return nil
        }
    }

    /// Rows LsofView adds that aren't descriptors: their other end is a pid kept in `node`, if any.
    static let linkedKinds: Set<LsofEntry.Kind> = [.xpc, .mach, .iokit, .sharedMemory, .taskPort, .kobject, .exception]

    /// An XPC, Mach or kernel object row's other end; needs no lsof run.
    static func linked(_ e: LsofEntry) -> PeerInfo? {
        guard linkedKinds.contains(e.kind), let p = Int32(e.node) else { return nil }
        return PeerInfo(relation: .otherEnd, ends: [.init(pid: p, fd: "")])
    }

    /// Distinct pids, in the order found.
    var pids: [Int32] {
        var seen: Set<Int32> = []
        return ends.map(\.pid).filter { seen.insert($0).inserted }
    }
}

struct LsofView: View {
    @Environment(Store.self) private var store
    let entries: [LsofEntry]
    let filter: String
    let pid: Int32
    @State private var kinds: Set<LsofEntry.Kind> = []
    @State private var sort = [KeyPathComparator(\LsofEntry.fdSort)]
    @State private var index: PeerIndex?
    @State private var resolved: [Int: PeerInfo] = [:]
    @State private var loading = false
    @State private var locations: Set<String> = []
    @AppStorage("connections.view") private var view = "Table"
    @State private var mach: MachLoader.Result?
    @State private var machLoading = false

    var body: some View {
        let bundle = store.procs[pid]?.bundlePath
        let entries = self.entries.map { e -> LsofEntry in
            var e = e
            e.location = FileLocation.of(e, ownBundle: bundle)
            return e
        } + xpcEntries + machEntries + kernelEntries
        let resolved = peers(entries)
        let counts = Dictionary(grouping: entries, by: \.kind).mapValues(\.count)
        let locCounts = Dictionary(grouping: entries.filter { !$0.location.isEmpty }, by: \.location).mapValues(\.count)
        let rows = entries.filter {
            (kinds.isEmpty || kinds.contains($0.kind)) &&
            (locations.isEmpty || locations.contains($0.location)) &&
            (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.fd.contains(filter)
             || $0.type.localizedCaseInsensitiveContains(filter) || peerMatches($0, filter))
        }.sorted(using: sort)
        let listeners = entries.filter { $0.kind == .tcp && $0.endpoints.state == "LISTEN" }
        VStack(spacing: 0) {
            if !listeners.isEmpty { listening(listeners) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(LsofEntry.Kind.allCases.filter { counts[$0] != nil }) { k in
                        let on = kinds.contains(k)
                        Button {
                            if on { kinds.remove(k) } else { kinds.insert(k) }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: k.symbol)
                                Text(k.rawValue)
                                Text(verbatim: "\(counts[k] ?? 0)").bold().monospacedDigit()
                            }
                            .font(.system(size: 11))
                            .padding(.horizontal, 8).frame(height: 22)
                            .foregroundStyle(on ? .white : k.color)
                            .background(on ? AnyShapeStyle(k.color) : AnyShapeStyle(k.color.opacity(0.14)), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                    if !kinds.isEmpty { Button("Show all") { kinds = [] }.controlSize(.small) }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
            }
            .frame(height: 34)
            // Proportion strip: one segment per kind.
            GeometryReader { g in
                HStack(spacing: 1) {
                    ForEach(LsofEntry.Kind.allCases.filter { counts[$0] != nil }) { k in
                        Rectangle().fill(k.color.opacity(kinds.isEmpty || kinds.contains(k) ? 0.85 : 0.2))
                            .frame(width: max(2, g.size.width * Double(counts[k] ?? 0) / Double(max(entries.count, 1)) - 1))
                    }
                }
            }
            .frame(height: 4)
            .padding(.horizontal, 8).padding(.bottom, 4)
            if !locCounts.isEmpty { locationChips(locCounts) }
            peerStatus.padding(.horizontal, 8).padding(.bottom, 4)
            machStatus.padding(.horizontal, 8).padding(.bottom, 4)
            if view == "Graph" {
                PeerGraph(center: pid, entries: entries, resolved: resolved, mach: machSnapshot).environment(store)
            } else {
            Table(rows, sortOrder: $sort) {
                TableColumn("FD", value: \.fdSort) { e in
                    HStack(spacing: 4) {
                        Text(e.fd).monospacedDigit()
                        if !e.mode.isEmpty {
                            Pill(text: e.mode == "u" ? "rw" : e.mode, color: e.mode == "r" ? .blue : .orange)
                        }
                    }
                }.width(min: 66, ideal: 74, max: 100)
                TableColumn("Kind", value: \.kindName) { e in
                    Label(e.kind == .image ? "mapped" : e.type, systemImage: e.kind.symbol).foregroundStyle(e.kind.color)
                }.width(min: 96, ideal: 104, max: 140)
                TableColumn("Name", value: \.name) { e in NameCell(e: e) }
                TableColumn("Location", value: \.location) { e in
                    Text(e.location).foregroundStyle(.secondary).lineLimit(1)
                }.width(min: 70, ideal: 110, max: 180)
                TableColumn("Other end") { e in
                    if let info = resolved[e.id] {
                        // Re-injected: a Table cell can be rebuilt (on an accessibility press, for one) without
                        // the window's environment, and ProcessChip's @Environment(Store.self) then traps.
                        PeerCell(info: info, pid: pid, scope: index?.scope ?? .ownUser).environment(store)
                    }
                }.width(min: 90, ideal: 190)
                TableColumn("Size", value: \.sizeSort) { e in
                    Text(e.size.map { Fmt.bytes($0) } ?? "").monospacedDigit().foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }.width(min: 70, ideal: 80, max: 100)
            }
            }
        }
        // The view is rebuilt for every lsof run (CommandTab's generation), so Re-run resolves again too.
        .task { await loadIndex(fresh: false) }
        .task { await loadMach(fresh: false) }
    }

    /// XPC links from launchd pid domains, as rows beside the descriptors: the process hosting this one
    /// (an app for its XPC service, a host daemon for its extension), and the services this one hosts. Not
    /// from lsof, so they show without the all-process run. Negative ids keep them apart from lsof's rows.
    private var xpcEntries: [LsofEntry] {
        guard let me = store.procs[pid] else { return [] }
        func row(_ n: Int, type: String, name: String, peer: Int32) -> LsofEntry {
            LsofEntry(id: -1 - n, fd: "", mode: "", type: type, device: "", sizeOff: "", node: "\(peer)", name: name, kind: .xpc)
        }
        var out: [LsofEntry] = []
        if let o = me.domainOwner, o != pid, store.procs[o] != nil {
            out.append(row(0, type: "XPC host", name: me.launchdLabel ?? "runs in its pid domain", peer: o))
        }
        let hosted = store.procs.values.filter { $0.domainOwner == pid && $0.pid != pid }.sorted { $0.pid < $1.pid }
        for (i, p) in hosted.enumerated() {
            out.append(row(i + 1, type: SmartTree.isExtension(p) ? "XPC extension" : "XPC service",
                           name: p.launchdLabel ?? p.name, peer: p.pid))
        }
        return out
    }

    private var machSnapshot: MachSnapshot? {
        if case .snapshot(let s) = mach { s } else { nil }
    }

    /// One row per process this one shares Mach ports with (MachSnapshot.peers). Ids below the XPC rows'.
    private var machEntries: [LsofEntry] {
        guard let s = machSnapshot else { return [] }
        return s.peers(of: pid).enumerated().map { i, m in
            var m = m
            if m.sendsTo > 0, let p = store.procs[m.pid] { m.services = LaunchdServices.names(of: p) }
            return LsofEntry(id: -1_000_000 - i, fd: "", mode: "", type: m.direction, device: "", sizeOff: "",
                             node: "\(m.pid)", name: m.summary, kind: .mach)
        }
    }

    /// Kernel objects this process holds rights to, from the same snapshot: IOKit connections by user client
    /// class, memory entries shared with few other processes, task ports of other processes (and who holds
    /// this one's), and a count of everything else by type.
    private var kernelEntries: [LsofEntry] {
        guard let s = machSnapshot else { return [] }
        var out: [LsofEntry] = []
        func add(_ type: String, _ name: String, peer: Int32? = nil, _ kind: LsofEntry.Kind) {
            out.append(LsofEntry(id: -2_000_000 - out.count, fd: "", mode: "", type: type, device: "", sizeOff: "",
                                 node: peer.map { "\($0)" } ?? "", name: name, kind: kind))
        }
        func times(_ n: Int) -> String { n > 1 ? " ×\(n)" : "" }
        for (cls, n) in (s.iokit[pid] ?? [:]).sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }) {
            add("IOKit", cls + times(n), .iokit)
        }
        for m in s.sharedMemory(of: pid) {
            add("Memory", "\(m.entries) memory entr\(m.entries == 1 ? "y" : "ies")"
                + (m.bytes > 0 ? ", \(Fmt.bytes(m.bytes))" : "") + (m.holders > 2 ? " · held by \(m.holders) processes" : ""),
                peer: m.pid, .sharedMemory)
        }
        if let w = s.widelyShared[pid] {
            add("Memory", "\(w) memory entr\(w == 1 ? "y" : "ies") held by more than \(MachSnapshot.fewHolders) processes", .sharedMemory)
        }
        for t in s.taskRights where t.holder == pid { add("Task →", "its \(t.flavor) port", peer: t.target, .taskPort) }
        for t in s.taskRights where t.target == pid {
            let note = s.isCommonTaskHolder(t.holder)
                ? " · common holder, has \(Int((Double(s.taskTargets(of: t.holder)) / Double(s.processCount) * 100).rounded())) % of processes' task ports" : ""
            add("Task ←", "holds our \(t.flavor) port" + note, peer: t.holder, .taskPort)
        }
        for (type, n) in (s.kernelObjects[pid] ?? [:]).sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }) {
            add("Object", type + times(n), .kobject)
        }
        // Exception handlers: ours (possibly this process itself), and the processes whose exceptions we handle.
        func pct(_ h: Int32) -> Int { Int((Double(s.exceptionsHandled(by: h)) / Double(max(s.processCount, 1)) * 100).rounded()) }
        for r in s.exceptionRoutes where r.process == pid {
            let kinds = r.mask.joined(separator: ", ")
            if r.handler == pid {
                add("In-process", kinds + " exceptions, handled by this process itself", .exception)
            } else {
                add("Handler", kinds + " exceptions go here"
                    + (s.isCommonExceptionHandler(r.handler) ? " · system default, handles \(pct(r.handler)) % of processes'" : ""),
                    peer: r.handler, .exception)
            }
        }
        let handled = s.exceptionRoutes.filter { $0.handler == pid && $0.process != pid }
        if s.isCommonExceptionHandler(pid) {
            let kinds = Set(handled.flatMap(\.mask)).sorted().joined(separator: ", ")
            add("Handles", "system default: \(kinds) exceptions of \(Fmt.count(handled.count)) processes (\(pct(pid)) %)", .exception)
        } else {
            for r in handled { add("Handles", "its " + r.mask.joined(separator: ", ") + " exceptions", peer: r.process, .exception) }
        }
        return out
    }

    /// lsof's resolved other ends, plus each XPC and Mach row's.
    private func peers(_ entries: [LsofEntry]) -> [Int: PeerInfo] {
        var r = resolved
        for e in entries where PeerInfo.linkedKinds.contains(e.kind) { r[e.id] = PeerInfo.linked(e) }
        return r
    }

    private func loadMach(fresh: Bool) async {
        guard store.helperState.isRunning else { mach = .unavailable("Mach ports need the helper: install it to see them."); return }
        machLoading = true
        // The MachServices plists are read here too, once, off the main thread.
        let r = await Task.detached { _ = LaunchdServices.byLabel; return MachLoader.load(fresh: fresh) }.value
        guard !Task.isCancelled else { return }
        mach = r
        machLoading = false
    }

    private var machStatus: some View {
        HStack(spacing: 6) {
            switch mach {
            case .snapshot(let s)?:
                let peers = s.peers(of: pid)
                let common = peers.filter(\.common).count
                let queued = peers.reduce(0) { $0 + $1.queuedHere }
                let own = s.counts[pid].map { c in
                    " · \(Fmt.count(c.total)) ports" + (c.fullQueues > 0 ? ", \(c.fullQueues) full queue\(c.fullQueues == 1 ? "" : "s")" : "")
                        + (c.sendOnce > 0 ? ", \(Fmt.count(c.sendOnce)) repl\(c.sendOnce == 1 ? "y" : "ies") owed" : "")
                        + (c.deadNames > 0 ? ", \(Fmt.count(c.deadNames)) dead name\(c.deadNames == 1 ? "" : "s")" : "")
                } ?? ""
                Text("Mach ports: \(peers.count) processes\(common > 0 ? ", \(common) of them common services" : "")\(queued > 0 ? " · \(queued) message\(queued == 1 ? "" : "s") queued here" : "") \(own) · snapshot of \(s.processCount) processes at \(s.at.formatted(date: .omitted, time: .standard))")
                    .help("From lsmp, as root: which processes can send to which. A right to a port means \"can talk\", not traffic. Common services are peers at least \(Int(MachSnapshot.commonShare * 100)) % of processes can send to; the graph leaves them out.")
            case .unavailable(let why)?:
                Text(why)
            case nil:
                Text("Reading Mach ports…")
            }
            if machLoading { ProgressView().controlSize(.mini) }
            Spacer(minLength: 0)
            Button("Refresh Mach") { Task { await loadMach(fresh: true) } }
                .controlSize(.small).disabled(machLoading || !store.helperState.isRunning)
                .help("Take a new Mach port snapshot (about 3 s of work for the helper)")
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(height: 18)
    }

    private func peerMatches(_ e: LsofEntry, _ f: String) -> Bool {
        guard let info = resolved[e.id] ?? PeerInfo.linked(e) else { return false }
        return info.pids.contains { store.procs[$0]?.name.localizedCaseInsensitiveContains(f) == true || "\($0)" == f }
    }

    private func loadIndex(fresh: Bool) async {
        loading = true
        let viaHelper = store.helperState.isRunning
        let ix = await Task.detached { PeerIndexLoader.load(viaHelper: viaHelper, fresh: fresh) }.value
        guard !Task.isCancelled else { return }
        var r: [Int: PeerInfo] = [:]
        for e in entries { if let info = PeerInfo.resolve(e, pid: pid, in: ix) { r[e.id] = info } }
        index = ix
        resolved = r
        loading = false
    }

    private var peerStatus: some View {
        HStack(spacing: 6) {
            if let ix = index {
                let found = resolved.values.filter { $0.relation != .alsoOpen && !$0.ends.isEmpty }.count
                let missing = resolved.values.filter(\.unresolved).count
                Text("Other ends: \(found) found\(missing > 0 ? ", \(missing) not visible" : "") · searched \(ix.processCount) processes\(ix.scope == .ownUser ? " (yours only)" : "") at \(ix.at.formatted(date: .omitted, time: .standard))")
                    .help(ix.scope == .ownUser
                          ? "Without the helper (or as a standard user) lsof only sees your own processes, so peers in root daemons and other users' processes aren't found."
                          : "From one lsof run over every process, as root.")
            } else {
                Text("Finding other ends…")
            }
            if loading { ProgressView().controlSize(.mini) }
            Spacer(minLength: 0)
            Picker("", selection: $view) {
                Text("Table").tag("Table")
                Text("Graph").tag("Graph")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
            .help("Graph: this process in the middle and the processes on the other end of its pipes and sockets around it, plus its XPC host and the XPC services it hosts (dashed)")
            Button("Refresh") { Task { await loadIndex(fresh: true) } }
                .controlSize(.small).disabled(loading)
                .help("Run lsof over every process again")
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(height: 18)
    }

    private func locationChips(_ counts: [String: Int]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Label("Files in", systemImage: "folder").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(FileLocation.order.filter { counts[$0] != nil } + counts.keys.filter { !FileLocation.order.contains($0) }.sorted(),
                        id: \.self) { loc in
                    let on = locations.contains(loc)
                    Button {
                        if on { locations.remove(loc) } else { locations.insert(loc) }
                    } label: {
                        HStack(spacing: 4) {
                            Text(loc)
                            Text(verbatim: "\(counts[loc] ?? 0)").bold().monospacedDigit()
                        }
                        .font(.system(size: 11))
                        .padding(.horizontal, 8).frame(height: 20)
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .background(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.12)), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
                if !locations.isEmpty { Button("All locations") { locations = [] }.controlSize(.small) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 26)
    }

    private func listening(_ ls: [LsofEntry]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Label("Listening", systemImage: "ear").font(.system(size: 11, weight: .semibold)).foregroundStyle(.blue)
                ForEach(ls) { e in
                    let clients = resolved[e.id]?.pids.count ?? 0
                    Pill(text: e.endpoints.local + (e.type == "IPv6" ? " v6" : "")
                         + (clients > 0 ? " · \(clients) client\(clients == 1 ? "" : "s")" : ""), color: .blue)
                        .help("fd \(e.fd), \(e.type)")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 28)
    }

    struct PeerCell: View {
        @Environment(Store.self) private var store
        let info: PeerInfo
        let pid: Int32
        let scope: PeerIndex.Scope
        private let shown = 2

        var body: some View {
            if info.unresolved {
                Text("not visible").foregroundStyle(.tertiary)
                    .help(scope == .ownUser
                          ? "No process of yours holds the other end: it is probably in a root daemon or another user's process. Install the helper to search every process."
                          : "No running process holds the other end: it may be the kernel, or the peer already closed it.")
            } else {
                let pids = info.pids
                HStack(spacing: 4) {
                    switch info.relation {
                    case .clients: Text("from").foregroundStyle(.secondary)
                    case .alsoOpen: Text("also").foregroundStyle(.secondary)
                    case .otherEnd: EmptyView()
                    }
                    ForEach(pids.prefix(shown), id: \.self) { p in
                        if p == pid {
                            let fds = info.ends.filter { $0.pid == p }.map(\.fd).joined(separator: ", ")
                            Text("this process · fd \(fds)").foregroundStyle(.secondary)
                        } else if let proc = store.procs[p] {
                            ProcessChip(proc: proc)
                        } else {
                            Text(verbatim: "pid \(p)").foregroundStyle(.secondary).strikethrough()
                        }
                    }
                    if pids.count > shown {
                        Text("+\(pids.count - shown)").foregroundStyle(.secondary)
                            .help(pids.dropFirst(shown).map { p in
                                store.procs[p].map { "\($0.name) (\(p))" } ?? "pid \(p)"
                            }.joined(separator: "\n"))
                    }
                }
                .lineLimit(1)
            }
        }
    }

    struct NameCell: View {
        let e: LsofEntry
        var body: some View {
            switch e.kind {
            case .tcp, .udp:
                let p = e.endpoints
                HStack(spacing: 6) {
                    Text(p.local).font(.system(.body, design: .monospaced))
                    if let r = p.remote {
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(r).font(.system(.body, design: .monospaced))
                    }
                    if let s = p.state {
                        Pill(text: s, color: s == "ESTABLISHED" ? .green : s == "LISTEN" ? .blue : .orange)
                    }
                }
                .textSelection(.enabled)
            case .file, .image, .dir:
                let slash = e.name.lastIndex(of: "/")
                let dir = slash.map { String(e.name[...$0]) } ?? ""
                let leaf = slash.map { String(e.name[e.name.index(after: $0)...]) } ?? e.name
                HStack(spacing: 0) {
                    Text(dir).foregroundStyle(.secondary)
                    Text(leaf)
                }
                .lineLimit(1).truncationMode(.head)
                .help(e.name)
                .contextMenu {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: e.name)]) }
                    Button("Copy Path") { ProcessOutline.Coordinator.copy(e.name) }
                }
            default:
                Text(e.name.isEmpty ? "—" : e.name).foregroundStyle(.secondary).lineLimit(1)
                    .help(e.name)
            }
        }
    }
}

// MARK: - vmmap

struct VmmapView: View {
    let s: VMSummary
    let filter: String
    enum Mode: String, CaseIterable { case chart = "Chart", regions = "Regions", zones = "Malloc Zones" }
    @State private var mode = Mode.chart
    @State private var regionSort = [KeyPathComparator(\VMRegion.resident, order: .reverse)]
    @State private var zoneSort = [KeyPathComparator(\MallocZone.allocated, order: .reverse)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(s.warnings.enumerated()), id: \.offset) { _, w in
                Label(w, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    .padding(.horizontal, 10)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    StatTile(title: "Physical footprint", value: Fmt.bytes(s.footprint),
                             sub: s.footprintPeak.map { "peak \(Fmt.bytes($0))" }, color: .accentColor)
                    if let t = s.regionTotal {
                        StatTile(title: "Resident", value: Fmt.bytes(t.resident))
                        StatTile(title: "Dirty", value: Fmt.bytes(t.dirty), color: .orange)
                        StatTile(title: "Swapped", value: Fmt.bytes(t.swapped), color: .purple)
                        StatTile(title: "Regions", value: "\(t.count)")
                    }
                    if let z = s.zoneTotal {
                        StatTile(title: "Malloc allocated", value: Fmt.bytes(z.allocated),
                                 sub: "\(z.allocations.formatted()) allocations · \(z.fragPercent)% frag",
                                 color: z.fragPercent > 50 ? .red : .primary)
                    }
                }
                .padding(.horizontal, 10)
            }
            if let fp = s.footprint, let peak = s.footprintPeak, peak > 0 {
                HStack(spacing: 8) {
                    Text("Footprint vs peak").font(.caption).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                    MiniBar(fraction: Double(fp) / Double(peak), width: 220)
                    Text(verbatim: String(format: "%.0f%%", 100 * Double(fp) / Double(peak))).font(.caption).monospacedDigit()
                }
                .padding(.horizontal, 10)
            }
            ForEach(Array(s.portions.enumerated()), id: \.offset) { _, p in
                PortionBar(title: p.title, total: p.total, parts: p.parts).padding(.horizontal, 10)
            }
            Picker("", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize().padding(.horizontal, 10)
            switch mode {
            case .chart: chart
            case .regions: regionTable
            case .zones: zoneTable
            }
        }
        .padding(.top, 8)
    }

    private var filteredRegions: [VMRegion] {
        s.regions.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
    }

    private var chart: some View {
        let top = Array(filteredRegions.sorted { $0.resident + $0.swapped > $1.resident + $1.swapped }.prefix(20))
        let mx = Double(top.map { $0.resident + $0.swapped }.max() ?? 1)
        let segs: [(String, Color)] = [("Resident (clean)", Color.blue.opacity(0.55)), ("Resident (dirty)", .orange),
                                        ("Swapped / compressed", Color.purple.opacity(0.7))]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("Largest regions by memory in use").font(.caption).foregroundStyle(.secondary)
                ForEach(segs, id: \.0) { s in
                    HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(s.1).frame(width: 10, height: 10); Text(s.0) }
                        .font(.caption)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(top) { r in
                        let dirty = min(r.dirty, r.resident)
                        let parts = [Double(r.resident - dirty), Double(dirty), Double(r.swapped)]
                        HStack(spacing: 8) {
                            Text(r.name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                                .frame(width: 190, alignment: .trailing)
                            GeometryReader { g in
                                HStack(spacing: 0) {
                                    ForEach(0..<3, id: \.self) { i in
                                        Rectangle().fill(segs[i].1).frame(width: g.size.width * parts[i] / max(mx, 1))
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                            .frame(height: 14)
                            Text(Fmt.bytes(r.resident + r.swapped)).font(.system(size: 11)).monospacedDigit()
                                .frame(width: 70, alignment: .leading)
                        }
                        .help("\(r.name): resident \(Fmt.bytes(r.resident)) (dirty \(Fmt.bytes(r.dirty))), swapped \(Fmt.bytes(r.swapped)), virtual \(Fmt.bytes(r.virtual))")
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 10)
    }

    private var regionTable: some View {
        let rows = filteredRegions.sorted(using: regionSort)
        let maxRes = Double(rows.map(\.resident).max() ?? 1)
        let maxSwap = Double(rows.map(\.swapped).max() ?? 1)
        return Table(rows, sortOrder: $regionSort) {
            TableColumn("Region", value: \.name) { r in
                HStack {
                    Text(r.name)
                    if !r.note.isEmpty { Image(systemName: "info.circle").foregroundStyle(.secondary).help(r.note) }
                }
            }.width(min: 140, ideal: 220)
            TableColumn("Virtual", value: \.virtual) { r in Text(Fmt.bytes(r.virtual)).monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 60, ideal: 70)
            TableColumn("Resident", value: \.resident) { r in
                HStack { MiniBar(fraction: Double(r.resident) / max(maxRes, 1), color: .blue, width: 50)
                    Text(Fmt.bytes(r.resident)).monospacedDigit() }
            }.width(min: 110, ideal: 130)
            TableColumn("Dirty", value: \.dirty) { r in Text(Fmt.bytes(r.dirty)).monospacedDigit().foregroundStyle(r.dirty > 0 ? .orange : .secondary) }
                .width(min: 60, ideal: 70)
            TableColumn("Swapped", value: \.swapped) { r in
                HStack { MiniBar(fraction: Double(r.swapped) / max(maxSwap, 1), color: .purple, width: 50)
                    Text(Fmt.bytes(r.swapped)).monospacedDigit() }
            }.width(min: 110, ideal: 130)
            TableColumn("Count", value: \.count) { r in Text(verbatim: "\(r.count)").monospacedDigit() }.width(min: 40, ideal: 50)
        }
    }

    private var zoneTable: some View {
        let rows = s.zones.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }.sorted(using: zoneSort)
        let maxAlloc = Double(rows.map(\.allocated).max() ?? 1)
        return Table(rows, sortOrder: $zoneSort) {
            TableColumn("Zone", value: \.name) { z in Text(z.name) }.width(min: 160, ideal: 240)
            TableColumn("Allocated", value: \.allocated) { z in
                HStack { MiniBar(fraction: Double(z.allocated) / max(maxAlloc, 1), color: .blue, width: 50)
                    Text(Fmt.bytes(z.allocated)).monospacedDigit() }
            }.width(min: 110, ideal: 130)
            TableColumn("Allocations", value: \.allocations) { z in Text(verbatim: z.allocations.formatted()).monospacedDigit() }
                .width(min: 70, ideal: 80)
            TableColumn("Fragmentation", value: \.fragPercent) { z in
                HStack {
                    MiniBar(fraction: Double(z.fragPercent) / 100, color: z.fragPercent > 50 ? .red : .orange, width: 50)
                    Text(verbatim: "\(z.fragPercent)%").monospacedDigit()
                    Text(Fmt.bytes(z.fragSize)).foregroundStyle(.secondary).monospacedDigit()
                }
            }.width(min: 150, ideal: 170)
            TableColumn("Resident", value: \.resident) { z in Text(Fmt.bytes(z.resident)).monospacedDigit() }.width(min: 60, ideal: 70)
            TableColumn("Swapped", value: \.swapped) { z in Text(Fmt.bytes(z.swapped)).monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 60, ideal: 70)
        }
    }
}

/// "Writable regions: Total=4.7G written=145.2M(3%) …" as a labelled stacked bar.
struct PortionBar: View {
    let title: String
    let total: UInt64?
    let parts: [(String, UInt64?, Int?)]
    private let palette: [Color] = [.blue, .orange, .purple, .gray, .teal]

    var body: some View {
        // Only the parts that partition the total (vmmap lists "written" as a superset of resident/swapped).
        let shown = parts.filter { $0.0 != "written" }
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 150, alignment: .leading).lineLimit(1)
            GeometryReader { g in
                HStack(spacing: 1) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { i, p in
                        Rectangle().fill(palette[i % palette.count].opacity(0.8))
                            .frame(width: max(1, g.size.width * Double(p.2 ?? 0) / 100))
                    }
                    Spacer(minLength: 0)
                }
                .clipShape(Capsule())
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }
            .frame(width: 220, height: 6)
            HStack(spacing: 8) {
                Text(verbatim: Fmt.bytes(total)).font(.caption).bold()
                ForEach(Array(shown.enumerated()), id: \.offset) { i, p in
                    HStack(spacing: 3) {
                        Circle().fill(palette[i % palette.count]).frame(width: 6, height: 6)
                        Text(verbatim: "\(p.0.replacingOccurrences(of: "_", with: " ")) \(Fmt.bytes(p.1))").font(.caption)
                    }
                }
            }
            .lineLimit(1)
        }
    }
}

// MARK: - sample (call tree)

private let idleLeaves: Set<String> = [
    "mach_msg2_trap", "mach_msg_trap", "__workq_kernreturn", "semaphore_wait_trap", "semaphore_timedwait_trap",
    "__psynch_cvwait", "__psynch_mutexwait", "__psynch_rw_rdlock", "__psynch_rw_wrlock", "kevent", "kevent64", "kevent_id",
    "kevent_qos", "__select", "__semwait_signal", "__ulock_wait", "__ulock_wait2", "__sigsuspend", "__wait4", "__accept",
    "poll", "read", "__recvfrom", "__recvmsg", "__pselect", "__sleep", "start_wqthread", "__workq_open",
]

extension CallNode {
    var isIdleLeaf: Bool { children.isEmpty && idleLeaves.contains(symbol) }
    /// Samples where this frame itself was on top of the stack.
    var selfCount: Int { max(0, count - children.map(\.count).reduce(0, +)) }
    func leaves() -> [CallNode] { children.isEmpty ? [self] : children.flatMap { $0.leaves() } }
    /// Samples spent on top of the stack in a frame that isn't a known wait: a leaf's samples, and an
    /// inner frame's own (self) samples too. Counting leaves only called a thread spinning in `hot_loop`
    /// with one blocking callee "idle". The wait list is a heuristic: a busy `read` still counts as waiting.
    var busySamples: Int {
        var own = isThread || idleLeaves.contains(symbol) ? 0 : selfCount
        for c in children { own += c.busySamples }
        return own
    }
}

struct SampleView: View {
    let report: SampleReport
    let filter: String
    @State private var expanded: Set<Int>
    @State private var hideIdle: Bool
    /// The filter's match set, computed once per filter change. As a computed property it walked the
    /// whole call tree on every read, once more for every rendered row.
    @State private var matchCache: (filter: String, set: Set<Int>?) = ("", nil)

    init(report: SampleReport, filter: String) {
        self.report = report
        self.filter = filter
        // Busy threads open fully; threads that only sat in a wait are collapsed to their header.
        var open: Set<Int> = []
        func all(_ n: CallNode) { open.insert(n.id); n.children.forEach(all) }
        for t in report.threads where t.busySamples > 0 { all(t) }
        _expanded = State(initialValue: open)
        _hideIdle = State(initialValue: false)
    }

    private struct Row: Identifiable {
        let node: CallNode
        let depth: Int
        let total: Int
        var id: Int { node.id }
    }

    private var matches: Set<Int>? {
        if matchCache.filter == filter { return matchCache.set }
        return Self.matches(report, filter)   // first render after a change, before onChange caches it
    }

    private static func matches(_ report: SampleReport, _ filter: String) -> Set<Int>? {
        guard !filter.isEmpty else { return nil }
        var keep: Set<Int> = []
        @discardableResult func walk(_ n: CallNode) -> Bool {
            var hit = n.symbol.localizedCaseInsensitiveContains(filter) || (n.library?.localizedCaseInsensitiveContains(filter) ?? false)
            for c in n.children where walk(c) { hit = true }
            if hit { keep.insert(n.id) }
            return hit
        }
        report.threads.forEach { walk($0) }
        return keep
    }

    private func rows(_ m: Set<Int>?) -> [Row] {
        var out: [Row] = []
        func walk(_ n: CallNode, _ d: Int, _ total: Int) {
            if let m, !m.contains(n.id) { return }
            out.append(Row(node: n, depth: d, total: total))
            if m != nil || expanded.contains(n.id) { n.children.forEach { walk($0, d + 1, total) } }
        }
        for t in report.threads where !(hideIdle && t.busySamples == 0) { walk(t, 0, max(t.count, 1)) }
        return out
    }

    var body: some View {
        let m = matches
        let busyThreads = report.threads.filter { $0.busySamples > 0 }.count
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                StatTile(title: "Threads", value: "\(report.threads.count)", sub: "\(busyThreads) doing work")
                StatTile(title: "Samples / thread", value: "\(report.totalSamples)")
                if !report.topOfStack.isEmpty { heaviest }
                Spacer(minLength: 0)
            }
            .padding(8)
            HStack(spacing: 10) {
                // A search shows every matching path open whatever the expansion; these would change
                // state that isn't shown, only to surface when the search is cleared.
                Group {
                    Button("Expand all") { var s: Set<Int> = []; func a(_ n: CallNode) { s.insert(n.id); n.children.forEach(a) }; report.threads.forEach(a); expanded = s }
                    Button("Collapse all") { expanded = [] }
                }
                .disabled(!filter.isEmpty)
                .help(filter.isEmpty ? "" : "While filtering, every matching branch is shown open")
                Toggle("Hide idle threads", isOn: $hideIdle).toggleStyle(.checkbox)
                Spacer()
                HStack(spacing: 4) { Circle().fill(.orange).frame(width: 6, height: 6); Text("on CPU") }
                HStack(spacing: 4) { Circle().fill(.gray.opacity(0.6)).frame(width: 6, height: 6); Text("waiting") }
            }
            .controlSize(.small).font(.caption)
            .padding(.horizontal, 8).padding(.bottom, 6)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows(m)) { r in row(r) }
                }
                .padding(.vertical, 4)
            }
        }
        .onChange(of: filter, initial: true) { _, f in matchCache = (f, Self.matches(report, f)) }
    }

    private var heaviest: some View {
        let top = report.topOfStack.prefix(4)
        let mx = Double(top.map(\.count).max() ?? 1)
        return VStack(alignment: .leading, spacing: 2) {
            Text("Heaviest top-of-stack frames").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(top.enumerated()), id: \.offset) { _, f in
                HStack(spacing: 6) {
                    MiniBar(fraction: Double(f.count) / mx, color: idleLeaves.contains(f.symbol) ? .gray : .orange, width: 60)
                    Text(verbatim: "\(f.count)").font(.caption2).monospacedDigit().frame(width: 34, alignment: .trailing)
                    Text(f.symbol).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                    if let l = f.library { Text(l).font(.caption2).foregroundStyle(libColor(l)) }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func row(_ r: Row) -> some View {
        let n = r.node
        let open = expanded.contains(n.id) || !filter.isEmpty
        let canToggle = !n.children.isEmpty && filter.isEmpty
        let frac = Double(n.count) / Double(r.total)
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(r.depth) * 12, height: 1)
            Image(systemName: n.children.isEmpty ? "circle.fill" : (open ? "chevron.down" : "chevron.right"))
                .font(.system(size: n.children.isEmpty ? 4 : 9, weight: .bold))
                .foregroundStyle(n.children.isEmpty ? (n.isIdleLeaf ? Color.gray : Color.orange) : Color.secondary)
                .frame(width: 12)
                .accessibilityHidden(true)
            Text(verbatim: "\(n.count)").monospacedDigit().font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
            MiniBar(fraction: frac, color: n.isThread ? .accentColor : (n.busySamples > 0 ? .orange : .gray), width: 44)
            if n.isThread {
                Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                Text(n.symbol).bold().lineLimit(1)
                let busy = n.busySamples
                Pill(text: busy == 0 ? "idle" : String(format: "%.0f%% busy", 100 * Double(busy) / Double(max(n.count, 1))),
                     color: busy == 0 ? .secondary : .orange)
                if busy == 0, let leaf = n.leaves().max(by: { $0.count < $1.count }) {
                    Text("waiting in \(leaf.symbol)").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(n.symbol).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(n.isIdleLeaf ? .secondary : .primary)
                if let l = n.library { Text(l).font(.system(size: 10)).foregroundStyle(libColor(l)) }
                if !n.children.isEmpty, n.selfCount > 0 {
                    Pill(text: "self \(n.selfCount)", color: .orange)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: n.isThread ? 24 : 18)
        .padding(.horizontal, 6)
        .background(n.isThread ? Color.secondary.opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { if canToggle { toggle(n) } }
        .help("\(n.symbol)\(n.library.map { " (in \($0))" } ?? "") — \(n.count) samples")
        // One VoiceOver element per row: its text, an expanded/collapsed value and a press action.
        .accessibilityElement(children: .combine)
        .accessibilityValue(n.children.isEmpty ? "" : (open ? "expanded" : "collapsed"))
        .accessibilityAddTraits(canToggle ? .isButton : [])
        .accessibilityAction { if canToggle { toggle(n) } }
    }

    private func toggle(_ n: CallNode) {
        if expanded.contains(n.id) { expanded.remove(n.id); return }
        // Open the whole linear chain down to the next branch point (sample trees are mostly chains).
        var cur: CallNode? = n
        while let c = cur {
            expanded.insert(c.id)
            cur = c.children.count == 1 ? c.children[0] : nil
        }
    }
}

// MARK: - log

extension LogEntry.Level {
    var color: Color {
        switch self {
        case .fault: .purple
        case .error: .red
        case .default: .gray
        case .info: .blue
        case .debug: .mint
        case .activity: .teal
        }
    }
}

struct LogView: View {
    let entries: [LogEntry]
    let filter: String
    @State private var levels: Set<LogEntry.Level> = []
    /// Filtered rows, level counts and histogram, computed off the main thread once per filter/level
    /// change. Recomputing them in `body` cost ~150 ms per render for 100,000 events: every keystroke,
    /// resize or parent update blocked the UI.
    @State private var view: Filtered?

    struct Filtered: Sendable {
        var key: String
        var rows: [LogEntry]
        var counts: [LogEntry.Level: Int]
        var hist: Histogram?
    }

    struct Histogram: Sendable {
        static let buckets = 60
        var lo: Date, hi: Date, step: Double, peak: Int
        var bins: [[LogEntry.Level: Int]]
    }

    private var key: String { "\(filter)\u{0}\(levels.map(\.rawValue).sorted())" }

    var body: some View {
        Group {
            if let v = view {
                content(v)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: key) {
            let key = key, entries = entries, filter = filter, levels = levels
            // Typing: wait for a pause before filtering 100,000 rows (the first pass runs right away).
            if view != nil { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            let v = await Task.detached(priority: .userInitiated) { Self.compute(key, entries, filter, levels) }.value
            guard !Task.isCancelled else { return }
            view = v
        }
    }

    nonisolated static func compute(_ key: String, _ entries: [LogEntry], _ filter: String,
                                    _ levels: Set<LogEntry.Level>) -> Filtered {
        var counts: [LogEntry.Level: Int] = [:]
        for e in entries { counts[e.level, default: 0] += 1 }
        let rows = filter.isEmpty && levels.isEmpty ? entries : entries.filter {
            (levels.isEmpty || levels.contains($0.level)) &&
            (filter.isEmpty || $0.message.localizedCaseInsensitiveContains(filter) || $0.subsystem.localizedCaseInsensitiveContains(filter))
        }
        var lo = Date.distantFuture, hi = Date.distantPast
        for e in rows { if let d = e.date { if d < lo { lo = d }; if d > hi { hi = d } } }
        var hist: Histogram?
        if lo <= hi {
            let nb = Histogram.buckets
            let step = max(hi.timeIntervalSince(lo), 1) / Double(nb)
            var bins = Array(repeating: [LogEntry.Level: Int](), count: nb)
            for e in rows { guard let d = e.date else { continue }
                bins[min(nb - 1, Int(d.timeIntervalSince(lo) / step))][e.level, default: 0] += 1 }
            let peak = max(bins.map { $0.values.reduce(0, +) }.max() ?? 1, 1)
            hist = Histogram(lo: lo, hi: hi, step: step, peak: peak, bins: bins)
        }
        return Filtered(key: key, rows: rows, counts: counts, hist: hist)
    }

    private func content(_ v: Filtered) -> some View {
        let rows = v.rows, counts = v.counts
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(LogEntry.Level.allCases.filter { counts[$0] != nil }, id: \.self) { l in
                    let on = levels.contains(l)
                    Button { if on { levels.remove(l) } else { levels.insert(l) } } label: {
                        HStack(spacing: 4) { Text(l.rawValue); Text(verbatim: "\(counts[l] ?? 0)").bold().monospacedDigit() }
                            .font(.system(size: 11)).padding(.horizontal, 8).frame(height: 22)
                            .foregroundStyle(on ? .white : l.color)
                            .background(on ? AnyShapeStyle(l.color) : AnyShapeStyle(l.color.opacity(0.14)), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
                Spacer()
                if v.key != key { ProgressView().controlSize(.small) }   // a newer filter is being applied
                Text(verbatim: "\(rows.count) of \(entries.count) events").font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
            histogram(v.hist).frame(height: 70).padding(.horizontal, 8).padding(.bottom, 6)
            Table(rows) {
                TableColumn("Time") { e in Text(e.time).monospacedDigit().foregroundStyle(.secondary) }.width(min: 80, ideal: 90, max: 110)
                TableColumn("Level") { e in Pill(text: e.level.rawValue, color: e.level.color) }.width(min: 54, ideal: 60, max: 70)
                TableColumn("Thread") { e in Text(e.thread).monospaced().foregroundStyle(.secondary) }.width(min: 50, ideal: 60, max: 80)
                TableColumn("Subsystem") { e in
                    let parts = e.subsystem.split(separator: ":", maxSplits: 1).map(String.init)
                    HStack(spacing: 4) {
                        if let s = parts.first { Text(s).foregroundStyle(libColor(s)) }
                        if parts.count > 1 { Pill(text: parts[1]) }
                    }
                    .lineLimit(1)
                }.width(min: 110, ideal: 170, max: 260)
                TableColumn("Message") { e in Text(e.message).lineLimit(2).help(e.message) }
            }
        }
    }

    private static let timeFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    /// Event-rate histogram: 60 time buckets, each a column stacked by level (severest on top).
    private func histogram(_ h: Histogram?) -> some View {
        guard let h else { return AnyView(Color.clear) }
        let nb = Histogram.buckets, bins = h.bins, peak = h.peak, lo = h.lo, step = h.step
        let order: [LogEntry.Level] = [.fault, .error, .activity, .info, .default, .debug]
        let tf = Self.timeFormatter
        return AnyView(VStack(spacing: 2) {
            HStack(alignment: .bottom, spacing: 0) {
                Text(verbatim: "\(peak)").font(.caption2).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                    .frame(maxHeight: .infinity, alignment: .top)
                GeometryReader { g in
                    HStack(alignment: .bottom, spacing: 1) {
                        ForEach(0..<nb, id: \.self) { i in
                            VStack(spacing: 0) {
                                ForEach(order, id: \.self) { l in
                                    if let n = bins[i][l] {
                                        Rectangle().fill(l.color.opacity(0.85)).frame(height: max(l == .fault || l == .error ? 2 : 0, g.size.height * Double(n) / Double(peak)))
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .help("\(tf.string(from: lo.addingTimeInterval(Double(i) * step))): " +
                                  order.compactMap { l in bins[i][l].map { "\($0) \(l.rawValue.lowercased())" } }.joined(separator: ", "))
                        }
                    }
                    .frame(height: g.size.height, alignment: .bottom)
                }
                .padding(.leading, 6)
            }
            HStack {
                Text(tf.string(from: lo)); Spacer(); Text(tf.string(from: h.hi))
            }
            .font(.caption2).foregroundStyle(.secondary).padding(.leading, 40)
        })
    }
}

// MARK: - launchctl print / procinfo tree

struct KVTreeContent: View {
    let nodes: [KVNode]
    let filter: String

    private func keep(_ n: KVNode) -> Bool {
        filter.isEmpty || n.key.localizedCaseInsensitiveContains(filter) || (n.value?.localizedCaseInsensitiveContains(filter) ?? false)
            || n.children.contains(where: keep)
    }

    var body: some View {
        let ns = nodes.filter(keep)
        let leaves = ns.filter(\.isLeaf)
        let branches = ns.filter { !$0.isLeaf }
        // Small blocks tile two-up; big ones (entitlements, endpoint lists) get the full width so a
        // tall card never stretches a grid row and leaves its neighbour's column empty.
        let small = branches.filter { size($0) <= 10 }
        let large = branches.filter { size($0) > 10 }
        VStack(alignment: .leading, spacing: 10) {
            if !leaves.isEmpty {
                Card(title: "Overview", systemImage: "list.bullet.rectangle") {
                    KVGrid(rows: leaves.map { ($0.key, $0.value ?? "") })
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                ForEach(small) { card($0) }
            }
            ForEach(large) { card($0) }
        }
    }

    private func size(_ n: KVNode) -> Int { n.children.reduce(n.children.count) { $0 + size($1) } }

    private func card(_ b: KVNode) -> some View {
        Card(title: b.key, systemImage: icon(for: b.key), trailing: b.value ?? "\(b.children.count)") {
            Branch(node: b, filter: filter, keep: keep)
        }
    }

    private func icon(for key: String) -> String {
        let k = key.lowercased()
        if k.contains("environment") { return "leaf" }
        if k.contains("endpoint") || k.contains("port") { return "point.3.connected.trianglepath.dotted" }
        if k.contains("coalition") { return "square.stack.3d.up" }
        if k.contains("argument") { return "terminal" }
        if k.contains("entitle") || k.contains("code signing") { return "checkmark.seal" }
        if k.contains("audit") || k.contains("info") { return "info.circle" }
        if k.contains("semaphore") || k.contains("event") { return "bolt" }
        return "curlybraces"
    }

    struct Branch: View {
        let node: KVNode
        let filter: String
        let keep: (KVNode) -> Bool
        var body: some View {
            let kids = node.children.filter(keep)
            let leaves = kids.filter(\.isLeaf)
            VStack(alignment: .leading, spacing: 6) {
                if !leaves.isEmpty { KVGrid(rows: leaves.map { ($0.key, $0.value ?? "") }) }
                ForEach(kids.filter { !$0.isLeaf }) { c in
                    DisclosureGroup {
                        Branch(node: c, filter: filter, keep: keep).padding(.leading, 4)
                    } label: {
                        HStack {
                            Text(c.key).font(.system(.body, design: .monospaced))
                            if let v = c.value { Text(v).foregroundStyle(.secondary) }
                            Spacer()
                            Text(verbatim: "\(c.children.count)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

struct KVTreeView: View {
    let text: String
    let filter: String
    var body: some View {
        let nodes = LaunchctlParser.parse(text)
        if nodes.isEmpty {
            UnparsedNote(raw: text)
        } else {
            ScrollView { KVTreeContent(nodes: nodes, filter: filter).padding(10) }
        }
    }
}

// MARK: - LaunchServices record

struct LSRecordContent: View {
    let raw: String
    let filter: String
    var body: some View {
        let header = raw.split(separator: "\n").first.map(String.init) ?? ""
        let rows = LSRecordParser.rows(raw).filter {
            filter.isEmpty || $0.0.localizedCaseInsensitiveContains(filter) || $0.1.localizedCaseInsensitiveContains(filter)
        }
        let flags = rows.filter { $0.0 == "flag" }.map(\.1)
        Card(title: header.trimmingCharacters(in: .whitespaces).components(separatedBy: " ASN:").first ?? "",
             systemImage: "app.badge", trailing: header.components(separatedBy: " ").first { $0.hasPrefix("ASN:") }) {
            if !flags.isEmpty { FlowPills(items: flags, color: .orange) }
            KVGrid(rows: rows.filter { $0.0 != "flag" })
        }
    }
}

// MARK: - Entitlements

struct PlistValue: View {
    let value: Any
    var body: some View {
        if let b = value as? Bool, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
            Image(systemName: b ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(b ? .green : .red)
        } else if let s = value as? String {
            Text(s).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
        } else if let n = value as? NSNumber {
            Text(n.stringValue).monospacedDigit()
        } else if let a = value as? [Any] {
            VStack(alignment: .trailing, spacing: 2) {
                ForEach(Array(a.enumerated()), id: \.offset) { _, v in
                    if let s = v as? String { Pill(text: s, color: .accentColor) } else { PlistValue(value: v) }
                }
            }
        } else if let d = value as? [String: Any] {
            VStack(alignment: .trailing, spacing: 2) {
                ForEach(d.keys.sorted(), id: \.self) { k in
                    HStack { Text(k).font(.caption).foregroundStyle(.secondary); PlistValue(value: d[k]!) }
                }
            }
        } else if let data = value as? Data {
            Text("\(data.count) bytes").foregroundStyle(.secondary)
        } else {
            Text(String(describing: value)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - File locations

/// Where an open file lives, in a few places people recognise. Mapped images are included: which
/// frameworks a process loaded from outside the system is often the interesting part.
enum FileLocation {
    static let order = ["Own app", "Other apps", "Containers", "~/Library", "Home", "Temporary", "Local software", "/Library", "System", "Other"]
    private static let home = NSHomeDirectory()

    static func of(_ e: LsofEntry, ownBundle: String?) -> String {
        guard [.file, .dir, .image].contains(e.kind), e.name.hasPrefix("/") else { return "" }
        return of(path: e.name, ownBundle: ownBundle)
    }

    static func of(path p: String, ownBundle: String?) -> String {
        // A folder counts as inside itself: /Users/me is Home, /System is System.
        func under(_ dir: String) -> Bool { p == dir || p.hasPrefix(dir + "/") }
        if let b = ownBundle, under(b) { return "Own app" }
        if p.hasPrefix("/Volumes/") {
            let name = p.dropFirst("/Volumes/".count).prefix { $0 != "/" }
            return "Volume \(name)"
        }
        if under(home + "/Library/Containers") || under(home + "/Library/Group Containers") { return "Containers" }
        if under(home + "/Library") { return "~/Library" }
        if p.contains(".app/") || p.hasSuffix(".app") || under("/Applications") { return "Other apps" }
        if under(home) { return "Home" }
        if ["/private/var/folders", "/var/folders", "/private/tmp", "/tmp"].contains(where: under) { return "Temporary" }
        if under("/usr/local") || under("/opt") { return "Local software" }   // Homebrew and the like
        if under("/Library/Apple") { return "System" }
        if under("/Library") { return "/Library" }
        if p == "/" || ["/System", "/usr", "/bin", "/sbin", "/private", "/var", "/dev", "/Users", "/etc", "/cores"].contains(where: under) {
            return "System"
        }
        return "Other"
    }
}

// MARK: - Peer graph

/// This process in the middle, the processes on the other end of its pipes, unix sockets and TCP
/// connections around it, one edge each, labelled with how many of each kind. XPC links (the `.xpc` rows
/// from LsofView.xpcEntries) are drawn dashed: a registration means "can talk", not an open connection.
struct PeerGraph: View {
    @Environment(Store.self) private var store
    let center: Int32
    let entries: [LsofEntry]
    let resolved: [Int: PeerInfo]
    /// To leave out common services (MachSnapshot.isCommon) the center only shares Mach ports with.
    var mach: MachSnapshot?
    private let maxPeers = 24

    private struct Peer: Identifiable {
        let id: Int32
        var kinds: [LsofEntry.Kind: Int] = [:]
        /// "XPC host", "XPC service" or "XPC extension" when the two share a launchd pid domain link.
        var xpc: String?
        /// Mach ports shared, both directions.
        var machPorts = 0
        /// Task port flavors held, either way ("control", "read"…), and memory entries shared with few others.
        var taskPorts: [String] = []
        /// "→" when the peer handles the center's exceptions, "←" when the center handles the peer's.
        var exceptions: [String] = []
        var sharedMemory = 0
        /// Counts each Mach or XPC link once, so a peer with 40 ports doesn't outweigh real connections.
        var total: Int { kinds.values.reduce(0, +) + (xpc == nil ? 0 : 1) + (machPorts > 0 ? 1 : 0) }
        var label: String {
            ([xpc].compactMap { $0 } + LsofEntry.Kind.allCases.compactMap { k in kinds[k].map { "\(Self.short(k)) \($0)" } }
             + taskPorts.map { "task \($0)" } + exceptions.map { "exc \($0)" } + (sharedMemory > 0 ? ["shm \(sharedMemory)"] : [])
             + (machPorts > 0 ? ["mach \(machPorts)"] : []))
                .joined(separator: " · ")
        }
        /// No descriptor, only rights (XPC, Mach): "can talk", so the edge is dashed.
        var canTalkOnly: Bool { kinds.isEmpty }
        /// Which peers make the cut: open descriptors first, then XPC, then Mach ports by count.
        var rank: (Int, Int, Int, Int, Int) { (kinds.values.reduce(0, +), xpc == nil ? 0 : 1, taskPorts.count + exceptions.count, sharedMemory, machPorts) }
        var edgeColor: Color {
            !kinds.isEmpty ? main.color : xpc != nil ? LsofEntry.Kind.xpc.color : !taskPorts.isEmpty ? LsofEntry.Kind.taskPort.color
                : !exceptions.isEmpty ? LsofEntry.Kind.exception.color
                : sharedMemory > 0 ? LsofEntry.Kind.sharedMemory.color : LsofEntry.Kind.mach.color
        }
        var main: LsofEntry.Kind { kinds.max { $0.value < $1.value }?.key ?? .unix }
        static func short(_ k: LsofEntry.Kind) -> String {
            switch k { case .pipe: "pipe"; case .unix: "unix"; case .tcp: "TCP"; case .udp: "UDP"; default: k.rawValue }
        }
    }

    /// The peers drawn, and how many common services were left out: a peer only linked by Mach ports that
    /// most processes can send to (launchd, logd…) would be on every map.
    private var peers: (shown: [Peer], commonHidden: Int) {
        let machPeers = Dictionary((mach?.peers(of: center) ?? []).map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var by: [Int32: Peer] = [:]
        for e in entries {
            guard let info = resolved[e.id], info.relation != .alsoOpen else { continue }
            if e.kind == .xpc {
                for pid in info.pids where pid != center { by[pid, default: Peer(id: pid)].xpc = e.type }
                continue
            }
            if e.kind == .mach {
                guard let pid = info.pids.first, pid != center, let p = machPeers[pid] else { continue }
                by[pid, default: Peer(id: pid)].machPorts = p.sendsTo + p.receivesFrom
                continue
            }
            // Task ports and shared memory come from the snapshot below.
            if PeerInfo.linkedKinds.contains(e.kind) { continue }
            for pid in info.pids where pid != center {
                by[pid, default: Peer(id: pid)].kinds[e.kind, default: 0] += 1
            }
        }
        for t in mach?.taskRights ?? [] where t.holder == center || t.target == center {
            // Its port held here: "task control"; ours held there: "task ← control".
            let other = t.holder == center ? t.target : t.holder
            // coreservicesd holds most processes' task ports: on every map, so left out like a common service.
            guard other != center, !(t.target == center && mach?.isCommonTaskHolder(other) == true) else { continue }
            by[other, default: Peer(id: other)].taskPorts.append(t.holder == center ? t.flavor : "← \(t.flavor)")
        }
        for m in mach?.sharedMemory(of: center) ?? [] { by[m.pid, default: Peer(id: m.pid)].sharedMemory += m.entries }
        // The system default handler (ReportCrash) would be on most maps, like a common service.
        for r in mach?.exceptionRoutes ?? [] where r.process != r.handler && (r.process == center || r.handler == center) {
            if r.process == center, mach?.isCommonExceptionHandler(r.handler) == true { continue }
            if r.handler == center, mach?.isCommonExceptionHandler(center) == true { continue }
            let other = r.process == center ? r.handler : r.process
            by[other, default: Peer(id: other)].exceptions.append(r.process == center ? "→" : "←")
        }
        let common = by.values.filter {
            $0.kinds.isEmpty && $0.xpc == nil && $0.taskPorts.isEmpty && $0.exceptions.isEmpty && $0.sharedMemory == 0 && machPeers[$0.id]?.common == true
        }.map(\.id)
        for c in common { by[c] = nil }
        return (by.values.sorted { $0.rank != $1.rank ? $0.rank > $1.rank : $0.id < $1.id }, common.count)
    }

    var body: some View {
        let (all, commonHidden) = peers
        let shown = Array(all.prefix(maxPeers))
        GeometryReader { g in
            let mid = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            let rx = max(60, g.size.width / 2 - 110), ry = max(40, g.size.height / 2 - 30)
            let spots = shown.indices.map { i -> CGPoint in
                let a = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(max(shown.count, 1))
                return CGPoint(x: mid.x + rx * cos(a), y: mid.y + ry * sin(a))
            }
            ZStack {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, p in
                    Path { path in path.move(to: mid); path.addLine(to: spots[i]) }
                        .stroke(p.edgeColor.opacity(p.canTalkOnly ? 0.75 : 0.55),
                                style: StrokeStyle(lineWidth: p.canTalkOnly ? 1.5 : min(1 + Double(p.total) / 2, 5),
                                                   dash: p.canTalkOnly ? [5, 3] : []))
                    Text(p.label)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .padding(.horizontal, 3)
                        .background(Color(nsColor: .windowBackgroundColor).opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                        .position(x: (mid.x + spots[i].x) / 2, y: (mid.y + spots[i].y) / 2)
                }
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, p in
                    node(p.id).position(spots[i])
                }
                node(center).scaleEffect(1.15).position(mid)
                let notes = (all.count > shown.count ? ["+\(all.count - shown.count) more"] : [])
                    + (commonHidden > 0 ? ["\(commonHidden) common service\(commonHidden == 1 ? "" : "s") left out (Mach only), in the table"] : [])
                if !notes.isEmpty {
                    Text(notes.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize().frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 10)
                        .position(x: g.size.width / 2, y: g.size.height - 12)
                }
                if all.isEmpty {
                    let hidden = resolved.values.filter(\.unresolved).count
                    Text(resolved.isEmpty ? "Finding other ends…"
                         : hidden > 0 ? "\(hidden) other end\(hidden == 1 ? "" : "s") not visible: in processes lsof can't see from here."
                         : "No other process on the end of its pipes or sockets, and no XPC host or services.")
                        .foregroundStyle(.secondary).position(x: mid.x, y: mid.y + 40)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Peer graph: \(all.count) processes")
    }

    /// A solid backing, so edges pass behind the chip instead of through its translucent capsule.
    private func node(_ pid: Int32) -> some View {
        Group {
            if let p = store.procs[pid] {
                ProcessChip(proc: p)
            } else {
                Text(verbatim: "pid \(pid)").font(.caption).foregroundStyle(.secondary).strikethrough()
                    .padding(.horizontal, 6)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
    }
}
