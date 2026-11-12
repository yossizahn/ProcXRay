import Darwin
import Foundation

/// `ProcXRay --bench`: times each stage of a refresh tick, in wall-clock and this process's CPU time.
/// Child-process CPU (lsappinfo, launchctl) is reported separately via RUSAGE_CHILDREN.
enum Bench {
    @MainActor static func run() {
        let n = 20
        func cpu(_ who: Int32) -> Double {
            var r = rusage(); getrusage(who, &r)
            return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
        }
        func time(_ label: String, _ body: () -> Void) {
            let w0 = Date(), c0 = cpu(RUSAGE_SELF), k0 = cpu(RUSAGE_CHILDREN)
            for _ in 0..<n { body() }
            let w = Date().timeIntervalSince(w0) / Double(n) * 1000
            let c = (cpu(RUSAGE_SELF) - c0) / Double(n) * 1000
            let k = (cpu(RUSAGE_CHILDREN) - k0) / Double(n) * 1000
            print(String(format: "%-28@ wall %7.2f ms   cpu %7.2f ms   children cpu %6.2f ms", label as NSString, w, c, k))
        }
        let helper = HelperClient.shared.probe().isRunning
        print("helper running: \(helper); \(n) iterations each")
        time("lsappinfo list (spawn)") { _ = Shell.run("/usr/bin/lsappinfo", ["list"]) }
        let lsText = Shell.run("/usr/bin/lsappinfo", ["list"])
        time("lsappinfo parse") { _ = LSAppInfo.parse(lsText) }
        time("launchctl list") { _ = Launchd.list() }
        time("sysctl allProcesses") { _ = Native.allProcesses() }
        let kprocs = Native.allProcesses().filter { $0.pid >= 0 }
        let pids = kprocs.map(\.pid)
        time("per-pid path") { for p in pids { _ = Native.path(p) } }
        time("per-pid responsible") { for p in pids { _ = Native.responsible(p) } }
        time("per-pid coalition") { for p in pids { _ = Native.coalition(p) } }
        time("per-pid taskInfo") { for p in pids { _ = Native.taskInfo(p) } }
        time("per-pid rusage") { for p in pids { _ = Native.rusage(p) } }
        time("per-pid sandboxed") { for k in kprocs { _ = Native.sandboxed(k.pid, start: k.start) } }
        time("per-pid userName") { for p in Native.allProcesses() { _ = Native.userName(p.uid) } }
        if helper { time("helper allMetrics (XPC)") { _ = HelperClient.shared.allMetrics() } }
        let priv = helper ? HelperClient.shared.allMetrics() : nil
        time("full snapshot()") { _ = Store.snapshot(prev: [:], signCache: [:], priv: { priv }) }
        let snap = Store.snapshot(prev: [:], signCache: [:], priv: { priv })
        let store = Store(); store.procs = snap.procs; store.lsApps = snap.ls
        for g in Grouping.allCases {
            time("nodes(\(g.label))") {
                store.procs = snap.procs   // bump the cache generation so it really rebuilds
                _ = store.nodes(grouping: g, filter: "", sort: .pid)
            }
        }
        for g in Grouping.allCases {
            time("nodes(\(g.label), memory)") {
                store.procs = snap.procs
                _ = store.nodes(grouping: g, filter: "", sort: ColumnSort(id: "mem", ascending: false))
            }
        }
        let defaultCols = Set(Column.defaultShown), allCols = Set(Column.all.map(\.id))
        for (label, cols) in [("default columns", defaultCols), ("all columns", allCols)] {
            for g in [Grouping.smart, .flat] {
                time("nodes(\(g.label), \(label))") {
                    store.procs = snap.procs
                    _ = store.nodes(grouping: g, filter: "", sort: ColumnSort(id: "mem", ascending: false), columns: cols)
                }
            }
        }
        if ProcessInfo.processInfo.environment["BENCH_COLUMNS"] != nil {
            for c in Column.all {
                time("nodes(Smart, only \(c.id))") {
                    store.procs = snap.procs
                    _ = store.nodes(grouping: .smart, filter: "", sort: .pid, columns: [c.id])
                }
            }
        }
        time("nodes(Smart, all columns, sort by Kind)") {
            store.procs = snap.procs
            _ = store.nodes(grouping: .smart, filter: "", sort: ColumnSort(id: "kind", ascending: true), columns: allCols)
        }
        time("ghosts()") { _ = Store.ghosts(procs: snap.procs, lsApps: snap.ls) }
        let one = Array(snap.procs.values.prefix(50))
        time("CodeSign.inspect x50") { for p in one { _ = CodeSign.inspect(pid: p.pid, path: p.path) } }
    }

