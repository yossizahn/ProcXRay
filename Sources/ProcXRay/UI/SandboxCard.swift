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
