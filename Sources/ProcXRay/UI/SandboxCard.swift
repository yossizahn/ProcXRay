import SwiftUI

/// Whether the process is sandboxed and, if it is, what the kernel says its sandbox lets it do right now.
struct SandboxCard: View {
    let proc: ProcInfo
    var exited = false
    let entitlements: [String: Any]
    @State private var report: SandboxProbes.Report?
    @State private var gone = false
    @State private var checkedAt: Date?

    var body: some View {
        Card(title: "Sandbox", systemImage: "square.dashed") {
            Text(Self.summary(proc.sandboxed, entitlements: entitlements)).fixedSize(horizontal: false, vertical: true)
            if proc.sandboxed == true && !exited {
                if gone {
                    Text("The process exited before its sandbox could be checked.").foregroundStyle(.secondary)
                } else if let r = report {
                    SandboxProbeTable(report: r, entitlements: entitlements, checkedAt: checkedAt) {
                        Task { await recheck() }
                    }
                }
                Divider()
                SandboxProfileSection(proc: proc)
            }
        }
        .task(id: proc.key) { await recheck() }
    }

    static func summary(_ sandboxed: Bool?, entitlements: [String: Any]) -> String {
        switch sandboxed {
        case true?:
            isAppSandbox(entitlements) ? "Sandboxed (App Sandbox)."
                : "Sandboxed, but not by the App Sandbox entitlement: a system profile, one inherited from its parent, or sandbox-exec."
        case false?: "Not sandboxed."
        case nil: "Unknown: the sandbox state couldn't be read."
        }
    }

    static func isAppSandbox(_ e: [String: Any]) -> Bool { e["com.apple.security.app-sandbox"] as? Bool == true }

    /// Off the main thread: usually under 1 ms, but the first checks of a process took 28–40 ms here.
    private func recheck() async {
        guard proc.sandboxed == true, !exited else { return }
        let pid = proc.pid, start = proc.start
        report = await Task.detached { SandboxProbes.run(pid: pid, start: start) }.value
        gone = report == nil
        checkedAt = Date()
    }
}

/// The checks' answers: files by location (read, write), then other capabilities, then network.
struct SandboxProbeTable: View {
    let report: SandboxProbes.Report
    let entitlements: [String: Any]
    var checkedAt: Date?
    var recheck: (() -> Void)?

    private var appSandbox: Bool { SandboxCard.isAppSandbox(entitlements) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow {
                    Text("Files").font(.subheadline.weight(.semibold))
                    Text("Read").font(.subheadline.weight(.semibold))
                    Text("Write").font(.subheadline.weight(.semibold))
                }
                ForEach(report.locations) { l in
                    GridRow {
                        Text(l.id).foregroundStyle(.secondary).help(l.path ?? "Doesn't exist here, so it can't be checked.")
                        mark(l.read)
                        mark(l.write)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal).padding(.vertical, 3)
                ForEach(report.capabilities) { c in
                    GridRow {
                        Text(c.id).foregroundStyle(.secondary).help(c.detail)
                        mark(c.verdict)
                    }
                }
            }
            // Not a grid row: its long text would widen the verdict columns.
            (Text("Network ").foregroundStyle(.secondary) + Text(network).foregroundStyle(appSandbox ? .primary : .secondary))
                .fixedSize(horizontal: false, vertical: true)
                .help("The kernel can't be asked about network access this way, so this comes from the entitlements.")
            HStack(alignment: .firstTextBaseline) {
                Text("Asked of the kernel (sandbox_check), so it includes folders the user has granted since launch. Privacy permissions (camera, Desktop, …) are a separate gate: “allowed” here can still be refused by Privacy & Security.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if let recheck {
                    Button("Check again", action: recheck).controlSize(.small)
                        .help(checkedAt.map { "Last checked \($0.formatted(date: .omitted, time: .standard))" } ?? "")
                }
            }
        }
    }

    private var network: String {
        guard appSandbox else { return "unknown (can't be checked, and no App Sandbox entitlements to go by)." }
        let out = entitlements["com.apple.security.network.client"] as? Bool == true
        let inc = entitlements["com.apple.security.network.server"] as? Bool == true
        return "(from entitlements): outgoing \(out ? "allowed" : "denied"), incoming \(inc ? "allowed" : "denied")."
    }

    @ViewBuilder private func mark(_ v: SandboxProbes.Verdict) -> some View {
        switch v {
        case .allowed: Label("allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .denied: Label("denied", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        case .unknown: Text("—").foregroundStyle(.secondary).help("Couldn't be checked.")
        }
    }
}

/// The profile it was compiled with: secinitd's cached copy and the inputs it was built from.
struct SandboxProfileSection: View {
    let proc: ProcInfo
    @State private var result: Result<SandboxProfileInfo, SandboxProfileInfo.Failure>?

