import AppKit
import SwiftUI

/// Empty bottom-pane placeholder (same frame as real content so the split never jumps).
struct PanePlaceholder: View {
    let text: String
    var body: some View {
        Text(verbatim: text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Background Task Management

struct BackgroundItemsView: View {
    @Environment(Store.self) var store
    @State private var selection: Set<BTMItem.ID> = []
    @State private var search = ""
    @AppStorage("background.onlyEnabled") private var onlyEnabled = false

    var body: some View {
        let items = store.btm.filter { i in
            (!onlyEnabled || i.enabled) &&
            (search.isEmpty || [i.name, i.identifier, i.developer, i.teamID, i.executable, i.url, i.bundleID, i.type]
                .contains { $0.localizedCaseInsensitiveContains(search) })
        }
        if store.btm.isEmpty && !store.btmLoading {
            VStack(spacing: 10) {
                if let e = store.btmError {
                    Label("Couldn't load background items", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.headline)
                    Text(verbatim: e).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(12).help(e).frame(maxWidth: 560)
                    Divider().frame(maxWidth: 560)
                } else if store.btmLoaded {
                    Text("sfltool dumpbtm returned no background item records.").font(.headline)
                }
                Image(systemName: store.helperState.isRunning ? "gearshape.2" : "lock.shield")
                    .font(.largeTitle).foregroundStyle(.secondary)
                Text(verbatim: store.helperState.isRunning
                     ? "Background items are loaded on request."
                     : "The Background Task Management database is root-only.")
                Text(verbatim: store.helperState.isRunning
                     ? "The privileged helper reads it as root — no password needed."
                     : "Reading it runs `sfltool dumpbtm`, which asks for your admin password every time.")
                    .foregroundStyle(.secondary)
                Button(store.helperState.isRunning ? "Load Background Items (via root helper)" : "Load Background Items (asks for password)") { store.loadBTM() }
                    .controlSize(.large)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Background Items")
        } else {
            btmTable(items)
        }
    }

    /// The launchd job for an item: a running process with the item's executable that is a job's main
    /// process, else a job whose label the item's identifier names.
    private func job(for i: BTMItem) -> (label: String, pid: pid_t?)? {
        if !i.executable.isEmpty,
           let p = store.procs.values.first(where: { $0.path == i.executable && $0.launchdLabel != nil }) {
            return (p.launchdLabel!, p.pid)
        }
        guard !i.identifier.isEmpty else { return nil }
        let j = (store.jobs + store.otherJobs).first { i.identifier == $0.label || i.identifier.hasSuffix("." + $0.label) }
        return j.map { ($0.label, $0.pid) }
    }

    /// The launchd job a record installed is matched as the Launch tab matches: executable path, then label.
    /// Double-click or the context menu shows its process; the menu also reveals the target in Finder.
    private var columns: [DataColumn<BTMItem>] {
        [
            DataColumn(id: "name", title: "Name", width: 220, minWidth: 140, text: \.name,
                       dot: { $0.enabled ? .systemGreen : .tertiaryLabelColor },
                       tooltip: { $0.enabled ? "Enabled" : "Disabled" },
                       less: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }),
            .text("type", "Type", width: 140, \.type),
            .text("disposition", "Disposition", width: 220, color: { _ in .secondaryLabelColor }, \.disposition),
            .text("developer", "Developer", width: 150, \.developer),
            .text("team", "Team", width: 90, mono: true, \.teamID),
            .text("target", "Target", width: 260, color: { _ in .secondaryLabelColor }) { $0.executable.ifEmpty($0.url) },
            .text("job", "Job", width: 220) { i in job(for: i).map { j in j.pid.map { "\(j.label) (\($0))" } ?? j.label } ?? "" },
            .text("lastUse", "Last use", width: 150, \.lastUse),
            .number("uid", "UID", width: 44, value: { Int($0.uid) }, format: { String($0) }),
        ]
    }

    @ViewBuilder
    private func btmTable(_ items: [BTMItem]) -> some View {
        SplitPane(id: "btm", defaultFraction: 0.65) {
            DataTable(rows: items, columns: columns, initialSort: ("name", true), autosave: "backgroundItems", live: true, selection: $selection,
                      menu: { rows in
                          guard rows.count == 1, let i = rows.first else { return [] }
                          var items: [DataMenuItem] = []
                          if let pid = job(for: i)?.pid { items.append(DataMenuItem(title: "Show in Processes") { AppRouter.shared.show(pid) }) }
                          if let path = Reveal.path(in: i.executable.ifEmpty(i.url)) {
                              items.append(DataMenuItem(title: "Reveal in Finder") { Reveal.reveal([path]) })
                          }
                          return items
                      },
                      onOpen: { i in if let pid = job(for: i)?.pid { AppRouter.shared.show(pid) } },
                      exportName: "Background Items")
        } bottom: {
            if selection.count == 1, let id = selection.first, let i = store.btm.first(where: { $0.id == id }) {
                KV(rows: i.fields.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
                   + (i.embedded.isEmpty ? [] : [("Embedded items", i.embedded.joined(separator: "\n"))]))
            } else {
                PanePlaceholder(text: "Select a background item")
            }
        }
        .searchable(text: $search, placement: .toolbar)
        .toolbar {
            Toggle("Enabled only", isOn: $onlyEnabled)
            Button { store.loadBTM() } label: { Label(store.helperState.isRunning ? "Reload" : "Reload (asks for password)", systemImage: "arrow.clockwise") }
                .disabled(store.btmLoading)
                .help(store.helperState.isRunning ? "Runs sfltool dumpbtm as root via the helper" : "Runs sfltool dumpbtm, which requires admin authorization")
            if store.btmLoading { ProgressView().controlSize(.small) }
        }
        .navigationTitle("Background Items")
        .navigationSubtitle(store.btmError.map { "Last reload failed: \($0.split(separator: "\n").first ?? "")" }
                            ?? "sfltool dumpbtm — \(store.btm.count) records, loaded on request only")
    }
}

// MARK: - launchd

struct LaunchdView: View {
    @Environment(Store.self) var store
    @State private var selected: Set<LaunchdJob.ID> = []
    private var selection: LaunchdJob.ID? { selected.count == 1 ? selected.first : nil }
    @State private var search = ""
    @AppStorage("launchd.runningOnly") private var runningOnly = true
    @State private var detail = ""
    /// Label → plist path, read once when the view appears.
    @State private var plists: [String: String] = [:]

    var body: some View {
        let procs = store.procs
        // The gui domain (launchctl list, every job) and the running jobs of the system and user domains.
        let all = store.jobs + store.otherJobs
        let jobs = all.filter {
            (!runningOnly || $0.pid != nil) && (search.isEmpty || $0.label.localizedCaseInsensitiveContains(search))
        }
        let current = selection.flatMap { s in all.first { $0.id == s } }
        SplitPane(id: "launchd", defaultFraction: 0.6) {
            DataTable(rows: jobs, columns: [
                .text("label", "Label", width: 340, \.label),
                .text("domain", "Domain", width: 60, color: { _ in .secondaryLabelColor }, \.domain),
                .number("pid", "PID", width: 60, value: { $0.pid }, format: { String($0) }),
                .text("lastExit", "Last exit", width: 70,
                      color: { $0.lastExit == "0" || $0.lastExit == "-" ? .secondaryLabelColor : .systemRed }, \.lastExit),
                .text("process", "Process", width: 260, color: { _ in .secondaryLabelColor }) { j in j.pid.flatMap { procs[$0]?.path } ?? "" },
                .text("plist", "Plist", width: 260, color: { _ in .secondaryLabelColor }) { plists[$0.label] ?? "" },
            ], initialSort: ("label", true), autosave: "launchdJobs", live: true, selection: $selected,
                      menu: { rows in
                          guard rows.count == 1, let j = rows.first else { return [] }
                          var items: [DataMenuItem] = []
                          if let pid = j.pid { items.append(DataMenuItem(title: "Show in Processes") { AppRouter.shared.show(pid) }) }
                          if let path = j.pid.flatMap({ procs[$0]?.path }) { items.append(DataMenuItem(title: "Reveal Process in Finder") { Reveal.reveal([path]) }) }
                          if let plist = plists[j.label] { items.append(DataMenuItem(title: "Reveal Plist in Finder") { Reveal.reveal([plist]) }) }
                          return items
                      },
                      onOpen: { j in if let pid = j.pid { AppRouter.shared.show(pid) } },
                      exportName: "launchd Jobs")
        } bottom: {
            if selection != nil, current == nil {
                PanePlaceholder(text: "\(selection ?? "") is no longer loaded in launchd")
            } else if let current {
                VStack(spacing: 0) {
                    if let pid = current.pid {
                        HStack {
                            Text(verbatim: "pid \(pid)").foregroundStyle(.secondary)
                            Button("Show in Processes") { AppRouter.shared.show(pid) }.controlSize(.small)
                            Spacer()
                        }
                        .padding(6)
                        Divider()
                    }
                    if detail == "loading…" { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                    else { OutputPane(raw: detail, filterable: true) { f in KVTreeView(text: detail, filter: f) } }
                }
            } else { PanePlaceholder(text: "Select a job to see launchctl print") }
        }
        // The label stays the same when the job restarts or is removed: reload when its row changes,
        // and on a manual refresh (run counts and other details aren't in the row).
        .task(id: "\(selection ?? "")|\(current.map { "\($0)" } ?? "gone")|\(store.fullRefreshGen)") {
            guard let current else { return }
            detail = "loading…"
            let (label, domain) = (current.label, current.domain)
            let d = await Task.detached { Launchd.printJob(label, domain: domain) }.value
            guard !Task.isCancelled else { return }   // selection moved on while launchctl ran
            detail = d
        }
        .task { if plists.isEmpty { plists = await Task.detached { Launchd.plistPaths() }.value } }
        .searchable(text: $search, placement: .toolbar)
        .toolbar { Toggle("Running only", isOn: $runningOnly) }
        .navigationTitle("launchd Jobs")
        .navigationSubtitle("gui/\(getuid()), with the running jobs of system and user/\(getuid()) — \(all.count) jobs")
    }
}

// MARK: - CLI self-test (`ProcXRay --dump`) used to cross-check against ps / lsappinfo

enum SelfTest {
    @MainActor static func run() {
        let snap = Store.snapshot(prev: [:], signCache: [:])
        if let e = snap.error { print(e); exit(1) }
        let procs = snap.procs
        print("processes: \(procs.count)")
        print("team id: \(HelperConfig.teamID ?? "none")  requirement: \(HelperConfig.peerRequirement)")
        let hs = HelperClient.shared.probe()
        print("helper: \(hs.label)")
        if hs.isRunning {
            let t0 = Date()
            let priv = HelperClient.shared.allMetrics() ?? [:]
            let merged = Store.snapshot(prev: [:], signCache: [:], priv: { priv }).procs
            print("helper metrics: \(priv.count) pids, \(priv.values.filter { $0.rss != nil }.count) with task info, \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            print("merged readable task info: \(merged.values.filter(\.isInspectable).count) / \(merged.count) (via helper: \(merged.values.filter(\.viaHelper).count))")
            if let ld = merged[1] { print("launchd via helper: rss=\(ld.rss ?? 0) threads=\(ld.threads ?? -1)") }
            let a = HelperClient.shared.argsEnv(1)
            print("launchd argv via helper: \(a?.args ?? []) env=\(a?.env.count ?? -1) cwd=\(a?.cwd ?? "-")")
            let pi = HelperClient.shared.run(.launchctlProcinfo, pid: 1) ?? ""
            print("procinfo(1) lines: \(pi.split(separator: "\n").count)")
        }
        print("readable task info: \(procs.values.filter(\.isInspectable).count)")
        print("with responsible pid: \(procs.values.filter { $0.responsible != nil }.count)")
        print("with coalition: \(procs.values.filter { $0.coalition != nil }.count)")
        print("ls apps: \(snap.ls.count), exited: \(snap.ls.filter(\.exited).map(\.name))")
        print("ls apps with coalition id: \(snap.ls.filter { $0.coalition != nil }.count)")
        for a in snap.ls where !a.relatedCoalitionPIDs.isEmpty {
            print("ls \(a.name) pid \(a.pid ?? -1) coal \(a.coalition ?? 0) members \(a.coalitionPIDs) related \(a.relatedCoalitionIDs)/\(a.relatedCoalitionPIDs)")
        }
        print("launchd jobs: \(snap.jobs.count), running: \(snap.jobs.filter { $0.pid != nil }.count)")
        // Every grouping must place each process exactly once, with unique row ids.
        let store = Store(); store.procs = procs; store.lsApps = snap.ls
        for g in Grouping.allCases {
            let roots = store.nodes(grouping: g, filter: "", sort: .pid)
            var ids: [Int] = [], pids: [pid_t] = []
            func walk(_ n: ProcNode) { ids.append(n.id); if let p = n.proc { pids.append(p.pid) }; n.children?.forEach(walk) }
            roots.forEach(walk)
            let ok = Set(ids).count == ids.count && pids.count == procs.count && Set(pids) == Set(procs.keys)
            print("grouping \(g.label): \(roots.count) roots, \(pids.count) procs, \(ids.count) rows — \(ok ? "ok" : "MISMATCH")")
            if g == .smart {
                for c in roots {
                    let subs = (c.children ?? []).filter { $0.kind == .group }.map { "\($0.title) \($0.totalCount)" }
                    print("  \(c.title): \(c.unitCount) top-level, \(c.totalCount) procs, \(Fmt.pct(c.cpuKey)) %, \(Fmt.bytes(c.memKey))"
                          + (subs.isEmpty ? "" : " — " + subs.joined(separator: ", ")))
                }
                // Role groups inside units: the units with any, and their shape.
                func units(_ n: ProcNode) -> [ProcNode] { n.kind == .unit ? [n] : (n.children ?? []).flatMap(units) }
                func shape(_ n: ProcNode, _ depth: Int) -> [String] {
                    guard n.proc == nil, depth < 6 else { return [] }
                    let line = String(repeating: "  ", count: depth) + "\(n.title) (\(n.totalCount))" + (n.subtitle.isEmpty ? "" : " — \(n.subtitle)")
                    return [line] + (n.children ?? []).flatMap { shape($0, depth + 1) }
                }
                for u in roots.flatMap(units) where (u.children ?? []).contains(where: { $0.proc == nil }) {
                    let lone = (u.children ?? []).filter { $0.proc != nil }.count
                    print(shape(u, 2).joined(separator: "\n") + "  [\(lone) rows directly under it]")
                    if ProcessInfo.processInfo.environment["DUMP_ROLES"] != nil {
                        for g in u.children ?? [] where g.proc == nil {
                            let names = Dictionary(grouping: g.children ?? [], by: { $0.title }).map { "\($0.key)×\($0.value.count)" }
                            print("      \(g.title): \(names.sorted().joined(separator: ", "))")
                        }
                    }
                }
                let other = roots.first { $0.category == .other }?.children ?? []
                if !other.isEmpty { print("  other: \(other.prefix(8).map { "\($0.title)(\($0.proc?.path ?? "-"))" })") }
            }
        }
        // Group-row values with every column shown: one line per category, and the first app's row.
        let all = Set(Column.all.map(\.id))
        let smart = store.nodes(grouping: .smart, filter: "", sort: ColumnSort(id: "mem", ascending: false), columns: all)
        func values(_ n: ProcNode) -> String {
            Column.all.compactMap { c in n.groupValues[c.id].flatMap { $0.hasValue ? "\(c.id)=\($0.display)" : nil } }
                .joined(separator: " ")
        }
        for c in smart { print("values \(c.title): \(values(c))") }
        // Sorting inside the tree (Keep Groups When Sorting): each category's children by summed memory.
        for c in smart {
            let mems = (c.children ?? []).map { $0.sortValue.number ?? 0 }
            print("sorted by memory in \(c.title): \(mems == mems.sorted(by: >) ? "ok" : "OUT OF ORDER") (first: \(c.children?.first?.title ?? "-"))")
        }
        if let app = smart.first?.children?.first { print("values \(app.title): \(values(app))") }
        for g in Store.ghosts(procs: procs, lsApps: snap.ls) {
            print("left behind by \(g.name) (\(g.detail)): \(g.survivors.map { "\($0.name)(\($0.pid))" })")
        }
        // Inspector tab names an earlier version stored, and where they open now.
        print("inspector tabs: " + ["Overview", "Origin", "Trust", "Resources", "Connections", "Activity", "Files & Ports", "Bogus"]
            .map { "\($0)→\(InspectorTab(stored: $0)?.rawValue ?? "nil")" }.joined(separator: ", "))
        let me = getpid()
        if let p = procs[me] {
            print("self: \(p.name) pid \(p.pid) ppid \(p.ppid) resp \(p.responsible ?? -1) coal \(p.coalition ?? 0) fp \(Fmt.bytes(p.footprint))")
            let s = CodeSign.inspect(pid: me, path: p.path)
            print("self sign: \(s.shortSigner) id=\(s.identifier ?? "-") flags=\(s.runtimeFlagNames)")
        }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--pid"), i + 1 < args.count, let pid = pid_t(args[i + 1]), let p = procs[pid] {
            print("pid \(pid): name=\(p.name) ppid=\(p.ppid) resp=\(p.responsible ?? -1) coal=\(p.coalition ?? 0) user=\(p.user) rss=\(p.rss ?? 0) threads=\(p.threads ?? -1) sandbox=\(String(describing: p.sandboxed)) label=\(p.launchdLabel ?? "-")")
            let s = CodeSign.inspect(pid: pid, path: p.path)
            print("  sign: \(s.shortSigner) team=\(s.teamID ?? "-") id=\(s.identifier ?? "-") ents=\(s.entitlementKeys.count) status=\(s.runtimeFlagNames)")
            if let a = Native.argsEnv(pid) { print("  argv: \(a.args) env count: \(a.env.count)") }
            print("  cwd: \(Native.cwd(pid) ?? "-")")
            if let c = p.counters {
                print("  counters: running=\(c.runningThreads ?? 0) csw=\(c.contextSwitches ?? 0) faults=\(c.faults ?? 0) cow=\(c.cowFaults ?? 0) pageins=\(c.pageins ?? 0) msgsent=\(c.machMsgsSent ?? 0) msgrecv=\(c.machMsgsReceived ?? 0) sysbsd=\(c.unixSyscalls ?? 0) sysmach=\(c.machSyscalls ?? 0)")
                print("  counters: instrs=\(c.instructions ?? 0) cycles=\(c.cycles ?? 0) cpu=\(p.cpuNanos ?? 0)ns pcore=\(c.pCoreNanos ?? 0)ns waiting=\(c.waitingNanos ?? 0)ns peak=\(c.peakFootprint ?? 0) neural=\(c.neuralFootprint ?? 0) logical=\(c.logicalWrites ?? 0)")
            }
        }
        // `sfltool dumpbtm` prompts for an admin password, so only run it when explicitly asked.
        if args.contains("--btm") {
            let btm = BTM.dump()
            print("btm records: \(btm.count), enabled: \(btm.filter(\.enabled).count)")
        }
    }
}

/// The big button in the middle of a tab that hasn't run yet (Memory, Sample, Logs, Syscalls).
struct EmptyRunButton: View {
    let title: String
    var systemImage = "play.fill"
    var disabledReason: String? = nil
    var help = ""
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage).padding(.horizontal, 6)
        }
        .buttonStyle(.borderedProminent).controlSize(.large)
        .disabled(disabledReason != nil)
        .help(disabledReason ?? help)
    }
}
