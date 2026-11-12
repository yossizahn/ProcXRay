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

    var body: some View {
        let p = proc
        let r = p.rates
        let children = store.procs.values.filter { $0.ppid == p.pid && $0.pid != p.pid && $0.start >= p.start }.count
        let attributed = store.procs.values.filter { $0.responsible == p.pid && $0.pid != p.pid && $0.start >= p.start }.count
        let owner = store.unitRoot(of: p).flatMap { $0 == p.pid ? nil : store.procs[$0] }
        let parent = store.procs[p.ppid].flatMap { $0.start <= p.start && $0.pid != p.pid ? $0 : nil }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Now, over the last refresh; sparklines arrive with the Resources step.
                HStack(spacing: 8) {
                    StatTile(title: "CPU", value: p.cpuPercent.map { "\(Fmt.pct($0)) %" } ?? "—",
                             sub: p.threads.map { "\($0) threads" })
                    StatTile(title: "Memory", value: Fmt.bytes(p.footprint), sub: "footprint")
                    StatTile(title: "Disk", value: diskRate(r), sub: "read + written")
                    StatTile(title: "Power", value: r?.watts.map { String(format: "%.2f W", $0) } ?? "—", sub: "CPU energy")
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
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Re-read on an exec, on a manual refresh, and when the helper comes or goes.
        .task(id: "\(p.codeKey)|\(store.fullRefreshGen)|\(exited)|\(store.helperState.isRunning)") {
            guard !exited else { return }
            let pid = p.pid, start = p.start, key = p.key
            let helper = store.helperState.isRunning
            let c = await Task.detached { () -> String? in
                let c = Native.cwd(pid) ?? (helper ? HelperClient.shared.argsEnv(pid)?.cwd : nil)
                return Native.isSame(pid, start: start) ? c : nil
            }.value
            guard !Task.isCancelled else { return }
            cwd = (key, c)
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
            ("State", .text(Column.byID["state"]!.value(p, store).display)),
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

// MARK: - Origin

/// Why is it running, and who does it belong to: a chain read top to bottom, then the reverse relations.
struct OriginTab: View {
    @Environment(Store.self) var store
    let proc: ProcInfo
    var exited = false
    @State private var loadedKey: String?
    @State private var job: (title: String, text: String)?
    @State private var procinfo: (title: String, text: String)?
    @State private var args: Native.ArgsEnv?
    @State private var argsLoaded = false

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
                command(p)
                relations(p)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Reload when the process registers with LaunchServices or launchd, execs, or on a manual refresh.
        .task(id: "\(p.codeKey)|\(p.launchdLabel ?? "")|\(store.fullRefreshGen)|\(exited)|\(store.helperState.isRunning)") {
            guard !exited else { return }   // keep what was shown; the pid may be someone else's now
            if loadedKey != p.key { job = nil; procinfo = nil; args = nil; argsLoaded = false }
            let label = p.launchdLabel, pid = p.pid, start = p.start, key = p.key
            let helper = store.helperState.isRunning
            let (j, pi, a) = await Task.detached { () -> ((String, String)?, (String, String)?, Native.ArgsEnv?) in
                let j = label.map { ("launchctl print \($0)", Launchd.printJob($0)) }
                let pi = helper ? ("launchctl procinfo \(pid) (as root via helper)",
                                   HelperClient.shared.run(.launchctlProcinfo, pid: pid) ?? "helper did not answer") : nil
                let a: Native.ArgsEnv? = Native.argsEnv(pid) ?? {
                    guard helper, let r = HelperClient.shared.argsEnv(pid) else { return nil }
                    return Native.ArgsEnv(execPath: r.execPath, args: r.args, env: r.env)
                }()
                return (j, pi, Native.isSame(pid, start: start) ? a : nil)
            }.value
            guard !Task.isCancelled else { return }
            job = j; procinfo = pi; args = a; argsLoaded = true; loadedKey = key
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
                if let ls = store.lsApps.first(where: { $0.pid == p.pid }) {
                    Text("LaunchServices: registered as the app \u{201C}\(ls.name)\u{201D} (\(ls.type ?? "?")).")
                    Collapsible(title: "LaunchServices record", startsOpen: false) { LSRecordContent(raw: ls.raw, filter: "") }
                }
                if let e = p.extensionPoint {
                    Text("App extension for \(ExtensionInfo.title(e)) (\(e))\(p.containingAppName.map { ", inside \($0)" } ?? "").")
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
                    ])
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
                } else if store.lsApps.first(where: { $0.pid == p.pid }) == nil, p.extensionPoint == nil {
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

    // 5. Command: argv, environment and working directory, collapsed.
    @ViewBuilder private func command(_ p: ProcInfo) -> some View {
        Card(title: "Command", systemImage: "terminal") {
            if let a = args {
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
            } else {
                Text(exited ? "The process has exited; its arguments can't be read any more."
                     : argsLoaded ? "Arguments not readable (another user's process; the helper can read them)." : "Reading…")
                    .foregroundStyle(.secondary)
            }
        }
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
        Card(title: "Related processes", systemImage: "circle.grid.cross") {
            VStack(alignment: .leading, spacing: 8) {
                group("Children", children)
                group("Responsible for", attributed)
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
                Card(title: "Sandbox", systemImage: "square.dashed") {
                    Text(proc.sandboxed.map { $0 ? "Sandboxed (App Sandbox)." : "Not sandboxed." } ?? "Unknown: the sandbox state couldn't be read.")
                }
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