    /// `ProcXRay --rates <pid>…`: two snapshots `--interval` seconds apart (default 2), then each pid's
    /// rates, for checking the rate columns against another tool.
    static func rates(_ args: [String]) {
        var interval = 2.0
        var pids: [pid_t] = []
        var i = 0
        while i < args.count {
            if args[i] == "--interval", i + 1 < args.count { interval = Double(args[i + 1]) ?? 2; i += 2; continue }
            if let p = pid_t(args[i]) { pids.append(p) }
            i += 1
        }
        let a = Store.snapshot(prev: [:], signCache: [:])
        Thread.sleep(forTimeInterval: interval)
        let b = Store.snapshot(prev: a.samples, signCache: [:])
        for pid in pids {
            guard let p = b.procs[pid], let r = p.rates else { print("\(pid): no rates"); continue }
            func f(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "—" }
            print("\(pid) \(p.name): cpu% \(f(r.cpuPercent)) waiting% \(f(r.waitingPercent)) csw/s \(f(r.contextSwitches)) faults/s \(f(r.faults)) pageins/s \(f(r.pageins)) read B/s \(f(r.diskRead)) write B/s \(f(r.diskWrite)) W \(r.watts.map { String(format: "%.3f", $0) } ?? "—") wakeups/s \(f(r.wakeups)) syscalls/s \(f(r.syscalls)) machmsgs/s \(f(r.machMsgs))")
            print("    pcore% \(f(r.pCoreShare)) ipc \(r.ipc.map { String(format: "%.2f", $0) } ?? "—") cycles/s \(r.cycles.map(siFormat) ?? "—") instrs/s \(r.instructions.map(siFormat) ?? "—") bsd/s \(f(r.unixSyscalls)) mach/s \(f(r.machSyscalls)) sent/s \(f(r.machMsgsSent)) recv/s \(f(r.machMsgsReceived)) logical B/s \(f(r.logicalWrites)) fds \(Native.openFileCount(pid).map(String.init) ?? "—") assertions \(Native.powerAssertions(pid))")
        }
    }

    /// `ProcXRay --helper-call <status|argsenv|lsof|lsofall|vmmap|sample|procinfo|btm> [pid]`: one helper call from
    /// the shell, for testing the helper without the UI. Only this exact binary is accepted by the helper.
    static func helperCall(_ args: [String]) {
        let c = HelperClient.shared
        print(c.probe().label)
        guard let what = args.first else { return }
        let pid = args.dropFirst().first.flatMap { Int32($0) } ?? 0
        let tools: [String: HelperTool] = ["lsof": .lsof, "vmmap": .vmmap, "sample": .sample,
                                           "procinfo": .launchctlProcinfo, "btm": .btmDump, "lsofall": .lsofAll]
        if what == "argsenv" {
            guard let r = c.argsEnv(pid) else { print("argsEnv: nil"); return }
            print("argsEnv: exec=\(r.execPath) args=\(r.args.count) env=\(r.env.count) cwd=\(r.cwd ?? "nil")")
        } else if let t = tools[what] {
            let out = c.run(t, pid: pid) ?? "helper did not answer"
            print("\(what): \(out.utf8.count) bytes")
            print(out.prefix(400))
        }
    }

    /// `ProcXRay --peers [--root] [pid…]`: builds the Connections tab's peer index, then resolves each
    /// process's descriptors as the tab does (its own `lsof -p` run), and counts how many other ends were
    /// found per kind. Without pids, every process in the index.
    static func peers(_ args: [String]) {
        let viaHelper = args.contains("--root")   // not --helper: that starts the daemon
        let t0 = Date()
        let ix = PeerIndexLoader.load(viaHelper: viaHelper, fresh: true)
        print(String(format: "index: %d processes, %.2f s, scope %@", ix.processCount, -t0.timeIntervalSinceNow,
                     "\(ix.scope)"))
        var pids = args.compactMap { Int32($0) }
        if pids.isEmpty { pids = Array(Set(ix.byAddress.values.flatMap { $0.map(\.pid) })).sorted() }
        var found: [String: Int] = [:], missing: [String: Int] = [:], none: [String: Int] = [:]
        for pid in pids {
            let entries = LsofParser.parse(Shell.run("/usr/sbin/lsof", ["-n", "-P", "-p", "\(pid)"], mergeStderr: false))
            for e in entries where [.pipe, .unix, .tcp, .file].contains(e.kind) {
                let k = e.kind.rawValue
                guard let info = PeerInfo.resolve(e, pid: pid, in: ix) else { none[k, default: 0] += 1; continue }
                if info.unresolved { missing[k, default: 0] += 1 } else { found[k, default: 0] += 1 }
                if pids.count <= 3, e.kind != .file {
                    print("  \(pid) fd \(e.fd) \(e.type) \(e.name) → \(info.unresolved ? "not visible" : info.ends.map { "\($0.pid):\($0.fd)" }.joined(separator: " "))")
                }
            }
        }
        for k in Set(found.keys).union(missing.keys).union(none.keys).sorted() {
            print("\(k): \(found[k] ?? 0) found, \(missing[k] ?? 0) not visible, \(none[k] ?? 0) with no other end")
        }
    }
}
