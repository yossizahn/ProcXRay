import AppKit
import SwiftUI

// The inspector's tabs and its fixed header (docs/ui-regrouping-plan.md, Part 5). Info, Launch, Security
// and Usage are built here; the other tabs are their own views.

/// The inspector's tabs, named by what they hold: static facts, then live counters, then on-demand captures
/// (docs/ui-regrouping-plan.md, 5.1).
enum InspectorTab: String, CaseIterable, Identifiable {
    case info = "Info"
    case launch = "Launch"
    case security = "Security"
    case usage = "Usage"
    case threads = "Threads"
    case memory = "Memory"
    case filesPorts = "Files & Ports"
    case logs = "Logs"
    case sample = "Sample"
    case syscalls = "Syscalls"
    var id: String { rawValue }

    /// A stored tab name, including the six names an earlier version stored.
    init?(stored raw: String) {
        let old: [String: InspectorTab] = ["Overview": .info, "Origin": .launch, "Trust": .security,
                                           "Resources": .usage, "Connections": .filesPorts, "Activity": .logs]
        guard let t = InspectorTab(rawValue: raw) ?? old[raw] else { return nil }
        self = t
    }

    /// ⌘1 … ⌘9, then ⌘0 for the tenth.
    var shortcut: KeyEquivalent {
        let i = InspectorTab.allCases.firstIndex(of: self)!
        return KeyEquivalent(Character(String((i + 1) % 10)))
    }
}

// MARK: - Header

/// Always visible above the tabs: who the process is, what owns it, and the actions.
struct InspectorHeader: View {
    @Environment(Store.self) var store
    @Environment(\.inspectorLinks) private var links
    let proc: ProcInfo
    let exited: Bool
    let sign: SignInfo?

    var body: some View {
        let p = proc
        let owner = store.unitRoot(of: p).flatMap { $0 == p.pid ? nil : store.procs[$0] }
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let links { HistoryButtons(links: links) }
                Group {
                    if let img = IconCache.icon(for: p) { Image(nsImage: img) } else { Image(systemName: "terminal") }
                }
                .frame(width: 16, height: 16)
                Text(p.name).font(.headline).lineLimit(1).truncationHelp(p.name)
                Text(verbatim: "pid \(p.pid) · \(p.user) · \(Fmt.age(p.start))")
                    .foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    .truncationHelp("pid \(p.pid) · \(p.user) · \(Fmt.age(p.start))")
                Spacer(minLength: 0)
            }
            .frame(height: 22)
            // What it is, whose it is, its sandbox and signer: each from a field, nothing inferred.
            HStack(spacing: 5) {
                HStack(spacing: 5) {
                    Text(store.kind(of: p) ?? "Process")
                    if let owner {
                        Text("of").foregroundStyle(.secondary)
                        ProcessChip(proc: owner)
                    }
                    Text("·").foregroundStyle(.tertiary)
                    Text(p.sandboxed.map { $0 ? "sandboxed" : "not sandboxed" } ?? "sandbox ?")
                    Text("·").foregroundStyle(.tertiary)
                    Text(TrustVerdict(sign).short)
                }
                .truncationHelp([
                    (store.kind(of: p) ?? "Process") + (owner.map { " of \($0.name) (\($0.pid))" } ?? ""),
                    p.sandboxed.map { $0 ? "sandboxed" : "not sandboxed" } ?? "sandbox ?",
                    TrustVerdict(sign).short,
                ].joined(separator: " · "))
                Spacer(minLength: 8)
                // The four live figures; Usage has them with their history.
                Text(verbatim: live(p)).monospacedDigit().layoutPriority(1)
                    .help("CPU · Memory · Disk I/O · Power, over the last refresh")
            }
            .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            .frame(height: 20)
            // Badges only; the signals and Reveal are in the Process menu and the row's context menu.
            let b = badges(p)
            if !b.isEmpty {
                HStack(spacing: 6) {
                    ForEach(b, id: \.0) { Pill(text: $0.0, color: $0.1).help($0.2) }
                    Spacer(minLength: 0)
                }
                .frame(height: 22)
            }
        }
        .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
    }

    /// "CPU 3.7 % · 759 MB · 0 B/s · <0.01 W"
    private func live(_ p: ProcInfo) -> String {
        if exited { return "exited" }
        let r = p.rates
        let disk = r.flatMap { a in a.diskRead.flatMap { rd in a.diskWrite.map { rd + $0 } } }
        return ["CPU " + (p.cpuPercent.map { "\(Fmt.pct($0)) %" } ?? "—"),
                Fmt.bytes(p.footprint),
                disk.map(bytesPerSecFormat) ?? "—",
                r?.watts.map(wattsFormat) ?? "—"].joined(separator: " · ")
    }

    /// (text, colour, tooltip): states worth seeing at a glance, each read from a field.
    private func badges(_ p: ProcInfo) -> [(String, Color, String)] {
        var out: [(String, Color, String)] = []
        if exited { out.append(("exited", .red, "The process has exited; this is its last known state.")) }
        if let t = p.leftBehindText { out.append(("left behind", .orange, "Outlived \(t)")) }
        if p.isZombie { out.append(("zombie", .gray, "Exited, waiting for its parent to collect it")) }
        if p.stat == 4 { out.append(("stopped", .orange, "Stopped by a signal (SIGSTOP or similar)")) }
        if p.isTranslated { out.append(("Rosetta", .purple, "x86_64 code translated by Rosetta")) }
        if p.uid == 0 { out.append(("root", .orange, "Runs as root")) }
        if let s = sign {
            if s.unsigned { out.append(("unsigned", .red, "No code signature")) }
            else if s.valid == false { out.append(("invalid signature", .red, s.error ?? "The signature does not validate")) }
            else if s.isAdhoc { out.append(("ad hoc", .orange, "Signed without an identity (ad hoc)")) }
        }
        return out
    }
}

/// One line on who signed the code, from the signature's fields.
struct TrustVerdict {
    let short: String
    let long: String
    let color: Color

    init(_ s: SignInfo?) {
        guard let s else { short = "signature not read"; long = "The code signature hasn't been read yet."; color = .secondary; return }
        let hardened = s.staticFlags & 0x0001_0000 != 0
        let leaf = s.authority.first ?? ""
        let team = s.teamID.map { " (\($0))" } ?? ""
        func name(_ prefix: String) -> String? {
            guard leaf.hasPrefix(prefix) else { return nil }
            // "Developer ID Application: Mozilla Corporation (43AQ936H96)" → "Mozilla Corporation"
            var n = String(leaf.dropFirst(prefix.count))
            if let r = n.range(of: " (", options: .backwards), n.hasSuffix(")") { n = String(n[..<r.lowerBound]) }
            return n
        }
        if s.unsigned {
            (short, long, color) = ("unsigned", "Unsigned: no code signature.", .red)
        } else if s.valid == false {
            (short, long, color) = ("invalid signature", "The signature does not validate\(s.error.map { ": \($0)" } ?? ".")", .red)
        } else if s.isPlatform {
            (short, long, color) = ("Apple platform", "Apple platform binary, part of macOS.", .green)
        } else if s.isAppleSigned {
            (short, long, color) = ("Apple", "Signed by Apple (not a platform binary).", .green)
        } else if s.isAdhoc {
            (short, long, color) = ("ad hoc", "Ad hoc signed: a signature with no identity behind it.", .orange)
        } else if let n = name("Developer ID Application: ") {
            (short, long, color) = (n, "Developer ID: \(n)\(team)" + (hardened ? ", hardened runtime" : ", no hardened runtime"), .primary)
        } else if leaf.hasPrefix("Apple Mac OS Application Signing") {
            (short, long, color) = ("Mac App Store", "Mac App Store\(team)" + (hardened ? ", hardened runtime" : ""), .primary)
        } else if let n = name("Apple Development: ") ?? name("Mac Developer: ") {
            (short, long, color) = ("development build", "Development build signed by \(n)\(team): runs only on registered machines.", .orange)
        } else {
            let who = leaf.isEmpty ? (s.teamID ?? "unknown signer") : leaf
            (short, long, color) = (who, "Signed by \(who)" + (hardened ? ", hardened runtime" : ""), .primary)
        }
    }
}

// MARK: - Shared bits