    /// `preloaded`: the result already read, for rendering without running the task (Bench).
    init(proc: ProcInfo, preloaded: Result<SandboxProfileInfo, SandboxProfileInfo.Failure>? = nil) {
        self.proc = proc
        _result = State(initialValue: preloaded)
    }
    @State private var shownSource: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Compiled profile").font(.subheadline.weight(.semibold))
            switch result {
            case nil: ProgressView().controlSize(.small)
            case .failure(let f)?: Text(Self.text(f)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if case .needsFullDiskAccess = f {
                    Button("Open Full Disk Access settings") { FullDiskAccess.openSettings() }.controlSize(.small)
                }
            case .success(let i)?: details(i)
            }
        }
        .task(id: proc.key) {
            guard result == nil else { return }
            let pid = proc.pid
            result = await Task.detached { SandboxProfileInfo.read(pid: pid) }.value
        }
    }

    static func text(_ f: SandboxProfileInfo.Failure) -> String {
        switch f {
        case .notSandboxed: "Not sandboxed."
        case .noContainer: "No container, so no cached profile: it runs under a named system profile, one inherited from its parent, or sandbox-exec. macOS doesn't let other processes read those."
        case .needsFullDiskAccess: "Not readable without Full Disk Access for Proc X-Ray: macOS protects the cache it's kept in."
        case .unreadable(let p): "The container's metadata couldn't be read (\(p))."
        case .noCache(let p): "The container's metadata has no cached profile (\(p))."
        }
    }

    @ViewBuilder private func details(_ i: SandboxProfileInfo) -> some View {
        let changed = i.sources.filter(\.changed)
        Text(summary(i, changed: changed.count)).fixedSize(horizontal: false, vertical: true)
        if i.compiledByOtherBuild {
            Label("Compiled by a different libsandbox (\(i.buildID ?? "?")) than this system's (\(i.currentBuildID ?? "?")): it will be rebuilt at next launch.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
        Text("Source files").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(i.sources) { s in
                HStack(spacing: 6) {
                    Button(shownSource == s.path ? "Hide" : "Show") { shownSource = shownSource == s.path ? nil : s.path }
                        .controlSize(.mini)
                    Text(verbatim: s.path).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    if s.changed {
                        Text(s.currentDate == nil ? "gone" : "changed since").font(.caption).foregroundStyle(.orange)
                            .help("Modified \(s.currentDate?.formatted() ?? "—"); the profile was built from the version of \(s.compiledDate?.formatted() ?? "—").")
                    }
                }
                if shownSource == s.path {
                    MonoText(text: (try? String(contentsOfFile: s.path, encoding: .utf8)) ?? ";; Couldn't read \(s.path).", sbpl: true)
                        .frame(height: 260)
                }
            }
        }
        Text("Parameters").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
            ForEach(i.parameters, id: \.0) { k, v in
                GridRow {
                    Text(verbatim: k).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        .help(SandboxProfileInfo.describe(param: k) ?? "")
                    Text(verbatim: v).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
        if !i.redirectedPaths.isEmpty {
            Text(verbatim: "Redirected into the container: " + i.redirectedPaths.joined(separator: ", "))
                .font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        if !i.systemImages.isEmpty {
            DisclosureGroup("Frameworks that added their own rules (\(i.systemImages.count))") {
                Text(verbatim: i.systemImages.joined(separator: "\n")).font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
        }
        if let data = i.profileData {
            SandboxRulesView(data: data)
        }
        HStack {
            Text("From secinitd's cache next to the container, written when the app last launched. Folders granted after launch are added on top and don't appear here; the checks above include them.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Reveal") { NSWorkspace.shared.selectFile(i.metadataPath, inFileViewerRootedAtPath: "") }
                .controlSize(.small).help(i.metadataPath)
        }
    }

    private func summary(_ i: SandboxProfileInfo, changed: Int) -> String {
        var s = "Built from \(i.sources.count) source file\(i.sources.count == 1 ? "" : "s"), \(i.parameters.count) parameters and \(i.entitlementCount) entitlements"
        if let n = i.compiledSize { s += "; \(ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)) compiled" }
        s += "."
        if changed > 0 { s += " \(changed) source file\(changed == 1 ? " has" : "s have") changed since." }
        return s
    }
}

/// The compiled profile decoded back into readable SBPL rules, with a search field. Decoding runs the first
/// time the group is opened (it's a few milliseconds, but there's no reason to do it for every process).
struct SandboxRulesView: View {
    let data: Data
    @State private var expanded = false
    @State private var ruleset: SandboxRules.Ruleset?
    @State private var failure: String?
    @State private var query = ""

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if let rs = ruleset {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Filter by operation or rule text", text: $query)
                        .textFieldStyle(.roundedBorder).controlSize(.small)
                    MonoText(text: text(rs), sbpl: true).frame(height: 320)
                    Text("Each operation's effective policy, reconstructed from the compiled profile. These describe what the kernel enforces; they aren't the original source and don't necessarily recompile to the same bytes (the compiler merges wildcard and inherited rules into each operation).")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else if let why = failure {
                Text("Couldn't decode the rules: \(why)").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView().controlSize(.small)
            }
        } label: {
            Text("Decoded rules\(ruleset.map { " (\($0.operations.count) operations)" } ?? "")")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .font(.caption)
        // Decode on first expand. .task re-runs if the view reappears, so an interrupted decode restarts.
        .task(id: expanded) {
            guard expanded, ruleset == nil, failure == nil else { return }
            let data = self.data
            let result = await Task.detached(priority: .userInitiated) {
                Result { try SandboxRules.build(data: data) }
            }.value
            switch result {
            case .success(let rs?): ruleset = rs
            case .success(nil): failure = "libsandbox name tables unavailable"
            case .failure(let e): failure = "\(e)"
            }
        }
    }

    /// The default rule, then operations whose name or rules contain the query (case-insensitive).
    private func text(_ rs: SandboxRules.Ruleset) -> String {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var lines = [rs.defaultRule]
        for op in rs.operations {
            if q.isEmpty || op.name.lowercased().contains(q) || op.rules.contains(where: { $0.lowercased().contains(q) }) {
                lines.append(contentsOf: op.rules)
            }
        }
        if lines.count == 1 && !q.isEmpty { lines.append(";; no operation matches “\(query)”") }
        return lines.joined(separator: "\n")
    }
}

enum FullDiskAccess {
    static func openSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(u) }
    }
}
