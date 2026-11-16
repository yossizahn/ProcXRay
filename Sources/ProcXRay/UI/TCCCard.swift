import SwiftUI

/// Privacy & Security decisions that apply to the process: TCC's recorded answers for the app responsible for it,
/// and the services Apple's entitlements grant it outright.
struct TCCCard: View {
    let proc: ProcInfo
    /// The app TCC attributes it to (itself when it's its own responsible process).
    let responsible: ProcInfo?
    let entitlements: [String: Any]
    @State private var report: TCCGrants.Report?

    /// `preloaded`: the report already read, for rendering without running the task (Bench).
    init(proc: ProcInfo, responsible: ProcInfo?, entitlements: [String: Any], preloaded: TCCGrants.Report? = nil) {
        self.proc = proc
        self.responsible = responsible
        self.entitlements = entitlements
        _report = State(initialValue: preloaded)
    }

    private var owner: ProcInfo { responsible ?? proc }

    var body: some View {
        Card(title: "Privacy permissions (TCC)", systemImage: "hand.raised") {
            Text(attribution).fixedSize(horizontal: false, vertical: true)
            if let r = report {
                if r.grants.isEmpty {
                    Text("No decisions recorded for \(clientList).").foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    grantsGrid(r.grants)
                }
                availability(r)
            } else {
                ProgressView().controlSize(.small)
            }
            let builtIn = TCCGrants.builtIn(entitlements)
            if !builtIn.isEmpty {
                Text("Granted by its entitlements").font(.subheadline.weight(.semibold))
                Text(builtIn.map { TCCGrants.displayName($0.service) + ($0.overridable ? " (can be turned off)" : "") }.joined(separator: ", "))
                    .fixedSize(horizontal: false, vertical: true)
                    .help(builtIn.map(\.service).joined(separator: "\n"))
                Text("com.apple.private.tcc.allow: Apple's own binaries get these without a prompt or a database row.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: proc.key) {
            guard report == nil else { return }
            let c = clients
            report = await Task.detached { TCCGrants.read(clients: c) }.value
        }
    }

    /// What TCC can have filed the decisions under: bundle IDs, and executable paths for bare tools.
    var clients: Set<String> {
        var s: Set<String> = []
        for p in [owner, proc] {
            if let path = p.path { s.insert(path) }
            // Any bundle (.app, .xpc, .appex): the folder holding Contents/MacOS/<executable>.
            if let path = p.path, let r = path.range(of: "/Contents/MacOS/", options: .backwards),
               let id = Bundle(path: String(path[..<r.lowerBound]))?.bundleIdentifier { s.insert(id) }
        }
        return s
    }

    private var clientList: String { clients.sorted().joined(separator: ", ") }

    private var attribution: String {
        if let r = responsible, r.pid != proc.pid {
            return "TCC answers for the responsible app, \(r.name) (\(r.pid)), so these are its decisions."
        }
        return "TCC answers for the process itself: it is its own responsible process."
    }

    private func grantsGrid(_ g: [TCCGrants.Grant]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            ForEach(g) { x in
                GridRow(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(TCCGrants.displayName(x.service) + (x.target.map { " → \($0)" } ?? ""))
                            .help(x.service + (x.target.map { "\ntarget: \($0)" } ?? ""))
                        // The record's own fields, on a detail line rather than in a tooltip.
                        Text(verbatim: "changed \(x.modified?.formatted() ?? "—") · \(x.database.rawValue) database · \(x.clientIsPath ? "path" : "bundle ID") \(x.client)")
                            .font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
                    }
                    Text(TCCGrants.decision(x.authValue))
                        .foregroundStyle(x.authValue == 2 ? .green : x.authValue == 0 ? .red : .secondary)
                    Text(TCCGrants.reason(x.authReason)).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func availability(_ r: TCCGrants.Report) -> some View {
        let lines: [String] = [note("System database", r.system), note("User database", r.user)].compactMap { $0 }
        ForEach(lines, id: \.self) { l in
            Text(l).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if case .needsFullDiskAccess = r.user {
            Button("Open Full Disk Access settings") { FullDiskAccess.openSettings() }
            .controlSize(.small)
        }
    }

    private func note(_ what: String, _ a: TCCGrants.Availability) -> String? {
        switch a {
        case .read: nil
        case .needsFullDiskAccess: "\(what) not read: it needs Full Disk Access for Proc X-Ray, so camera, microphone, contacts, photos, files and folders, and automation aren't shown."
        case .sipProtected: "\(what) not read: macOS keeps it in a container that only TCC itself can open while System Integrity Protection is on (Full Disk Access isn't enough, even as root), so camera, microphone, contacts, photos, files and folders, and automation aren't shown."
        case .missing: "\(what) not found."
        case .failed(let m): "\(what) couldn't be read: \(m)"
        }
    }
}
