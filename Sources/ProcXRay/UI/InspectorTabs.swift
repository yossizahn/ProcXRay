import AppKit
import SwiftUI

// The inspector's six question-shaped tabs and its fixed header (docs/tree-and-inspector-proposal.md,
// Part 3). Overview, Origin and Trust are built here; Resources, Connections and Activity hold the
// existing panes until steps 8 and 9 rebuild them.

enum InspectorTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case origin = "Origin"
    case trust = "Trust"
    case resources = "Resources"
    case connections = "Connections"
    case activity = "Activity"
    var id: String { rawValue }
}

// MARK: - Header

/// Always visible above the tabs: who the process is, what owns it, and the actions.
struct InspectorHeader: View {
    @Environment(Store.self) var store
    @Environment(\.inspectorLinks) private var links
    let proc: ProcInfo
    let exited: Bool
    let sign: SignInfo?
    @State private var pendingSignal: (Int32, String)?
    @State private var signalError: String?

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
                Text(p.name).font(.headline).lineLimit(1)
                Text(verbatim: "pid \(p.pid) · \(p.user) · \(Fmt.age(p.start))")
                    .foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: 22)
            // What it is, whose it is, its sandbox and signer: each from a field, nothing inferred.
            HStack(spacing: 5) {
                Text(store.kind(of: p) ?? "Process")
                if let owner {
                    Text("of").foregroundStyle(.secondary)
                    ProcessChip(proc: owner)
                }
                Text("·").foregroundStyle(.tertiary)
                Text(p.sandboxed.map { $0 ? "sandboxed" : "not sandboxed" } ?? "sandbox unknown")
                Text("·").foregroundStyle(.tertiary)
                Text(TrustVerdict(sign).short)
                Spacer(minLength: 0)
            }
            .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            .frame(height: 20)
            HStack(spacing: 6) {
                ForEach(badges(p), id: \.0) { Pill(text: $0.0, color: $0.1).help($0.2) }
                Spacer(minLength: 0)
                Menu("Signal") {
                    Button("Terminate (SIGTERM)") { pendingSignal = (SIGTERM, "SIGTERM") }
                    Button("Kill (SIGKILL)") { pendingSignal = (SIGKILL, "SIGKILL") }
                    Button("Suspend (SIGSTOP)") { pendingSignal = (SIGSTOP, "SIGSTOP") }
                    Button("Resume (SIGCONT)") { send(SIGCONT, "SIGCONT") }   // harmless: no confirmation
                }
                .controlSize(.small).fixedSize()
                // kernel_task (pid 0): kill(0, …) would signal ProcXRay's own process group.
                .disabled(exited || p.pid <= 0)
                .help(exited ? "The process has exited." : "Send a signal to this process")
                Button("Reveal") {
                    if let path = p.path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
                .controlSize(.small)
                .disabled(p.path == nil)
                .help(p.path ?? "No executable path")
            }
            .frame(height: 22)
        }
        .padding(.horizontal, 10).padding(.top, 4)
        .confirmationDialog(pendingSignal.map { "Send \($0.1) to \(p.name) (pid \(p.pid))?" } ?? "",
                            isPresented: Binding(get: { pendingSignal != nil }, set: { if !$0 { pendingSignal = nil } })) {
            Button(pendingSignal?.1 ?? "Send", role: .destructive) {
                if let (sig, label) = pendingSignal { send(sig, label) }
                pendingSignal = nil
            }
        }
        .signalFailureAlert($signalError)
    }

    private func send(_ sig: Int32, _ label: String) {
        if let err = store.send(sig, to: proc) {
            let msg = "Couldn't send \(label) to \(proc.name) (pid \(proc.pid)).\n\n\(err)"
            DispatchQueue.main.async { signalError = msg }
        }
        store.refresh()
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

/// A titled key/value grid that doesn't scroll by itself (tabs put several in one ScrollView).
struct FactGrid: View {
    let rows: [(String, KVValue)]
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                GridRow {
                    Text(r.0).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    switch r.1 {
                    case .text(let t):
                        Text(t).textSelection(.enabled).font(.system(.body, design: .monospaced))
                    case .process(let p, let note):
                        HStack(spacing: 6) {
                            ProcessChip(proc: p)
                            if !note.isEmpty { Text(note).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                    }
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

// MARK: - Overview

struct OverviewTab: View {
    @Environment(Store.self) var store
    let proc: ProcInfo
    var exited = false
    let sign: SignInfo?
    /// Switches the inspector to another tab (the Related strip's counts lead to Origin).
    let show: (InspectorTab) -> Void
    @State private var cwd: (key: String, path: String?)?
    /// Arguments and environment, for the process `key` (nil: not readable).
    @State private var args: (key: String, value: Native.ArgsEnv?)?

    var body: some View {
        let p = proc
        let r = p.rates
        let children = store.procs.values.filter { $0.ppid == p.pid && $0.pid != p.pid && $0.start >= p.start }.count
        let attributed = store.procs.values.filter { $0.responsible == p.pid && $0.pid != p.pid && $0.start >= p.start }.count
        let owner = store.unitRoot(of: p).flatMap { $0 == p.pid ? nil : store.procs[$0] }
        let parent = store.procs[p.ppid].flatMap { $0.start <= p.start && $0.pid != p.pid ? $0 : nil }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Now (over the last refresh), with the last few minutes behind it.
                let h = store.history[p.key]
                HStack(spacing: 8) {
                    SparkTile(title: "CPU", value: p.cpuPercent.map { "\(Fmt.pct($0)) %" } ?? "—",
                              values: h?.cpu ?? [], format: { "\(Fmt.pct($0)) %" })
                    SparkTile(title: "Memory", value: Fmt.bytes(p.footprint), values: h?.memory ?? [], fromZero: false,
                              format: { Fmt.bytes(UInt64($0)) })
                    SparkTile(title: "Disk read + written", value: diskRate(r), values: h?.disk ?? [], format: bytesPerSecFormat)
                    SparkTile(title: "Power", value: r?.watts.map(wattsFormat) ?? "—", values: h?.power ?? [], format: wattsFormat)
                    Spacer(minLength: 0)
                }
                FactGrid(rows: facts(p))
                Card(title: "Related", systemImage: "point.3.connected.trianglepath.dotted") {
                    FactGrid(rows: [
                        ("Owner", owner.map { .process($0) } ?? .text("— (it is the top of its group)")),
                        ("Parent", parent.map { .process($0) } ?? .text(p.ppid == p.pid ? "none" : "not running (\(p.ppid))")),
                        ("Responsible", store.responsibleProcess(p).map { .process($0) } ?? .text(store.responsibleDescription(p))),
                    ])
                    HStack(spacing: 8) {
                        Button("\(children) children") { show(.origin) }
                        Button("responsible for \(attributed)") { show(.origin) }
                    }
                    .controlSize(.small)
                }
                command(p)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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

    /// The command line it was started with and its environment, collapsed.
    @ViewBuilder private func command(_ p: ProcInfo) -> some View {
        let loaded = args?.key == p.key ? args : nil
        Collapsible(title: "Command" + (loaded?.value.map { " (\($0.args.count) arguments, \($0.env.count) environment variables)" } ?? ""),
                    startsOpen: false) {
            if let a = loaded?.value {
                VStack(alignment: .leading, spacing: 6) {
                    Collapsible(title: "Arguments (\(a.args.count))", startsOpen: a.args.count <= 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(a.args.enumerated()), id: \.offset) { i, s in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("[\(i)]").foregroundStyle(.secondary).monospacedDigit()
                                    Text(s).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    Collapsible(title: "Environment (\(a.env.count))", startsOpen: false) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(a.env.sorted(), id: \.self) { Text($0).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                        }
                    }
                }
            } else {
                Text(exited && loaded == nil ? "The process has exited; its arguments can't be read any more."
                     : loaded != nil ? "Not readable (another user's process; the privileged helper can read it)." : "Reading…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func diskRate(_ r: Rates?) -> String {
        guard let read = r?.diskRead, let write = r?.diskWrite else { return "—" }
        let total = read + write
        return total < 1 ? "0 B/s" : Fmt.bytes(UInt64(total)) + "/s"
    }

    private func facts(_ p: ProcInfo) -> [(String, KVValue)] {
        var rows: [(String, KVValue)] = [("Path", .text(p.path ?? "— (\(p.comm))"))]
        if let b = store.bundleID(of: p) {
            let version = p.bundlePath.flatMap(BundleInfo.version)
            rows.append(("Bundle", .text(b + (version.map { "  \($0)" } ?? ""))))
        }
        rows += [
            ("User", .text("\(p.user) (uid \(p.uid))")),
            ("Started", .text(Fmt.shownStart(p.start) == p.start
                ? "\(Fmt.date.string(from: p.start))  (\(Fmt.age(p.start)) ago)"
                : "at boot, before the clock was set (\(Fmt.date.string(from: Fmt.shownStart(p.start))))")),
            ("State", .text(Column.byID["state"]!.value(p, store).display.ifEmpty("live"))),
            ("Architecture", .text(Column.byID["arch"]!.value(p, store).display)),
            ("Sandbox", .text(p.sandboxed.map { $0 ? "sandboxed" : "not sandboxed" } ?? "unknown")),
            ("Signed", .text(TrustVerdict(sign).long)),
            ("Working dir", .text(cwd?.key == p.key ? cwd?.path ?? "—" : "—")),
            ("Kind", .text(store.kind(of: p) ?? "—")),
        ]
        if let l = p.launchdLabel { rows.append(("launchd label", .text(l))) }
        if let e = p.extensionPoint { rows.append(("Extension point", .text("\(ExtensionInfo.title(e))  (\(e))"))) }
        return rows
    }
}

// MARK: - Sparklines

/// A line of the last `History.capacity` values, newest at the right edge. Rates are scaled from zero to
/// their maximum; a level such as memory (`fromZero` false) between its minimum and maximum, or it would
/// be a flat line at the top. Gaps (no reading for that refresh) break the line.
struct Sparkline: View {
    let values: [Double?]
    var fromZero = true
    var color: Color = .accentColor

    var body: some View {
        Canvas { ctx, size in
            let known = values.compactMap { $0 }
            let bottom = fromZero ? 0 : (known.min() ?? 0)
            let top = (known.max() ?? 0) - bottom
            let step = size.width / CGFloat(History.capacity - 1)
            var line = Path(), area = Path()
            var runStart: CGPoint?, last: CGPoint?
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
                let x = size.width - CGFloat(values.count - 1 - i) * step
                // A flat level (top 0) sits mid-height; a flat zero rate sits on the baseline.
                let y = top > 0 ? size.height - CGFloat((v - bottom) / top) * (size.height - 1) - 0.5
                                : (fromZero ? size.height - 0.5 : size.height / 2)
                let pt = CGPoint(x: x, y: y)
                if runStart == nil { line.move(to: pt); area.move(to: pt); runStart = pt } else { line.addLine(to: pt); area.addLine(to: pt) }
                last = pt
            }
            close()
            ctx.fill(area, with: .color(color.opacity(0.15)))
            ctx.stroke(line, with: .color(color), lineWidth: 1.2)
        }
        .accessibilityHidden(true)
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
            Sparkline(values: values, fromZero: fromZero).frame(height: 24)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(width: 150, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .help(known.isEmpty ? "No history yet"
              : "Last \(values.count) refreshes: \(format(known.min()!)) to \(format(known.max()!)); the line spans "
                + (fromZero ? "zero to the maximum." : "the minimum to the maximum."))
    }
}

// MARK: - Resources

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
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !p.isInspectable {
                    Text("Task info isn't readable (owned by \(p.user)). Install the privileged helper to read it.")
                        .foregroundStyle(.secondary)
                }
                Self.section("CPU", "cpu", h?.cpu, format: { "\(Fmt.pct($0)) %" }, rows: [
                    ("CPU", r?.cpuPercent.map { "\(Fmt.pct($0)) %" } ?? "—", Fmt.secs(p.cpuNanos)),
                    ("On performance cores", r?.pCoreShare.map { String(format: "%.0f %%", $0) } ?? "—",
                     c?.pCoreNanos.map { pc in Fmt.secs(pc) + (p.cpuNanos.flatMap { $0 > 0 ? String(format: " (%.0f %%)", Double(pc) / Double($0) * 100) : nil } ?? "") } ?? "—"),
                    ("Waiting for a CPU", r?.waitingPercent.map { String(format: "%.1f %%", $0) } ?? "—", Fmt.secs(c?.waitingNanos)),
                    // How many threads exist. (No "running" count: pti_numrunning is one instant, and for a
                    // process at a few percent CPU it reads 0 almost every time: 95.7 % of 2,000 reads for
                    // Firefox at 2 %.)
                    ("Threads", p.threads.map(String.init) ?? "—", ""),
                    ("Instructions per cycle", r?.ipc.map { String(format: "%.2f", $0) } ?? "—",
                     c.flatMap { c in c.instructions.flatMap { i in c.cycles.flatMap { $0 > 0 ? String(format: "%.2f", Double(i) / Double($0)) : nil } } } ?? "—"),
                    ("Context switches", rate(r?.contextSwitches), Fmt.count(c?.contextSwitches)),
                ])
                qosSection(p)
                Self.section("Memory", "memorychip", h?.memory, fromZero: false, format: { Fmt.bytes(UInt64($0)) }, rows: [
                    ("Footprint", Fmt.bytes(p.footprint), c?.peakFootprint.map { "peak " + Fmt.bytes($0) } ?? "—"),
                    ("Resident", Fmt.bytes(p.rss), ""),
                    ("Virtual", Fmt.bytes(p.virt), ""),
                    ("Neural Engine", Fmt.bytes(c?.neuralFootprint), ""),
                    ("Page faults", rate(r?.faults), c.map { "\(Fmt.count($0.faults)) (\(Fmt.count($0.cowFaults)) copy-on-write)" } ?? "—"),
                    ("Page-ins", rate(r?.pageins), Fmt.count(c?.pageins)),
                ])
                Self.section("Disk", "internaldrive", h?.disk, format: bytesPerSecFormat, rows: [
                    ("Read", r?.diskRead.map(bytesPerSecFormat) ?? "—", Fmt.bytes(p.diskRead)),
                    ("Written", r?.diskWrite.map(bytesPerSecFormat) ?? "—", Fmt.bytes(p.diskWrite)),
                    ("Logical writes", r?.logicalWrites.map(bytesPerSecFormat) ?? "—", Fmt.bytes(c?.logicalWrites)),
                ])
                Self.section("Energy and wakeups", "bolt", h?.power, format: wattsFormat, rows: [
                    ("CPU energy", r?.watts.map(wattsFormat) ?? "—", p.energyNJ.map { String(format: "%.2f J", Double($0) / 1e9) } ?? "—"),
                    ("Wakeups (idle + interrupt)", rate(r?.wakeups), Fmt.count(p.wakeups)),
                ])
                Self.section("System calls and IPC", "arrow.left.arrow.right", nil, format: { _ in "" }, rows: [
                    ("BSD system calls", rate(r?.unixSyscalls), Fmt.count(c?.unixSyscalls)),
                    ("Mach system calls", rate(r?.machSyscalls), Fmt.count(c?.machSyscalls)),
                    ("Mach messages sent", rate(r?.machMsgsSent), Fmt.count(c?.machMsgsSent)),
                    ("Mach messages received", rate(r?.machMsgsReceived), Fmt.count(c?.machMsgsReceived)),
                ] + machPortRows(p))
                voucherSection(p)
                other(p)
                if p.viaHelper { Text("Task metrics read as root through the privileged helper.").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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

    /// Mach-voucher (BANK) accounting: CPU and energy this process ran on behalf of others, and that others
    /// ran on its behalf (rusage ri_billed/serviced_system_time and _energy). Hidden when all four are zero,
    /// which is the common case; it is mainly non-zero for service daemons and the processes they serve.
    @ViewBuilder private func voucherSection(_ p: ProcInfo) -> some View {
        let c = p.counters
        let joules: (UInt64?) -> String = { $0.map { String(format: "%.2f J", Double($0) / 1e9) } ?? "—" }
        let any = [c?.servicedCpuNanos, c?.billedCpuNanos, c?.servicedEnergyNJ, c?.billedEnergyNJ].contains { ($0 ?? 0) > 0 }
        if any {
            Self.section("On behalf of other processes", "arrow.left.arrow.right.square", nil, format: { _ in "" }, rows: [
                ("CPU for others", "", Fmt.secs(c?.servicedCpuNanos)),
                ("CPU by others", "", Fmt.secs(c?.billedCpuNanos)),
                ("Energy for others", "", joules(c?.servicedEnergyNJ)),
                ("Energy by others", "", joules(c?.billedEnergyNJ)),
            ])
            .help("Work attributed through Mach vouchers (the BANK attribute). \"For others\" is CPU and energy this process spent servicing other processes' requests; \"by others\" is what other processes spent servicing this one. Most of it flows automatically over XPC, where a service adopts its caller's voucher. Totals since the process started.")
        }
    }

    /// CPU time by quality-of-service class: which kind of work the CPU went to (rusage ri_cpu_time_qos_*).
    /// Read with the rest of the counters each refresh, so "now" covers the same interval as CPU %.
    @ViewBuilder private func qosSection(_ p: ProcInfo) -> some View {
        if let q = p.counters?.qosNanos {
            let total = q.reduce(0, +)
            let now = p.rates?.qosPercent
            let rows: [Row] = q.indices.filter { q[$0] > 0 }.map { i in
                let share = total > 0 ? String(format: " (%.0f %%)", Double(q[i]) / Double(total) * 100) : ""
                return (Counters.qosClasses[i], now.map { "\(Fmt.pct($0[i])) %" } ?? "—", Fmt.secs(q[i]) + share)
            }
            if !rows.isEmpty {
                Self.section("CPU by QoS class", "dial.medium", nil, format: { _ in "" }, rows: rows)
                    .help("The quality-of-service class threads ran at. \"Now\" is the share of one core over the last refresh, as CPU % above.")
            }
        }
    }

    private func rate(_ v: Double?) -> String { v.map(perSecFormat) ?? "—" }

    /// The process's port space from the last lsmp snapshot (the Mach ports columns' or the Connections
    /// tab's, whichever ran); none until one has been taken. Counts at that moment, so under "Now".
    private func machPortRows(_ p: ProcInfo) -> [(String, String, String)] {
        guard let m = p.machPorts
                ?? MachLoader.peek().flatMap({ s in p.start <= s.at ? s.counts[p.pid] : nil }) else { return [] }
        return [
            ("Mach ports", Fmt.count(m.total),
             "\(Fmt.count(m.receive)) receive · \(Fmt.count(m.send)) send · \(Fmt.count(m.portSets)) sets"),
            ("Replies owed (send-once)", Fmt.count(m.sendOnce), ""),
            ("Dead names", Fmt.count(m.deadNames), ""),
            ("Full queues", Fmt.count(m.fullQueues), ""),
        ]
    }
    private static let metricWidth: CGFloat = 180, nowWidth: CGFloat = 90, totalWidth: CGFloat = 240

    /// One section: metric, now and since start in fixed-width columns, and its sparkline. The group
    /// inspector uses it too, so both pages line up the same way.
    static func section(_ title: String, _ symbol: String, _ spark: [Double?]?, fromZero: Bool = true,
                        format: @escaping (Double) -> String, rows: [(String, String, String)]) -> some View {
        Card(title: title, systemImage: symbol) {
            HStack(alignment: .top, spacing: 16) {
                // Fixed column widths, so every section's columns and sparkline line up with the others'.
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        Text("").frame(width: Self.metricWidth, alignment: .leading)
                        Text("Now").font(.caption).foregroundStyle(.secondary).frame(width: Self.nowWidth, alignment: .trailing)
                        Text("Since start").font(.caption).foregroundStyle(.secondary).frame(width: Self.totalWidth, alignment: .trailing)
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            Text(row.0).foregroundStyle(.secondary).frame(width: Self.metricWidth, alignment: .leading)
                            Text(row.1).monospacedDigit().textSelection(.enabled).frame(width: Self.nowWidth, alignment: .trailing)
                            Text(row.2).monospacedDigit().textSelection(.enabled).frame(width: Self.totalWidth, alignment: .trailing)
                        }
                    }
                }
                if let spark {
                    let known = spark.compactMap { $0 }
                    Sparkline(values: spark, fromZero: fromZero).frame(width: 200, height: 44)
                        .help(known.isEmpty ? "No history yet"
                              : "Last \(spark.count) refreshes: \(format(known.min()!)) to \(format(known.max()!)); the line spans "
                                + (fromZero ? "zero to the maximum." : "the minimum to the maximum."))
                }
            }
        }
    }

    @ViewBuilder private func other(_ p: ProcInfo) -> some View {
        let e = extra?.key == p.key ? extra : nil
        Card(title: "Other", systemImage: "ellipsis.circle") {
            VStack(alignment: .leading, spacing: 8) {
                FactGrid(rows: [
                    ("Open files", .text(e?.files.map { "\($0) descriptors (files, sockets, pipes)" } ?? (exited ? "—" : "not readable"))),
                    ("Power assertions", .text(e.map { $0.assertions.isEmpty ? "none" : $0.assertions.map { "\($0.0)\($0.1.isEmpty ? "" : ": \($0.1)")" }.joined(separator: "\n") } ?? "—")),
                ])
            }
        }
    }
}

// MARK: - Origin

/// Why is it running, and who does it belong to: a chain read top to bottom, then the reverse relations.
struct OriginTab: View {
    @Environment(Store.self) var store
    let proc: ProcInfo
    var exited = false
    @State private var loadedKey: String?
    @State private var job: (title: String, text: String)?
    @State private var procinfo: (title: String, text: String)?

    var body: some View {
        let p = proc
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                installedBy(p)
                launchedBy(p)
                Card(title: "Parent chain", systemImage: "arrow.up.to.line") {
                    let chain = ancestors(p)
                    if chain.isEmpty { Text("No running parent.").foregroundStyle(.secondary) } else { ChipFlow(procs: chain) }
                }
                Card(title: "Responsible", systemImage: "person.crop.square") {
                    if let rp = store.responsibleProcess(p) { ProcessChip(proc: rp) }
                    else { Text(store.responsibleDescription(p)).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                relations(p)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Reload when the process registers with LaunchServices or launchd, execs, or on a manual refresh.
        .task(id: "\(p.codeKey)|\(p.launchdLabel ?? "")|\(store.fullRefreshGen)|\(exited)|\(store.helperState.isRunning)") {
            guard !exited else { return }   // keep what was shown; the pid may be someone else's now
            if loadedKey != p.key { job = nil; procinfo = nil }
            let label = p.launchdLabel, pid = p.pid, key = p.key
            let helper = store.helperState.isRunning
            let (j, pi) = await Task.detached { () -> ((String, String)?, (String, String)?) in
                let j = label.map { ("launchctl print \($0)", Launchd.printJob($0)) }
                let pi = helper ? ("launchctl procinfo \(pid) (as root via helper)",
                                   HelperClient.shared.run(.launchctlProcinfo, pid: pid) ?? "helper did not answer") : nil
                return (j, pi)
            }.value
            guard !Task.isCancelled else { return }
            job = j; procinfo = pi; loadedKey = key
        }
    }

    // 1. Installed by: the Background Task Management record, matched exactly on executable path or label.
    @ViewBuilder private func installedBy(_ p: ProcInfo) -> some View {
        Card(title: "Installed by", systemImage: "shippingbox") {
            if !store.btmLoaded {
                HStack {
                    Text("Background Items aren't loaded.").foregroundStyle(.secondary)
                    Button(store.btmLoading ? "Loading…" : "Load") { store.loadBTM() }
                        .controlSize(.small).disabled(store.btmLoading)
                        .help(store.helperState.isRunning ? "Reads `sfltool dumpbtm` through the helper."
                                                          : "Runs `sfltool dumpbtm`, which asks for an administrator password.")
                }
            } else if let item = btmItem(p) {
                FactGrid(rows: [
                    ("Item", .text(item.name)),
                    ("Developer", .text([item.developer, item.teamID].filter { !$0.isEmpty }.joined(separator: " · ").ifEmpty("—"))),
                    ("State", .text((item.enabled ? "enabled" : "disabled") + ", " + (item.allowed ? "allowed" : "not allowed"))),
                    ("Type", .text(item.type)),
                    ("Parent item", .text(item.parent.ifEmpty("—"))),
                ])
            } else {
                Text("No Background Items record for this executable or label.").foregroundStyle(.secondary)
            }
        }
    }

    private func btmItem(_ p: ProcInfo) -> BTMItem? {
        store.btm.first { item in
            (p.path != nil && item.executable == p.path)
                || (p.launchdLabel != nil && (item.identifier == p.launchdLabel || item.identifier.hasSuffix("." + p.launchdLabel!)))
        }
    }

    // 2. Launched by: the launchd job, LaunchServices, or the extension point.
    @ViewBuilder private func launchedBy(_ p: ProcInfo) -> some View {
        Card(title: "Launched by", systemImage: "bolt.horizontal") {
            VStack(alignment: .leading, spacing: 8) {
                // Who actually spawned it. Registering with LaunchServices (below) says nothing about this:
                // every app checks in on startup, however it was started.
                if p.ppid > 1, let parent = store.procs[p.ppid] {
                    HStack(spacing: 6) {
                        Text("Started directly by")
                        ProcessChip(proc: parent)
                        Text("(its parent process)").foregroundStyle(.secondary)
                    }
                } else if p.ppid == 1 {
                    Text("Parent is launchd: launchd started it (a launchd job or an app launch), or the process that started it has exited.")
                        .foregroundStyle(.secondary)
                }
                if let ls = store.lsApps.first(where: { $0.pid == p.pid }) {
                    Text("Registered with LaunchServices as the app \u{201C}\(ls.name)\u{201D} (\(ls.type ?? "?")).")
                    Collapsible(title: "LaunchServices record", startsOpen: false) { LSRecordContent(raw: ls.raw, filter: "") }
                }
                if let e = p.extensionPoint {
                    Text("App extension for \(ExtensionInfo.title(e)) (\(e))\(p.containingAppName.map { ", inside \($0)" } ?? "").")
                }
                if let o = p.domainOwner, let host = store.procs[o] {
                    HStack(spacing: 6) {
                        Text("Started by launchd for")
                        ProcessChip(proc: host)
                        Text("(runs in its pid domain)").foregroundStyle(.secondary)
                    }
                    .help("launchctl print pid/\(o) lists this process among the services it launched.")
                }
                if let label = p.launchdLabel {
                    let nodes = job.map { LaunchctlParser.parse($0.text) } ?? []
                    let top = Dictionary(nodes.map { ($0.key, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
                    FactGrid(rows: [
                        ("launchd job", .text(label)),
                        ("Domain", .text(p.launchdDomain ?? top["domain"] ?? "—")),
                        ("Type", .text(top["type"] ?? "—")),
                        ("Properties", .text(top["properties"] ?? "—")),
                        ("Runs / last exit", .text("\(top["runs"] ?? "—") / \(top["last exit code"] ?? "—")")),
                        ("Started because", .text(top["immediate reason"].map(Self.reasonText) ?? "—")),
                    ])
                    // Set by launchd only for jobs an app registered through SMAppService.
                    if let bid = top["parent bundle identifier"], !bid.isEmpty {
                        HStack(spacing: 6) {
                            Text("Registered by the app")
                            if let a = store.lsApps.first(where: { $0.bundleID == bid && $0.pid != nil }),
                               let host = store.procs[a.pid!] { ProcessChip(proc: host) }
                            Text(bid).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        .help("launchctl print: parent bundle identifier (an SMAppService registration).")
                    }
                    if let plist = top["path"], !plist.isEmpty {
                        HStack {
                            Text(plist).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: plist)]) }
                                .controlSize(.small)
                        }
                    }
                    if let job {
                        Collapsible(title: job.title, startsOpen: false) {
                            if nodes.count > 1 { KVTreeContent(nodes: nodes, filter: "") } else { Text(job.text).foregroundStyle(.secondary) }
                        }
                    }
                } else if store.lsApps.first(where: { $0.pid == p.pid }) == nil, p.extensionPoint == nil, p.domainOwner == nil {
                    Text("Not the main process of a launchd job in your domains, not a LaunchServices app.")
                        .foregroundStyle(.secondary)
                }
                if let procinfo {
                    Collapsible(title: procinfo.title, startsOpen: false) {
                        let n = LaunchctlParser.parse(procinfo.text)
                        if n.count > 1 { KVTreeContent(nodes: n, filter: "") } else { Text(procinfo.text).foregroundStyle(.secondary) }
                    }
                }
            }
        }
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
        Card(title: "Related processes", systemImage: "circle.grid.cross") {
            VStack(alignment: .leading, spacing: 8) {
                group("Children", children)
                group("Responsible for", attributed)
                if !hosted.isEmpty { group("Running in its pid domain", hosted) }
                group("Same resource coalition", coal)
                group("Same jetsam coalition, other resource coalitions", jet)
                group("Same app bundle", sameBundle)
                group("Same binary (same CDHash)", sameBinary)
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
    @AppStorage("showRawOutput") private var showRaw = false

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
        let team = s.teamID.map { t in
            store.procs.values.filter { $0.pid != proc.pid && store.signInfo(for: $0)?.teamID == t }.sorted { $0.pid < $1.pid }
        } ?? []
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(verdict.long, systemImage: s.unsigned || s.valid == false ? "xmark.seal" : "checkmark.seal")
                    .font(.title3.weight(.semibold)).foregroundStyle(verdict.color)
                Card(title: "Signature", systemImage: "signature") {
                    FactGrid(rows: signatureRows(s))
                }
                SandboxCard(proc: proc, exited: exited, entitlements: dict)
                entitlements(dict, platform: s.isPlatform || s.isAppleSigned)
                if !team.isEmpty, let t = s.teamID {
                    Card(title: "Same team (\(t))", systemImage: "person.3", trailing: "\(team.count)") { ChipFlow(procs: team) }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func signatureRows(_ s: SignInfo) -> [(String, KVValue)] {
        var rows: [(String, KVValue)] = []
        rows.append(("Identifier", .text(s.identifier ?? "—")))
        rows.append(("Team ID", .text(s.teamID ?? "—")))
        rows.append(("Authority", .text(s.authority.isEmpty ? "—" : s.authority.joined(separator: "\n"))))
        rows.append(("Valid now", .text(s.valid.map { $0 ? "yes" : "NO" } ?? "unknown")))
        rows.append(("CDHash", .text(s.cdHash ?? "—")))
        rows.append(("Code directory flags", .text(s.staticFlagNames.joined(separator: " ").ifEmpty("none"))))
        let status: String = s.runtimeStatus.map { String(format: "0x%08x  ", $0) + s.runtimeFlagNames.joined(separator: " ") } ?? "—"
        rows.append(("Runtime status", .text(status)))
        rows.append(("Requirement", .text(s.designatedRequirement ?? "—")))
        if let e = s.error { rows.append(("Error", .text(e))) }
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
                    Card(title: cap.title, systemImage: cap.symbol, trailing: "\(ks.count)") {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(ks, id: \.self) { k in
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