/// One fact in an inspector grid: its label, its value, and where the value comes from (shown in the info
/// bubble on its label, not in the row).
struct FactRow {
    enum Via { case direct, helper }
    let label: String
    let value: KVValue
    /// The API, tool or calculation: "proc_pidpath", "csops CS_OPS_CDHASH", "derived: Smart tree".
    let source: String
    var via: Via = .direct
    var help: String? = nil
    var needs: String? = nil
    init(_ label: String, _ value: KVValue, _ source: String, via: Via = .direct, help: String? = nil, needs: String? = nil) {
        self.label = label; self.value = value; self.source = source; self.via = via; self.help = help; self.needs = needs
    }
    /// A row showing a column's value: the column's help, source and needs.
    init(_ label: String, _ value: KVValue, column id: String, via: Via = .direct) {
        let c = Column.byID[id]!
        self.init(label, value, c.source, via: via, help: c.help, needs: c.needs)
    }
    var info: FieldInfo { FieldInfo(help: help, source: source, via: via, needs: needs) }
}

/// A titled key/value grid that doesn't scroll by itself (tabs put several in one ScrollView).
struct FactGrid: View {
    let rows: [FactRow]
    init(rows: [FactRow]) {
        assert(rows.allSatisfy { !$0.source.isEmpty }, "FactRow without a source: \(rows.filter { $0.source.isEmpty }.map(\.label))")
        self.rows = rows
    }
    /// Rows without sources (the Mach-O window, which shows a file's own fields).
    init(rows: [(String, KVValue)]) { self.rows = rows.map { FactRow($0.0, $0.1, "") } }
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                GridRow(alignment: .firstTextBaseline) {
                    FieldName(label: r.label, info: r.source.isEmpty ? nil : r.info).gridColumnAlignment(.trailing)
                    KVValueView(value: r.value)
                }
            }
        }
    }
}

/// Chips that wrap onto as many lines as they need.
struct ChipFlow: View {
    let procs: [ProcInfo]
    var limit = 200
    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(procs.prefix(limit), id: \.key) { ProcessChip(proc: $0) }
        }
        if procs.count > limit { Text("… and \(procs.count - limit) more").foregroundStyle(.secondary).font(.caption) }
    }
}

/// Left-to-right, wrapping.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// A collapsible section with our own chevron (Section(isExpanded:) only shows its control on hover).
struct Collapsible<Content: View>: View {
    let title: String
    let startsOpen: Bool
    @ViewBuilder let content: () -> Content
    @State private var open: Bool?

    var body: some View {
        let isOpen = open ?? startsOpen
        VStack(alignment: .leading, spacing: 6) {
            Button { open = !isOpen } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0)).frame(width: 10)
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isOpen ? "expanded" : "collapsed")
            if isOpen { content().padding(.leading, 14) }
        }
    }
}

// MARK: - Info

/// What the code is and how this instance runs: the Identity and Execution columns, one row each, and the
/// command line. Live figures are in the header and on Usage; who started it is on Launch.
struct InfoTab: View {
    @Environment(Store.self) var store
    let proc: ProcInfo
    var exited = false
    let sign: SignInfo?
    @State private var cwd: (key: String, path: String?)?
    /// Arguments and environment, for the process `key` (nil: not readable).
    @State private var args: (key: String, value: Native.ArgsEnv?)?

    var body: some View {
        let p = proc
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Card(title: Column.Section.identity.title) { FactGrid(rows: identity(p)) }
                command(p)
                Card(title: Column.Section.execution.title) { FactGrid(rows: execution(p)) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Nice is an optional read: make it while this tab shows it.
        .readsWhileShown([.nice, .suspended])
        // Re-read on an exec, on a manual refresh, and when the helper comes or goes.
        .task(id: "\(p.codeKey)|\(store.fullRefreshGen)|\(exited)|\(store.helperState.isRunning)") {
            guard !exited else { return }
            let pid = p.pid, start = p.start, key = p.key
            let helper = store.helperState.isRunning
            let (c, a) = await Task.detached { () -> (String?, Native.ArgsEnv?) in
                var c = Native.cwd(pid)
                var a = Native.argsEnv(pid)
                // The helper (root) only for what couldn't be read locally: another user's process.
                if helper, c == nil || a == nil, let r = HelperClient.shared.argsEnv(pid) {
                    c = c ?? r.cwd
                    a = a ?? Native.ArgsEnv(execPath: r.execPath, args: r.args, env: r.env)
                }
                return Native.isSame(pid, start: start) ? (c, a) : (nil, nil)
            }.value
            guard !Task.isCancelled else { return }
            cwd = (key, c)
            args = (key, a)
        }
    }

    /// The arguments, open, one per line; the environment collapsed.
    @ViewBuilder private func command(_ p: ProcInfo) -> some View {
        let loaded = args?.key == p.key ? args : nil
        Card(title: "Command", trailing: loaded?.value.map { "\($0.args.count) argument\($0.args.count == 1 ? "" : "s")" }) {
            if let a = loaded?.value {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(a.args.enumerated()), id: \.offset) { i, s in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("[\(i)]").foregroundStyle(.secondary).monospacedDigit()
                            Text(s).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            if let path = Reveal.path(in: s) { RevealButton(path: path) }
                        }
                    }
                }
                Collapsible(title: "Environment (\(a.env.count))", startsOpen: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(a.env.sorted(), id: \.self) { Text($0).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    }
                }
            } else {
                Text(exited && loaded == nil ? "Exited." : loaded != nil ? "? (another user's process: needs the helper)" : "Reading…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func col(_ id: String, _ p: ProcInfo) -> String { Column.byID[id]!.value(p, store).display }

    /// The Identity columns (name and pid are in the header, the command line has its own card).

    private func identity(_ p: ProcInfo) -> [FactRow] {
        var rows = [FactRow("Path", p.path.map { .path($0) } ?? .text("— (\(p.comm))"), column: "path")]
        if let b = store.bundleID(of: p) {
            let version = p.bundlePath.flatMap(BundleInfo.version)
            rows.append(FactRow("Bundle ID", .text(b + (version.map { "  \($0)" } ?? "")), column: "bundleID"))
        }
        rows += [
            FactRow("Kind", .text(store.kind(of: p) ?? "—"), column: "kind"),
            FactRow("Architecture", .text(col("arch", p)), column: "arch"),
        ]
        if let e = p.extensionPoint { rows.append(FactRow("Extension point", .text("\(ExtensionInfo.title(e))  (\(e))"), column: "extPoint")) }
        return rows
    }

    /// The Execution columns, plus the working directory and scheduling.
    private func execution(_ p: ProcInfo) -> [FactRow] {
        var rows = [
            FactRow("User", .text("\(p.user) (uid \(p.uid))"), column: "user"),
            FactRow("Started", .text(Fmt.shownStart(p.start) == p.start
                ? "\(Fmt.date.string(from: p.start))  (\(Fmt.age(p.start)) ago)"
                : "at boot, before the clock was set (\(Fmt.date.string(from: Fmt.shownStart(p.start))))"), column: "started"),
            FactRow("State", .text(col("state", p).ifEmpty("live")), column: "state"),
        ]
        // Cheap and unprivileged, so read here rather than waiting for the column's next refresh.
        if let s = p.idleExit ?? IdleExitState.read(p.pid) {
            rows.append(FactRow("Idle exit (dirty tracking)", .text(s.contains(.tracked) ? s.long : "not tracked"), column: "idleExit"))
        }
        rows += [
            FactRow("Working dir", (cwd?.key == p.key ? cwd?.path : nil).map { .path($0) } ?? .text("—"), "proc_pidinfo PROC_PIDVNODEPATHINFO"),
            FactRow("TTY", .text(p.tty.map(SmartTree.ttyName) ?? "—"), column: "tty"),
            FactRow("Process group", .text(p.pgid == p.pid ? "\(p.pgid) (leader)" : "\(p.pgid)"), column: "pgid"),
            FactRow("Priority", .text(col("priority", p)), column: "priority"),
            FactRow("Nice", .text(col("nice", p)), column: "nice", via: p.viaHelper && p.uid != getuid() ? .helper : .direct),
        ]
        return rows
    }
}

extension View {
    /// Makes the snapshot read `r` (an optional read, as a shown column would) while this view is on screen.
    func readsWhileShown(_ r: ExtraReads) -> some View {
        modifier(ReadsWhileShown(reads: r))
    }
}

private struct ReadsWhileShown: ViewModifier {
    @Environment(Store.self) var store
    let reads: ExtraReads
    func body(content: Content) -> some View {
        content
            .onAppear { store.addViewer(reads) }
            .onDisappear { store.removeViewer(reads) }
    }
}

// MARK: - Sparklines

/// A line of the last `History.capacity` values, newest at the right edge. Rates are scaled from zero to
/// their maximum; a level such as memory (`fromZero` false) between its minimum and maximum, or it would
/// be a flat line at the top. Gaps (no reading for that refresh) break the line. Hovering marks the
/// nearest sample and shows its value (through `format`) and how long ago it was read.
struct Sparkline: View {
    let values: [Double?]
    var fromZero = true
    var color: Color = .accentColor
    var format: ((Double) -> String)?
    @Environment(Store.self) private var store: Store?
    @State private var hover: CGPoint?

    private func step(_ width: CGFloat) -> CGFloat { width / CGFloat(History.capacity - 1) }
    private func x(_ i: Int, _ width: CGFloat) -> CGFloat { width - CGFloat(values.count - 1 - i) * step(width) }
    /// The sample under `x`, or nil left of the oldest one.
    private func index(at x: CGFloat, _ width: CGFloat) -> Int? {
        guard !values.isEmpty, width > 0 else { return nil }
        let back = Int(((width - x) / step(width)).rounded())
        let i = values.count - 1 - max(back, 0)
        return i >= 0 ? i : nil
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let hovered = hover.flatMap { index(at: $0.x, size.width) }
            Canvas { ctx, size in
                let known = values.compactMap { $0 }
                let bottom = fromZero ? 0 : (known.min() ?? 0)
                let top = (known.max() ?? 0) - bottom
                var line = Path(), area = Path()
                var runStart: CGPoint?, last: CGPoint?, mark: CGPoint?
                func close() {
                    if let s = runStart, let l = last {
                        area.addLine(to: CGPoint(x: l.x, y: size.height))
                        area.addLine(to: CGPoint(x: s.x, y: size.height))
                        area.closeSubpath()
                    }
                    runStart = nil; last = nil
                }
                for (i, v) in values.enumerated() {
                    guard let v else { close(); continue }
                    // A flat level (top 0) sits mid-height; a flat zero rate sits on the baseline.
                    let y = top > 0 ? size.height - CGFloat((v - bottom) / top) * (size.height - 1) - 0.5
                                    : (fromZero ? size.height - 0.5 : size.height / 2)
                    let pt = CGPoint(x: x(i, size.width), y: y)
                    if i == hovered { mark = pt }
                    if runStart == nil { line.move(to: pt); area.move(to: pt); runStart = pt } else { line.addLine(to: pt); area.addLine(to: pt) }
                    last = pt
                }
                close()
                ctx.fill(area, with: .color(color.opacity(0.15)))
                ctx.stroke(line, with: .color(color), lineWidth: 1.2)
                if let hovered {
                    let hx = x(hovered, size.width)
                    ctx.stroke(Path { $0.move(to: CGPoint(x: hx, y: 0)); $0.addLine(to: CGPoint(x: hx, y: size.height)) },
                               with: .color(.secondary.opacity(0.6)), lineWidth: 1)
                    if let m = mark {
                        ctx.fill(Path(ellipseIn: CGRect(x: m.x - 2.5, y: m.y - 2.5, width: 5, height: 5)), with: .color(color))
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let p) = phase { hover = p } else { hover = nil }
            }
            .overlay {
                // A fixed frame, so the label can sit outside it (a ZStack would grow to hold it, and a bare
                // overlay ignores the label's alignment guides).
                if let hovered {
                    label(hovered, at: x(hovered, size.width), width: size.width)
                        .frame(width: size.width, height: size.height, alignment: .topLeading)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// The hovered sample's value and age, centred above the chart on the sample and kept inside its width.
    private func label(_ i: Int, at x: CGFloat, width: CGFloat) -> some View {
        let value = values[i].map { format?($0) ?? String(format: "%.3g", $0) } ?? "no reading"
        let ago = Double(values.count - 1 - i) * (store?.interval ?? 2)
        let s = Int(ago.rounded())
        let when = s == 0 ? "now" : s < 60 ? "\(s) s ago" : s % 60 == 0 ? "\(s / 60) min ago" : "\(s / 60) min \(s % 60) s ago"
        return Text(verbatim: "\(value)  ·  \(when)")
            .font(.caption).monospacedDigit()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
            .fixedSize()
            .alignmentGuide(.leading) { d in -min(max(x - d.width / 2, 0), max(width - d.width, 0)) }
            .alignmentGuide(.top) { d in d.height + 3 }
            .allowsHitTesting(false)
    }
}

/// A stat tile with a sparkline under the value; the tooltip gives the range shown.
struct SparkTile: View {
    let title: String
    let value: String
    let values: [Double?]
    var fromZero = true
    let format: (Double) -> String

    var body: some View {
        let known = values.compactMap { $0 }
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: value).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
            Sparkline(values: values, fromZero: fromZero, format: format).frame(height: 24)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(width: 150, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .help(known.isEmpty ? "No history yet"
              : "Last \(values.count) refreshes: \(format(known.min()!)) to \(format(known.max()!)); the line spans "
                + (fromZero ? "zero to the maximum." : "the minimum to the maximum."))
    }
}

// MARK: - Usage

/// What the process is costing: each value now (over the last refresh) beside its total since start.
struct UsageTab: View {
    @Environment(Store.self) var store
    let proc: ProcInfo
    var exited = false
    @State private var extra: (key: String, files: Int?, qos: [(String, UInt64)]?, assertions: [(String, String)])?

    private typealias Row = (String, String, String)   // metric, now, since start

    var body: some View {
        let p = proc, r = p.rates, c = p.counters
        let h = store.history[p.key]
        let e = extra?.key == p.key ? extra : nil
        // The task metrics came from the helper (root) when the app couldn't read them itself.
        let via: FactRow.Via = p.viaHelper ? .helper : .direct
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !p.isInspectable {
                    Text("Task info isn't readable (owned by \(p.user)). Install the privileged helper to read it.")
                        .foregroundStyle(.secondary)
                }
                Self.section("CPU", "cpu", h?.cpu, via: via, format: { "\(Fmt.pct($0)) %" }, rows: [
                    ("CPU", r?.cpuPercent.map { "\(Fmt.pct($0)) %" } ?? "—", Fmt.secs(p.cpuNanos)),
                    ("P-core share", r?.pCoreShare.map { String(format: "%.0f %%", $0) } ?? "—",
                     c?.pCoreNanos.map { pc in Fmt.secs(pc) + (p.cpuNanos.flatMap { $0 > 0 ? String(format: " (%.0f %%)", Double(pc) / Double($0) * 100) : nil } ?? "") } ?? "—"),
                    ("Runnable wait", r?.waitingPercent.map { String(format: "%.1f %%", $0) } ?? "—", Fmt.secs(c?.waitingNanos)),
                    // How many threads exist. (No "running" count: pti_numrunning is one instant, and for a
                    // process at a few percent CPU it reads 0 almost every time: 95.7 % of 2,000 reads for
                    // Firefox at 2 %.)
                    ("Threads", p.threads.map(String.init) ?? "—", ""),
                    ("Instr/cycle", r?.ipc.map { String(format: "%.2f", $0) } ?? "—",
                     c.flatMap { c in c.instructions.flatMap { i in c.cycles.flatMap { $0 > 0 ? String(format: "%.2f", Double(i) / Double($0)) : nil } } } ?? "—"),
                    ("Context switches", rate(r?.contextSwitches), Fmt.count(c?.contextSwitches)),
                ] + qosRows(p) + voucherCPURows(p))
                if r?.gpuPercent != nil || p.gpuNanos != nil {
                    Self.section("GPU", "cpu.fill", nil, format: { _ in "" }, rows: [
                        ("% GPU", r?.gpuPercent.map { $0 < 0.05 ? "0" : String(format: "%.1f %%", $0) } ?? "—", Fmt.secs(p.gpuNanos)),
                    ])
                }
                Self.section("Memory", "memorychip", h?.memory, fromZero: false, via: via, format: { Fmt.bytes(UInt64($0)) }, rows: [
                    ("Memory", Fmt.bytes(p.footprint), c?.peakFootprint.map { "peak " + Fmt.bytes($0) } ?? "—"),
                    ("Resident", Fmt.bytes(p.rss), ""),
                    ("Virtual", Fmt.bytes(p.virt), ""),
                    ("Compressed", Fmt.bytes(p.compressed), ""),
                    ("Neural Engine", Fmt.bytes(c?.neuralFootprint), ""),
                    ("Page faults", rate(r?.faults), c.map { "\(Fmt.count($0.faults)) (\(Fmt.count($0.cowFaults)) copy-on-write)" } ?? "—"),
                    ("Page-ins", rate(r?.pageins), Fmt.count(c?.pageins)),
                ] + jetsamRows(p))
                TaskMemoryCard(proc: p, exited: exited)
                Self.section("Disk", "internaldrive", h?.disk, via: via, format: bytesPerSecFormat, rows: [
                    ("Read", r?.diskRead.map(bytesPerSecFormat) ?? "—", Fmt.bytes(p.diskRead)),
                    ("Written", r?.diskWrite.map(bytesPerSecFormat) ?? "—", Fmt.bytes(p.diskWrite)),
                    ("Logical writes", r?.logicalWrites.map(bytesPerSecFormat) ?? "—", Fmt.bytes(c?.logicalWrites)),
                ])
                Self.networkSection(h?.network, inRate: p.netIn, outRate: p.netOut,
                                    inTotal: p.netInTotal.map { Double($0) }, outTotal: p.netOutTotal.map { Double($0) },
                                    start: p.start)
                Self.section("IPC", "arrow.left.arrow.right", nil, via: via, format: { _ in "" }, rows: [
                    ("BSD system calls", rate(r?.unixSyscalls), Fmt.count(c?.unixSyscalls)),
                    ("Mach system calls", rate(r?.machSyscalls), Fmt.count(c?.machSyscalls)),
                    ("Mach messages sent", rate(r?.machMsgsSent), Fmt.count(c?.machMsgsSent)),
                    ("Mach messages received", rate(r?.machMsgsReceived), Fmt.count(c?.machMsgsReceived)),
                    ("Open files", e?.files.map { Fmt.count($0) } ?? "—", ""),
                ])
                Self.section("Energy", "bolt", h?.power, via: via, format: wattsFormat, rows: [
                    ("Power", r?.watts.map(wattsFormat) ?? "—", p.energyNJ.map { String(format: "%.2f J", Double($0) / 1e9) } ?? "—"),
                    ("Wakeups", rate(r?.wakeups), Fmt.count(p.wakeups)),
                ] + voucherEnergyRows(p) + assertionRows(e))
                if hasVouchers(p) { VoucherFlowsView(pids: [p.pid], subject: "this process").id(p.key) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .readsNetwork()
        .readsWhileShown([.gpu, .compressed])
        .onAppear { store.jetsamViewers += 1 }
        .onDisappear { store.jetsamViewers -= 1 }
        // Each refresh: these are read for the shown process only, not every process.
        .task(id: "\(p.key)|\(store.dataGen)|\(exited)") {
            guard !exited else { return }
            let pid = p.pid, start = p.start, key = p.key
            let got = await Task.detached { () -> (Int?, [(String, UInt64)]?, [(String, String)])? in
                let v = (Native.openFileCount(pid), Native.cpuTimeByQoS(pid), Native.powerAssertions(pid))
                return Native.isSame(pid, start: start) ? v : nil
            }.value
            guard !Task.isCancelled, let got else { return }
            extra = (key, got.0, got.1, got.2)
        }
    }

    /// Mach-voucher (BANK) accounting (rusage ri_billed/serviced_system_time and _energy): CPU and energy this
    /// process ran on behalf of others, and others on its behalf. Rows only when any is non-zero, which is
    /// mainly service daemons and the processes they serve.
    private func hasVouchers(_ p: ProcInfo) -> Bool {
        let c = p.counters
        return [c?.servicedCpuNanos, c?.billedCpuNanos, c?.servicedEnergyNJ, c?.billedEnergyNJ].contains { ($0 ?? 0) > 0 }
    }
    private func voucherCPURows(_ p: ProcInfo) -> [Row] {
        guard hasVouchers(p) else { return [] }
        return [("CPU for others", "", Fmt.secs(p.counters?.servicedCpuNanos)),
                ("CPU by others", "", Fmt.secs(p.counters?.billedCpuNanos))]
    }
    private func voucherEnergyRows(_ p: ProcInfo) -> [Row] {
        guard hasVouchers(p) else { return [] }
        let joules: (UInt64?) -> String = { $0.map { String(format: "%.2f J", Double($0) / 1e9) } ?? "—" }
        return [("Energy for others", "", joules(p.counters?.servicedEnergyNJ)),
                ("Energy by others", "", joules(p.counters?.billedEnergyNJ))]
    }
    private func assertionRows(_ e: (key: String, files: Int?, qos: [(String, UInt64)]?, assertions: [(String, String)])?) -> [Row] {
        guard let e else { return [("Power assertions", "—", "")] }
        if e.assertions.isEmpty { return [("Power assertions", "none", "")] }
        return e.assertions.map { ("Power assertion", $0.0, $0.1) }
    }

    /// CPU time by quality-of-service class (rusage ri_cpu_time_qos_*), indented under CPU. Read with the rest
    /// of the counters each refresh, so "now" covers the same interval as CPU %.
    private func qosRows(_ p: ProcInfo) -> [Row] {
        guard let q = p.counters?.qosNanos else { return [] }
        let total = q.reduce(0, +)
        let now = p.rates?.qosPercent
        return q.indices.filter { q[$0] > 0 }.map { i in
            let share = total > 0 ? String(format: " (%.0f %%)", Double(q[i]) / Double(total) * 100) : ""
            return ("  QoS " + Counters.qosClasses[i], now.map { "\(Fmt.pct($0[i])) %" } ?? "—", Fmt.secs(q[i]) + share)
        }
    }

    private func rate(_ v: Double?) -> String { v.map(perSecFormat) ?? "—" }

    /// Received and sent, now and in total; the group page passes sums. `start`: the process's start (the
    /// group's earliest member's). One started before the reader (NetSampler.since) may have closed sockets
    /// before then, so its total is a lower bound, shown as "≥"; with nothing seen, "none since" the reader's start.
    static func networkSection(_ spark: [Double?]?, inRate: Double?, outRate: Double?, inTotal: Double?, outTotal: Double?,
                               start: Date?, group: Bool = false) -> some View {
        let since = NetSampler.shared.since
        let lowerBound = since.flatMap { s in start.map { $0 < s } } ?? false
        let sinceText = since.map { $0.formatted(Calendar.current.isDateInToday($0) ? .dateTime.hour().minute() : .dateTime.month().day().hour().minute()) } ?? ""
        let total: (Double?) -> String = { v in
            guard let v else { return "—" }
            if v == 0 { return lowerBound ? "none since \(sinceText)" : "none" }
            return (lowerBound ? "≥ " : "") + Fmt.bytes(UInt64(v))
        }
        return section("Network", "network", spark, group: group, format: bytesPerSecFormat, rows: [
            ("Received", inRate.map(bytesPerSecFormat) ?? "—", total(inTotal)),
            ("Sent", outRate.map(bytesPerSecFormat) ?? "—", total(outTotal)),
        ])
        .help("TCP and UDP traffic, loopback included, from the kernel's per-socket counts (the ones nettop shows), read every 2 s since the app started"
              + (since.map { " (\($0.formatted(date: .abbreviated, time: .standard)))" } ?? "")
              + ". \"Now\" is the last 2 s, connections that closed in them included. \"Since start\" adds up every socket seen, over each socket's whole life"
              + (lowerBound ? ". \"≥\" and \"since\": the process started before the app, so sockets it closed before then aren't counted." : ".")
              + (NetSampler.shared.seesEverything ? "" : " Without the helper, only your own processes' sockets are counted, and not connections made through Network.framework's own stack (QUIC and most app traffic): the kernel shows the rest only to root."))
    }

    /// Jetsam band and memory limits (root only: the helper's), under "Now".
    private func jetsamRows(_ p: ProcInfo) -> [(String, String, String)] {
        guard let j = p.jetsam else {
            return [("Memory limit", "?", store.helperState.isRunning ? "" : "needs the helper")]
        }
        let mb: (Int32?) -> String = { $0.map { Fmt.bytes(UInt64($0) << 20) } ?? "none" }
        var used = ""
        if let b = j.limitBytes, b > 0, let f = p.footprint { used = String(format: "footprint is %.0f %% of it", Double(f) / Double(b) * 100) }
        var rows = [("Memory limit", mb(j.limitMB), used)]
        if j.limitsDiffer { rows.append(("  active / inactive", "", "\(mb(j.activeLimitMB)) / \(mb(j.inactiveLimitMB))")) }
        rows.append(("Memory-kill band (jetsam)", String(j.band), j.band == 0 ? "idle band: killed first" : ""))
        return rows
    }
    private static let metricWidth: CGFloat = 180, nowWidth: CGFloat = 90, totalWidth: CGFloat = 240

    /// One section: metric, now and since start in fixed-width columns, and its sparkline. The group
    /// inspector uses it too, so both pages line up the same way.
    /// Where each Usage row comes from, by its name (one name per quantity, so the name is the key).
    static let sources: [String: String] = [
        "CPU": "proc_taskinfo pti_total_user + pti_total_system",
        "P-core share": "rusage ri_user_ptime + ri_system_ptime",
        "Runnable wait": "rusage ri_runnable_time",
        "Threads": "proc_taskinfo pti_threadnum",
        "Instr/cycle": "rusage ri_instructions ÷ ri_cycles",
        "Context switches": "proc_taskinfo pti_csw",
        "QoS": "rusage ri_cpu_time_qos_*",
        "CPU for others": "rusage ri_serviced_system_time",
        "CPU by others": "rusage ri_billed_system_time",
        "% GPU": "IORegistry accelerator clients",
        "Memory": "rusage ri_phys_footprint",
        "Resident": "proc_taskinfo pti_resident_size",
        "Virtual": "proc_taskinfo pti_virtual_size",
        "Compressed": "task_info TASK_VM_INFO",
        "Neural Engine": "rusage ri_neural_footprint",
        "Page faults": "proc_taskinfo pti_faults, pti_cow_faults",
        "Page-ins": "proc_taskinfo pti_pageins",
        "Memory limit": "memorystatus_control GET_MEMLIMIT_PROPERTIES",
        "active / inactive": "memorystatus_control GET_MEMLIMIT_PROPERTIES",
        "Memory-kill band (jetsam)": "memorystatus_control GET_PRIORITY_LIST",
        "Read": "rusage ri_diskio_bytesread",
        "Written": "rusage ri_diskio_byteswritten",
        "Logical writes": "rusage ri_logical_writes",
        "Received": "NetworkStatistics per-socket counts",
        "Sent": "NetworkStatistics per-socket counts",
        "BSD system calls": "proc_taskinfo pti_syscalls_unix",
        "Mach system calls": "proc_taskinfo pti_syscalls_mach",
        "Mach messages sent": "proc_taskinfo pti_messages_sent",
        "Mach messages received": "proc_taskinfo pti_messages_received",
        "Open files": "proc_pidinfo PROC_PIDLISTFDS",
        "Power": "rusage ri_energy_nj",
        "Wakeups": "rusage ri_pkg_idle_wkups + ri_interrupt_wkups",
        "Energy for others": "rusage ri_serviced_energy",
        "Energy by others": "rusage ri_billed_energy",
        "Power assertion": "IOPMCopyAssertionsByProcess",
        "Power assertions": "IOPMCopyAssertionsByProcess",
    ]
    /// A Usage row's info bubble: the column of the same name's help where there is one.
    static func info(_ label: String, group: Bool, via: FactRow.Via) -> FieldInfo {
        let key = label.trimmingCharacters(in: .whitespaces)
        let col = Column.all.first { $0.title == key }
        return FieldInfo(help: col?.help, source: source(label, group: group), via: via, needs: col?.needs)
    }

    static func source(_ label: String, group: Bool) -> String {
        let key = label.trimmingCharacters(in: .whitespaces)
        let s = sources[key] ?? sources[key.hasPrefix("QoS ") ? "QoS" : key] ?? ""
        assert(!s.isEmpty, "Usage row without a source: \(label)")
        return group && !s.isEmpty ? "Σ " + s : s
    }

    static func section(_ title: String, _ symbol: String, _ spark: [Double?]?, fromZero: Bool = true, group: Bool = false,
                        via: FactRow.Via = .direct,
                        format: @escaping (Double) -> String, rows: [(String, String, String)]) -> some View {
        Card(title: title, systemImage: symbol) {
            VStack(alignment: .leading, spacing: 6) {
                // The history across the card, so the rows below keep room for their sources.
                if let spark {
                    let known = spark.compactMap { $0 }
                    Sparkline(values: spark, fromZero: fromZero, format: format).frame(maxWidth: .infinity).frame(height: 32)
                        .help(known.isEmpty ? "No history yet"
                              : "Last \(spark.count) refreshes: \(format(known.min()!)) to \(format(known.max()!)); the line spans "
                                + (fromZero ? "zero to the maximum." : "the minimum to the maximum."))
                }
                // Fixed column widths, so every section's columns line up with the others'.
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        Text("").frame(width: Self.metricWidth, alignment: .leading)
                        Text("Now").font(.caption).foregroundStyle(.secondary).frame(width: Self.nowWidth, alignment: .trailing)
                        Text("Since start").font(.caption).foregroundStyle(.secondary).frame(width: Self.totalWidth, alignment: .trailing)
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            FieldName(label: row.0, info: info(row.0, group: group, via: via)).frame(width: Self.metricWidth, alignment: .leading)
                            Text(row.1).monospacedDigit().textSelection(.enabled).frame(width: Self.nowWidth, alignment: .trailing)
                            Text(row.2).monospacedDigit().textSelection(.enabled).frame(width: Self.totalWidth, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

}

/// While shown, the store reads network rates (Store.networkViewers), as it does for the network columns.
private struct ReadsNetwork: ViewModifier {
    @Environment(Store.self) var store
    func body(content: Content) -> some View {
        content
            .onAppear { store.networkViewers += 1; NetSampler.shared.want(true) }   // starts now, not at the next refresh
            .onDisappear { store.networkViewers -= 1 }
    }
}

extension View {
    func readsNetwork() -> some View { modifier(ReadsNetwork()) }
}

// MARK: - Launch

/// Who it belongs to and how it was started: lineage, mechanism, then each registry's record, then the
/// processes related to it.
struct LaunchTab: View {
    @Environment(Store.self) var store
    let proc: ProcInfo
    var exited = false
    @State private var loadedKey: String?
    @State private var job: (title: String, text: String)?
    @State private var procinfo: (title: String, text: String)?
    @State private var envAttr: EnvAttribution?
    /// launchd's attribution record for the job: nil until looked up, then the result (or none).
    @State private var launchdAttr: (key: String, result: LaunchdAttribution.Result?)?

    var body: some View {
        let p = proc
        let ls = store.lsApps.first { $0.pid == p.pid }
        let jobNodes = job.map { LaunchctlParser.parse($0.text) } ?? []
        let jobFacts = Dictionary(jobNodes.map { ($0.key, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let item = store.btmLoaded ? btmItem(p) : nil
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                lineage(p, ls: ls)
                    // launchd's attribution record costs ~2 s (see LaunchdAttribution): once per job shown, not per refresh.
                    .task(id: "\(p.key)|\(p.launchdLabel ?? "")") {
                        guard !exited, p.ppid == 1, let label = p.launchdLabel, !label.hasPrefix("application."),
                              launchdAttr?.key != p.key + label else { return }
                        let key = p.key + label
                        let r = await Task.detached { LaunchdAttribution.lookup(label: label) }.value
                        guard !Task.isCancelled else { return }
                        launchdAttr = (key, r)
                    }
                mechanism(p, ls: ls, jobFacts: jobFacts)
                if p.launchdLabel != nil || p.domainOwner != nil { launchdJob(p, nodes: jobNodes, top: jobFacts) }
                if let ls { launchServices(ls) }
                if let item { backgroundItem(item) }
                if let e = p.extensionPoint {
                    Card(title: "Extension", systemImage: "puzzlepiece.extension") {
                        FactGrid(rows: [
                            FactRow("Extension point", .text("\(ExtensionInfo.title(e))  (\(e))"), "Info.plist NSExtensionPointIdentifier"),
                            FactRow("Containing app", .text(p.containingAppName ?? "—"), "derived: enclosing .app bundle"),
                        ])
                    }
                }
                relations(p)
                unregistered(p, ls: ls, item: item)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Reload when the process registers with LaunchServices or launchd, execs, or on a manual refresh.
        .task(id: "\(p.codeKey)|\(p.launchdLabel ?? "")|\(store.fullRefreshGen)|\(exited)|\(store.helperState.isRunning)") {
            guard !exited else { return }   // keep what was shown; the pid may be someone else's now
            if loadedKey != p.key { job = nil; procinfo = nil; envAttr = nil }
            let label = p.launchdLabel, pid = p.pid, key = p.key, launchdChild = p.ppid == 1
            let helper = store.helperState.isRunning
            let (j, pi, ea) = await Task.detached { () -> ((String, String)?, (String, String)?, EnvAttribution?) in
                let j = label.map { ("launchctl print \($0)", Launchd.printJob($0)) }
                let pi = helper ? ("launchctl procinfo \(pid) (as root via helper)",
                                   HelperClient.shared.run(.launchctlProcinfo, pid: pid) ?? "helper did not answer") : nil
                // Only for launchd's children: for any other process the parent chain already says who started it.
                let ea = launchdChild ? EnvAttribution.read(pid) : nil
                return (j, pi, ea)
            }.value
            guard !Task.isCancelled else { return }
            job = j; procinfo = pi; envAttr = ea; loadedKey = key
        }
    }

    /// A label and its value, for cards whose values are views rather than text.
    private struct Row<V: View>: View {
        let label: String
        var source = ""
        @ViewBuilder let value: V
        init(_ label: String, source: String = "", @ViewBuilder value: () -> V) {
            self.label = label; self.source = source; self.value = value()
        }
        var body: some View {
            GridRow(alignment: .firstTextBaseline) {
                FieldName(label: label, info: source.isEmpty ? nil : FieldInfo(source: source)).gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 2) { value }
            }
        }
    }

    // Lineage: who it belongs to.
    @ViewBuilder private func lineage(_ p: ProcInfo, ls: LSApp?) -> some View {
        let record = LaunchWatcher.shared.record(pid: p.pid, start: p.start)
        let parentApp = ls?.parentASNID.flatMap { id in store.lsApps.first { $0.asn == id } }
        let env = p.ppid == 1 ? envAttr : nil
        Card(title: Column.Section.lineage.title, systemImage: "arrow.up.to.line") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                Row("Parent chain", source: "kinfo_proc e_ppid") {
                    // Root first: kernel_task › launchd › … › this process.
                    FlowLayout(spacing: 4) {
                        ForEach(ancestors(p).reversed(), id: \.key) { a in
                            ProcessChip(proc: a)
                            Text("›").foregroundStyle(.tertiary)
                        }
                        Text(p.name).fontWeight(.medium)
                    }
                }
                Row("Responsible", source: "responsibility_get_pid_responsible_for_pid") {
                    if let rp = store.responsibleProcess(p) { ProcessChip(proc: rp) }
                    else { Text(store.responsibleDescription(p)).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                if let r = record, !r.launcher.isEmpty {
                    Row("Requested by", source: "CoreServicesUIAgent's launch log at \(Fmt.date.string(from: r.at)), launcher pid \(r.launcher[0].pid); parents read when the request came in") {
                        FlowLayout(spacing: 4) {
                            ForEach(Array(r.launcher.enumerated()), id: \.offset) { i, hop in
                                if i > 0 { Text("←").foregroundStyle(.tertiary) }
                                hopChip(hop)
                            }
                        }
                        sourceLine("CoreServicesUIAgent's launch log at \(Fmt.date.string(from: r.at)): launcher pid \(r.launcher[0].pid)"
                                   + (r.launcherVersion.map { ", pid version \($0)" } ?? "") + "; its parents read the moment the request came in",
                                   .exact)
                    }
                }
                if let parentApp, let pid = parentApp.pid, let host = store.procs[pid] {
                    Row("Parent app", source: "LaunchServices parentASN \(parentApp.asn)") {
                        ProcessChip(proc: host)
                        sourceLine("LaunchServices parentASN \(parentApp.asn)", .exact)
                    }
                }
                if p.ppid == 1, let label = p.launchdLabel, !label.hasPrefix("application.") {
                    Row("Loaded on behalf of", source: "launchd's attribution record for \(label), as launchd logs it when launchservicesd asks") { launchdAttribution(label, p) }
                }
                if let e = env, e.fromShell {
                    Row("Inherited environment", source: "the environment it inherited (CLAUDE_PID, CLAUDE_CODE_SESSION_ID, TERM_PROGRAM, PWD)") { envRows(e, p) }
                }
            }
        }
    }

    // Mechanism: how it was started.
    @ViewBuilder private func mechanism(_ p: ProcInfo, ls: LSApp?, jobFacts: [String: String]) -> some View {
        let record = LaunchWatcher.shared.record(pid: p.pid, start: p.start)
        let parentApp = ls?.parentASNID.flatMap { id in store.lsApps.first { $0.asn == id } }
        let env = p.ppid == 1 ? envAttr : nil
        let mechanisms = LaunchMechanism.describe(ppid: p.ppid, parentName: store.procs[p.ppid]?.name, record: record,
                                                  parentASN: ls?.parentASN ?? parentApp?.name, env: env, launchdLabel: p.launchdLabel,
                                                  job: jobFacts)
        Card(title: "Mechanism", systemImage: "bolt.horizontal") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(mechanisms, id: \.self) { m in
                    Row("How", source: m.source) {
                        Text(verbatim: m.how).fontWeight(.medium)
                        if let d = m.detail { Text(verbatim: d).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        sourceLine(m.source, m.confidence)
                    }
                }
                if mechanisms.isEmpty {
                    Row("How") { Text("—").foregroundStyle(.secondary).help("Nothing records how this process was started.") }
                }
                if let reason = jobFacts["immediate reason"] {
                    Row("Started because", source: "launchctl print: immediate reason") { Text(Self.reasonText(reason)).textSelection(.enabled) }
                }
            }
            if p.ppid == 1, record == nil {
                Text(LaunchWatcher.shared.unavailable
                     ?? LaunchWatcher.shared.since.map { "Launch log traced from \(Fmt.date.string(from: $0)); this launch wasn't seen." }
                     ?? "Launch tracing isn't running.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    // The launchd job: its record, then the raw launchctl output.
    @ViewBuilder private func launchdJob(_ p: ProcInfo, nodes: [KVNode], top: [String: String]) -> some View {
        Card(title: "launchd job", systemImage: "gearshape.2") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                if let label = p.launchdLabel {
                    Row("Label", source: "launchctl list") { Text(label).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                    Row("Domain", source: "launchctl print") { Text(p.launchdDomain ?? top["domain"] ?? "—") }
                    Row("Type", source: "launchctl print") { Text(top["type"] ?? "—") }
                    Row("Properties", source: "launchctl print") { Text(top["properties"] ?? "—").textSelection(.enabled) }
                    Row("Runs / last exit", source: "launchctl print") { Text("\(top["runs"] ?? "—") / \(top["last exit code"] ?? "—")") }
                    if let plist = top["path"], !plist.isEmpty { Row("Plist", source: "launchctl print: path") { PathText(path: plist) } }
                    // Set by launchd only for jobs an app registered through SMAppService.
                    if let bid = top["parent bundle identifier"], !bid.isEmpty {
                        Row("Registered by (SMAppService)", source: "launchctl print: parent bundle identifier") {
                            HStack(spacing: 6) {
                                if let a = store.lsApps.first(where: { $0.bundleID == bid && $0.pid != nil }),
                                   let host = store.procs[a.pid!] { ProcessChip(proc: host) }
                                Text(bid).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
                if let o = p.domainOwner, let host = store.procs[o] {
                    Row("Per-process launchd domain (pid domain)", source: "launchctl print pid/<n>") {
                        ProcessChip(proc: host)
                            .help("launchctl print pid/\(o) lists this process among the services it launched.")
                    }
                }
            }
            if let job {
                Collapsible(title: job.title, startsOpen: false) {
                    if nodes.count > 1 { KVTreeContent(nodes: nodes, filter: "") } else { Text(job.text).foregroundStyle(.secondary) }
                }
            }
            if let procinfo {
                Collapsible(title: procinfo.title, startsOpen: false) {
                    let n = LaunchctlParser.parse(procinfo.text)
                    if n.count > 1 { KVTreeContent(nodes: n, filter: "") } else { Text(procinfo.text).foregroundStyle(.secondary) }
                }
            }
        }
    }

    @ViewBuilder private func launchServices(_ ls: LSApp) -> some View {
        Card(title: "LaunchServices", systemImage: "app.badge") {
            FactGrid(rows: [
                FactRow("Name", .text(ls.name), "lsappinfo list"),
                FactRow("Type", .text(ls.type.map(Self.lsTypeLabel) ?? "—"), "lsappinfo list"),
                FactRow("LaunchServices instance (ASN)", .text(ls.asn), "lsappinfo list"),
                FactRow("State tags", .text(ls.stateTags.joined(separator: " ").ifEmpty("—")), "lsappinfo list"),
            ])
            Collapsible(title: "lsappinfo record", startsOpen: false) { LSRecordContent(raw: ls.raw, filter: "") }
        }
    }

    /// An LS type with its plain phrase: "No Dock icon (UIElement)".
    static func lsTypeLabel(_ t: String) -> String {
        switch t {
        case "Foreground": "Dock icon (Foreground)"
        case "UIElement": "No Dock icon (UIElement)"
        case "BackgroundOnly": "No UI (BackgroundOnly)"
        default: t
        }
    }

    @ViewBuilder private func backgroundItem(_ item: BTMItem) -> some View {
        Card(title: "Background item (BTM)", systemImage: "shippingbox") {
            FactGrid(rows: [
                FactRow("Item", .text(item.name), "sfltool dumpbtm"),
                FactRow("Developer", .text([item.developer, item.teamID].filter { !$0.isEmpty }.joined(separator: " · ").ifEmpty("—")), "sfltool dumpbtm"),
                FactRow("State", .text((item.enabled ? "enabled" : "disabled") + ", " + (item.allowed ? "allowed" : "not allowed")), "sfltool dumpbtm"),
                FactRow("Type", .text(item.type), "sfltool dumpbtm"),
                FactRow("Parent item", .text(item.parent.ifEmpty("—")), "sfltool dumpbtm"),
            ])
        }
    }

    private func btmItem(_ p: ProcInfo) -> BTMItem? {
        store.btm.first { item in
            (p.path != nil && item.executable == p.path)
                || (p.launchdLabel != nil && (item.identifier == p.launchdLabel || item.identifier.hasSuffix("." + p.launchdLabel!)))
        }
    }

    /// One row for the registries that have no record of it, instead of a sentence per missing card.
    @ViewBuilder private func unregistered(_ p: ProcInfo, ls: LSApp?, item: BTMItem?) -> some View {
        let missing = [p.launchdLabel == nil && p.domainOwner == nil ? "launchd" : nil,
                       ls == nil ? "LaunchServices" : nil,
                       store.btmLoaded && item == nil ? "Background Items" : nil].compactMap { $0 }
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            if !missing.isEmpty {
                Row("Not registered with", source: "launchctl, lsappinfo, sfltool dumpbtm") { Text(missing.joined(separator: ", ")) }
            }
            if !store.btmLoaded {
                Row("Background item") {
                    HStack(spacing: 6) {
                        Text("not loaded").foregroundStyle(.secondary)
                        Button(store.btmLoading ? "Loading…" : "Load") { store.loadBTM() }
                            .controlSize(.small).disabled(store.btmLoading)
                            .help(store.helperState.isRunning ? "Reads `sfltool dumpbtm` through the helper."
                                                              : "Runs `sfltool dumpbtm`, which asks for an administrator password.")
                    }
                }
            }
        }
        .padding(.horizontal, 10)
    }

    /// The app launchd attributes the job to: whose coalition loaded it.
    @ViewBuilder private func launchdAttribution(_ label: String, _ p: ProcInfo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let a = launchdAttr, a.key == p.key + label {
                if let r = a.result {
                    HStack(spacing: 6) {
                        Text("Loaded on behalf of")
                        if let pid = r.leaderPid, let host = store.procs[pid] { ProcessChip(proc: host) }
                        Text(verbatim: r.bundleID ?? r.name ?? "coalition \(r.coalition)").font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    sourceLine("launchd's attribution record for \(label) (the coalition that loaded it, \(r.coalition)), as launchd logs it when launchservicesd asks; the record itself needs a private entitlement", .exact)
                } else {
                    Text("launchd attributes this job to no app's coalition.").foregroundStyle(.secondary)
                    sourceLine("launchd's attribution record, as launchd logs it when launchservicesd asks (looked up across all app coalitions)", .exact)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Looking up which app launchd attributes this job to…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The inherited environment: the Claude Code session, the terminal, the working directory.
    @ViewBuilder private func envRows(_ e: EnvAttribution, _ p: ProcInfo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Inherited environment").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if e.claudePid != nil || e.claudeSession != nil {
                HStack(spacing: 6) {
                    Text("Claude Code session")
                    // The session's process, if it's still the same one (started before this process).
                    if let cp = e.claudePid, let c = store.procs[cp], c.start <= p.start { ProcessChip(proc: c) }
                    else if let cp = e.claudePid { Text(verbatim: "pid \(cp), no longer running").foregroundStyle(.secondary) }
                    if let s = e.claudeSession { Text(verbatim: String(s.prefix(8))).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).help(s) }
                }
            }
            if let t = e.terminalName {
                Text(verbatim: "Terminal: \(t)" + (e.terminalSession.map { " (session \($0.prefix(18)))" } ?? "")).textSelection(.enabled)
            }
            if let w = e.pwd { Text(verbatim: "Working directory: \(w)").textSelection(.enabled) }
            sourceLine("the environment it inherited from whoever asked for it (CLAUDE_PID, CLAUDE_CODE_SESSION_ID, TERM_PROGRAM, PWD); an app passes these on to what it launches in turn", .inferred)
        }
    }

    @ViewBuilder private func hopChip(_ hop: LaunchWatcher.Hop) -> some View {
        if let live = store.procs[hop.pid], live.start == hop.start {
            ProcessChip(proc: live)
        } else {
            Text(verbatim: "\(hop.name) \(hop.pid)").font(.callout)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary.opacity(0.5), in: Capsule())
                .foregroundStyle(.secondary)
                .help("\(hop.path ?? hop.name): exited")
        }
    }

    /// The confidence badge; the source itself is in the row's info bubble (and this badge's tooltip).
    private func sourceLine(_ s: String, _ c: LaunchMechanism.Confidence) -> some View {
        Text(c.rawValue.uppercased()).font(.system(size: 8, weight: .bold))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .foregroundStyle(c == .exact ? Color.green : .orange)
            .background((c == .exact ? Color.green : .orange).opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
            .help("Source: " + s)
    }

    /// launchd's `immediate reason`, with the common ones spelled out.
    static func reasonText(_ r: String) -> String {
        let known: [String: String] = [
            "ipc (mach)": "a message to one of its Mach services",
            "ipc (socket)": "a connection to one of its sockets",
            "xpc event": "an XPC event it subscribes to",
            "launch job demand": "another job asked for it",
            "speculative": "its own RunAtLoad / KeepAlive setting",
            "semaphore": "a KeepAlive condition",
            "interval": "its start interval",
            "non-ipc demand": "an explicit start (launchctl kickstart or similar)",
        ]
        return known[r].map { "\($0) (\(r))" } ?? r
    }

    private func ancestors(_ p: ProcInfo) -> [ProcInfo] {
        var out: [ProcInfo] = []
        var cur = p
        var seen: Set<pid_t> = [p.pid]
        // A "parent" started after its child reused the parent's pid; the chain ends there.
        while let par = store.procs[cur.ppid], par.start <= cur.start, !seen.contains(par.pid) {
            out.append(par); seen.insert(par.pid); cur = par
        }
        return out
    }

    // Below the chain: who is related to it, the other way round.
    @ViewBuilder private func relations(_ p: ProcInfo) -> some View {
        let all = store.procs.values
        let byPid: (ProcInfo, ProcInfo) -> Bool = { $0.pid < $1.pid }
        let children = all.filter { $0.ppid == p.pid && $0.pid != p.pid && $0.start >= p.start }.sorted(by: byPid)
        let attributed = all.filter { $0.responsible == p.pid && $0.pid != p.pid && $0.start >= p.start }.sorted(by: byPid)
        let coal = p.coalition.map { c in all.filter { $0.coalition == c && $0.pid != p.pid }.sorted(by: byPid) } ?? []
        let jet = p.jetsamCoalition.map { j in
            all.filter { $0.jetsamCoalition == j && $0.pid != p.pid && $0.coalition != p.coalition }.sorted(by: byPid)
        } ?? []
        let bundle = p.bundlePath
        let sameBundle = bundle.map { b in all.filter { $0.bundlePath == b && $0.pid != p.pid }.sorted(by: byPid) } ?? []
        let sameBinary = p.cdhash.map { h in all.filter { $0.cdhash == h && $0.pid != p.pid }.sorted(by: byPid) } ?? []
        let hosted = all.filter { $0.domainOwner == p.pid && $0.pid != p.pid }.sorted(by: byPid)
        let team = store.signInfo(for: p)?.teamID.map { t in
            all.filter { $0.pid != p.pid && store.signInfo(for: $0)?.teamID == t }.sorted(by: byPid)
        } ?? []
        Card(title: "Related", systemImage: "circle.grid.cross") {
            VStack(alignment: .leading, spacing: 8) {
                group("Children", children)
                group("Responsible for", attributed)
                if !hosted.isEmpty { group("In its launchd domain (pid domain)", hosted) }
                group("Same accounting group (resource coalition)", coal)
                group("Same memory-kill group (jetsam coalition), other accounting groups", jet)
                group("Same bundle", sameBundle)
                group("Same binary (cdhash)", sameBinary)
                group("Same team" + (store.signInfo(for: p)?.teamID.map { " (\($0))" } ?? ""), team)
            }
        }
    }

    @ViewBuilder private func group(_ title: String, _ ps: [ProcInfo]) -> some View {
        if ps.isEmpty {
            Text("\(title): none").foregroundStyle(.secondary).font(.subheadline)
        } else {
            Collapsible(title: "\(title) (\(ps.count))", startsOpen: ps.count <= 8) { ChipFlow(procs: ps) }
        }
    }
}

// MARK: - Trust

/// What it is allowed to do: who signed it, the sandbox, and its entitlements by capability.
struct TrustTab: View {
    @Environment(Store.self) var store
    let proc: ProcInfo
    let sign: SignInfo?
    var exited = false
    @State private var filter = ""
    @State private var expanded: Set<EntitlementInfo.Capability> = []
    @AppStorage("showRawOutput") private var showRaw = false
    static let shownKeys = 30

    var body: some View {
        if let s = sign {
            VStack(spacing: 0) {
                HStack {
                    RawToggle(showRaw: $showRaw)
                    Spacer()
                    TextField(showRaw ? "filter lines" : "filter entitlements", text: $filter)
                        .textFieldStyle(.roundedBorder).frame(width: 180)
                }
                .padding(6)
                Divider()
                if showRaw {
                    MonoText(text: filterLines(s.entitlementsXML ?? "No entitlements.", filter))
                } else {
                    content(s)
                }
            }
        } else if exited {
            Text("The process exited before its code signature was read.").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView("Reading code signature…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ s: SignInfo) -> some View {
        let verdict = TrustVerdict(s)
        let dict: [String: Any] = s.entitlementsXML.flatMap { $0.data(using: .utf8) }
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(verdict.long, systemImage: s.unsigned || s.valid == false ? "xmark.seal" : "checkmark.seal")
                    .font(.title3.weight(.semibold)).foregroundStyle(verdict.color)
                Card(title: "Signature", systemImage: "signature") {
                    FactGrid(rows: signatureRows(s))
                }
                HardeningCard(proc: proc, exited: exited)
                TaskDetailCards(proc: proc, exited: exited)
                SandboxCard(proc: proc, exited: exited, entitlements: dict)
                TCCCard(proc: proc, responsible: store.responsibleProcess(proc), entitlements: dict)
                entitlements(dict, platform: s.isPlatform || s.isAppleSigned)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func signatureRows(_ s: SignInfo) -> [FactRow] {
        let info = "SecCodeCopySigningInformation"
        var rows: [FactRow] = []
        rows.append(FactRow("Identifier", .text(s.identifier ?? "—"), info))
        rows.append(FactRow("Team ID", .text(s.teamID ?? "—"), info))
        rows.append(FactRow("Authority", .text(s.authority.isEmpty ? "—" : s.authority.joined(separator: "\n")), info + " certificates"))
        rows.append(FactRow("Valid", .text(s.valid.map { $0 ? "yes" : "NO" } ?? "?"), "SecCodeCheckValidity"))
        rows.append(FactRow("Code hash (cdhash)", .text(s.cdHash ?? "—"), info + " unique"))
        rows.append(FactRow("Code directory flags", .text(s.staticFlagNames.joined(separator: " ").ifEmpty("none")), info + " flags"))
        let status: String = s.runtimeStatus.map { String(format: "0x%08x  ", $0) + s.runtimeFlagNames.joined(separator: " ") } ?? "—"
        rows.append(FactRow("Runtime status", .text(status), info + " status"))
        rows.append(FactRow("Designated requirement", .text(s.designatedRequirement ?? "—"), "SecCodeCopyDesignatedRequirement"))
        if let e = s.error { rows.append(FactRow("Error", .text(e), "Security framework")) }
        return rows
    }

    @ViewBuilder private func entitlements(_ dict: [String: Any], platform: Bool) -> some View {
        let keys = dict.keys.sorted().filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }
        if dict.isEmpty {
            Card(title: "Entitlements", systemImage: "key") { Text("None.").foregroundStyle(.secondary) }
        } else {
            let grouped = Dictionary(grouping: keys, by: EntitlementInfo.capability)
            ForEach(EntitlementInfo.Capability.allCases, id: \.self) { cap in
                if let ks = grouped[cap] {
                    // A filter shows every match; otherwise a long group stops at `shownKeys` until asked, since
                    // past ~16k pixels the tab stops drawing its text (Safari: 130 private-Apple keys).
                    let capped = filter.isEmpty && !expanded.contains(cap) && ks.count > Self.shownKeys + 5
                    Card(title: cap.title, systemImage: cap.symbol, trailing: "\(ks.count)") {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(capped ? Array(ks.prefix(Self.shownKeys)) : ks, id: \.self) { k in
                                let note = EntitlementInfo.notable(k, platform: platform)
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    if note != nil {
                                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                    }
                                    Text(k).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                    if let note { Text(note).font(.caption).foregroundStyle(.orange) }
                                    Spacer(minLength: 12)
                                    PlistValue(value: dict[k]!)
                                }
                                Divider().opacity(0.5)
                            }
                            if filter.isEmpty && ks.count > Self.shownKeys + 5 {
                                Button(capped ? "Show all \(ks.count)" : "Show fewer") {
                                    if capped { expanded.insert(cap) } else { expanded.remove(cap) }
                                }
                                .buttonStyle(.link).font(.caption)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Entitlements by capability, from Apple's documented key namespaces. A key outside them goes to Other;
/// nothing is guessed from a key's wording.
enum EntitlementInfo {
    enum Capability: Int, CaseIterable {
        case sandbox, files, network, hardware, personal, automation, codeLoading, apple, privateApple, other
        var title: String {
            switch self {
            case .sandbox: "App Sandbox"
            case .files: "Files"
            case .network: "Network"
            case .hardware: "Hardware"
            case .personal: "Personal data"
            case .automation: "Automation"
            case .codeLoading: "Code loading and debugging"
            case .apple: "Apple services"
            case .privateApple: "Private Apple"
            case .other: "Other"
            }
        }
        var symbol: String {
            switch self {
            case .sandbox: "square.dashed"
            case .files: "folder"
            case .network: "network"
            case .hardware: "camera"
            case .personal: "person.crop.circle"
            case .automation: "applescript"
            case .codeLoading: "ant"
            case .apple: "apple.logo"
            case .privateApple: "lock.fill"
            case .other: "seal"
            }
        }
    }

    /// Prefix → capability, first match. All `com.apple.security.*` namespaces are documented by Apple.
    private static let prefixes: [(String, Capability)] = [
        ("com.apple.security.app-sandbox", .sandbox),
        ("com.apple.security.inherit", .sandbox),
        ("com.apple.security.temporary-exception.", .sandbox),
        ("com.apple.security.files.", .files),
        ("com.apple.security.assets.", .files),
        ("com.apple.security.network.", .network),
        ("com.apple.security.device.", .hardware),
        ("com.apple.security.print", .hardware),
        ("com.apple.security.personal-information.", .personal),
        ("com.apple.security.automation.", .automation),
        ("com.apple.security.scripting-targets", .automation),
        ("com.apple.security.cs.", .codeLoading),
        ("com.apple.security.get-task-allow", .codeLoading),
        ("com.apple.developer.", .apple),
        ("com.apple.application-identifier", .apple),
        ("com.apple.security.application-groups", .apple),
        ("keychain-access-groups", .apple),
        ("com.apple.private.", .privateApple),
    ]

    static func capability(_ key: String) -> Capability {
        if key.contains(".private.") || key.hasPrefix("private.") { return .privateApple }
        return prefixes.first { key.hasPrefix($0.0) }?.1 ?? .other
    }

    /// What a notable entitlement permits, or nil. A private Apple entitlement is notable only on code
    /// Apple didn't sign: Apple's own binaries carry hundreds of them.
    static func notable(_ key: String, platform: Bool) -> String? {
        switch key {
        case "com.apple.security.get-task-allow":
            return "lets other processes attach a debugger and read its memory"
        case "com.apple.security.cs.disable-library-validation":
            return "may load libraries and plug-ins signed by anyone"
        case "com.apple.security.cs.allow-unsigned-executable-memory":
            return "may create executable memory without signing it"
        case "com.apple.security.cs.allow-dyld-environment-variables":
            return "honours DYLD_* variables, so a launcher can inject libraries"
        case "com.apple.security.cs.disable-executable-page-protection":
            return "turns off executable memory protection entirely"
        default:
            if !platform, capability(key) == .privateApple { return "private Apple entitlement on non-Apple code" }
            return nil
        }
    }
}

// MARK: - Store lookups

extension Store {
    /// The process at the top of `p`'s group in the Smart tree (its app or job), from the same pass.
    func unitRoot(of p: ProcInfo) -> pid_t? {
        if kindCache?.gen != dataGen { _ = kind(of: p) }
        return kindCache?.roots[p.pid]
    }
}

extension BundleInfo {
    /// CFBundleShortVersionString, read once per bundle.
    static func version(_ bundle: String) -> String? {
        if let hit = versions[bundle] { return hit }
        let plist = NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist") ?? NSDictionary(contentsOfFile: bundle + "/Info.plist")
        let v = plist?["CFBundleShortVersionString"] as? String
        versions[bundle] = .some(v)
        return v
    }
}
