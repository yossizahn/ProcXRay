import AppKit
import Darwin
import Foundation
import SwiftUI

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

    /// `ProcXRay --helper-call <status|argsenv|lsof|lsofall|vmmap|sample|procinfo|btm|taskinfo|powermetrics> [pid] [--full]`:
    /// one helper call from the shell, for testing the helper without the UI. Only this exact binary is accepted by the helper.
    static func helperCall(_ args: [String]) {
        let c = HelperClient.shared
        print(c.probe().label)
        guard let what = args.first else { return }
        let pid = args.dropFirst().first.flatMap { Int32($0) } ?? 0
        let tools: [String: HelperTool] = ["lsof": .lsof, "vmmap": .vmmap, "sample": .sample,
                                           "procinfo": .launchctlProcinfo, "btm": .btmDump, "lsofall": .lsofAll,
                                           "taskinfo": .taskinfo, "powermetrics": .powermetrics]
        if what == "mach" {
            let t0 = Date()
            switch c.machPorts() {
            case .success(let s): machSummary(s, seconds: -t0.timeIntervalSinceNow, pids: args.dropFirst().compactMap { Int32($0) })
            case .failure(let e): print("mach: \(e.message)")
            }
            return
        }
        if what == "argsenv" {
            guard let r = c.argsEnv(pid) else { print("argsEnv: nil"); return }
            print("argsEnv: exec=\(r.execPath) args=\(r.args.count) env=\(r.env.count) cwd=\(r.cwd ?? "nil")")
        } else if let t = tools[what] {
            let t0 = Date()
            let out = c.run(t, pid: pid) ?? "helper did not answer"
            let ms = -t0.timeIntervalSinceNow * 1000
            print(String(format: "%@: %d bytes in %.0f ms", what, out.utf8.count, ms))
            let preview = args.contains("--full") ? out[...] : out.prefix(2000)
            print(preview)
        }
    }

    /// `ProcXRay --mach-file <lsmp.json> [pid…]`: pairs a saved `lsmp -a -j` file as the helper does.
    static func machFile(_ args: [String]) {
        guard let path = args.first, let data = FileManager.default.contents(atPath: path) else { print("no file"); return }
        let t0 = Date()
        guard let s = MachSnapshot.parse(data) else { print("not lsmp JSON"); return }
        machSummary(s, seconds: -t0.timeIntervalSinceNow, pids: args.dropFirst().compactMap { Int32($0) })
    }

    static func machSummary(_ s: MachSnapshot, seconds: Double, pids: [Int32]) {
        let pairs = Set(s.links.map { [min($0.from, $0.to), max($0.from, $0.to)] })
        print(String(format: "mach: %d processes, %d directed links, %d pairs, %d ports, %d queued, %.2f s",
                     s.processCount, s.links.count, pairs.count, s.links.reduce(0) { $0 + $1.ports },
                     s.links.reduce(0) { $0 + $1.queued }, seconds))
        let hubs = s.senders.filter { s.isCommon($0.key) }.sorted { $0.value > $1.value }
        print("common services (≥ \(Int(MachSnapshot.commonShare * 100)) %): \(hubs.count): "
              + hubs.prefix(12).map { "\(Native.process($0.key)?.comm ?? "\($0.key)") \(Int((s.share($0.key) * 100).rounded()))%" }.joined(separator: ", "))
        var types: [String: Int] = [:]
        for d in s.kernelObjects.values { for (t, n) in d { types[t, default: 0] += n } }
        print("kernel objects: " + types.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        var classes: [String: Int] = [:]
        for d in s.iokit.values { for (c, n) in d { classes[c, default: 0] += n } }
        print("iokit connections: \(classes.values.reduce(0, +)): " + classes.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        let pairs2 = Set(s.sharedMemory.flatMap { m in m.holders.flatMap { a in m.holders.filter { $0 > a }.map { [a, $0] } } })
        print("shared memory: \(s.sharedMemory.count) entries with ≤ \(MachSnapshot.fewHolders) holders (\(pairs2.count) pairs), \(s.widelyShared.count) processes hold widely shared ones; sized \(s.sharedMemory.filter { $0.bytes != nil }.count)")
        var flavors: [String: Int] = [:]
        for t in s.taskRights { flavors[t.flavor, default: 0] += 1 }
        print("task ports of other processes: \(s.taskRights.count): \(flavors)")
        let holders = Dictionary(grouping: s.taskRights, by: \.holder).mapValues { Set($0.map(\.target)).count }
        print("  holders: " + holders.sorted { $0.value > $1.value }.prefix(8)
            .map { "\(Native.process($0.key)?.comm ?? "\($0.key)") \($0.value)\(s.isCommonTaskHolder($0.key) ? " (common)" : "")" }.joined(separator: ", "))
        for t in s.taskRights.filter({ $0.flavor == "control" && !s.isCommonTaskHolder($0.holder) }).prefix(8) {
            print("  \(Native.process(t.holder)?.comm ?? "\(t.holder)") holds \(Native.process(t.target)?.comm ?? "\(t.target)")'s control port")
        }
        func top(_ title: String, _ v: (MachPortCounts) -> Int) {
            let all = s.counts.map { ($0.key, v($0.value)) }
            let sorted = all.map(\.1).sorted()
            print("\(title): median \(sorted.isEmpty ? 0 : sorted[sorted.count / 2]), total \(sorted.reduce(0, +)), "
                  + all.sorted { $0.1 > $1.1 }.prefix(5).map { "\(Native.process($0.0)?.comm ?? "\($0.0)") \($0.1)" }.joined(separator: ", "))
        }
        var without = s; without.counts = [:]
        let size = (try? JSONEncoder().encode(s).count) ?? 0, sizeWithout = (try? JSONEncoder().encode(without).count) ?? 0
        print("reply: \(size) bytes, \(size - sizeWithout) of them port counts")
        top("ports", \.total)
        top("dead names", \.deadNames)
        top("replies owed", \.sendOnce)
        top("full queues", \.fullQueues)
        for pid in pids {
            if let c = s.counts[pid] { print("pid \(pid) ports: \(c)") }
            let ps = s.peers(of: pid)
            print("pid \(pid): \(ps.count) peers, \(ps.filter(\.common).count) common")
            for p in ps.prefix(15) {
                var p = p
                if let l = Launchd.otherDomains().first(where: { $0.pid == p.pid })?.label { p.services = LaunchdServices.byLabel[l] ?? [] }
                print("  \(p.pid) \(Native.process(p.pid)?.comm ?? "?"): \(p.direction) · \(p.summary)")
            }
            print("  iokit: \(s.iokit[pid] ?? [:])")
            print("  shared: \(s.sharedMemory(of: pid).prefix(5).map { "\($0.pid)×\($0.entries) \($0.bytes)B" })")
            print("  kernel: \(s.kernelObjects[pid] ?? [:])")
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
        var locs: [String: Int] = [:]
        var otherSamples: [String] = []
        for pid in pids {
            let entries = LsofParser.parse(Shell.run("/usr/sbin/lsof", ["-n", "-P", "-p", "\(pid)"], mergeStderr: false))
            let bundle = Native.path(pid).flatMap { path in path.range(of: ".app/", options: .backwards).map { String(path[..<$0.lowerBound]) + ".app" } }
            for e in entries {
                let l = FileLocation.of(e, ownBundle: bundle)
                guard !l.isEmpty else { continue }
                locs[l, default: 0] += 1
                if l == "Other", otherSamples.count < 8 { otherSamples.append(e.name) }
            }
            for e in entries where [.pipe, .unix, .tcp, .file].contains(e.kind) {
                let k = e.kind.rawValue
                guard let info = PeerInfo.resolve(e, pid: pid, in: ix) else { none[k, default: 0] += 1; continue }
                if info.unresolved { missing[k, default: 0] += 1 } else { found[k, default: 0] += 1 }
                if pids.count <= 3, e.kind != .file {
                    print("  \(pid) fd \(e.fd) \(e.type) \(e.name) → \(info.unresolved ? "not visible" : info.ends.map { "\($0.pid):\($0.fd)" }.joined(separator: " "))")
                }
            }
        }
        print("file locations: " + locs.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        if !otherSamples.isEmpty { print("  Other, e.g.: " + otherSamples.joined(separator: "  ")) }
        for k in Set(found.keys).union(missing.keys).union(none.keys).sorted() {
            print("\(k): \(found[k] ?? 0) found, \(missing[k] ?? 0) not visible, \(none[k] ?? 0) with no other end")
        }
    }

    /// `ProcXRay --domains [--root]`: reads every process's launchd pid domain as the Store does, then counts
    /// owners found and what the Smart tree's rule 4 changes.
    static func domains(_ args: [String]) {
        let viaHelper = args.contains("--root")
        let priv = viaHelper ? HelperClient.shared.allMetrics() : nil
        var procs = Store.snapshot(prev: [:], signCache: [:], priv: { priv }).procs
        let ls = LSAppInfo.list()
        let before = SmartTree.unitRoots(.init(procs: procs, lsApps: ls))
        let t0 = Date()
        var hostOf: [String: String] = [:]
        var unread = 0, hosts = 0
        for p in procs.values where p.pid > 0 && !p.isZombie {
            guard let kids = PidDomain.read(p.pid, ownedByUser: p.uid == getuid(), viaHelper: viaHelper) else { unread += 1; continue }
            if !kids.isEmpty { hosts += 1 }
            for k in kids { if let c = procs[k], k != p.pid { hostOf[c.key] = p.key } }
        }
        print(String(format: "read %d domains in %.2f s; %d unreadable; %d hosts", procs.count, -t0.timeIntervalSinceNow, unread, hosts))
        Store.applyDomainOwners(&procs, hostOf)
        let owned = procs.values.filter { $0.domainOwner != nil }
        let ext = procs.values.filter(SmartTree.isExtension)
        print("with a host: \(owned.count); extensions \(ext.filter { $0.domainOwner != nil }.count) of \(ext.count)")
        let after = SmartTree.unitRoots(.init(procs: procs, lsApps: ls))
        let units = { (r: [pid_t: pid_t]) in Set(r.values).count }
        let moved = procs.keys.filter { before[$0] != after[$0] }
        print("units: \(units(before)) → \(units(after)); \(moved.count) processes moved by rule 4")
        for pid in moved.prefix(15) {
            let p = procs[pid]!, r = after[pid].flatMap { procs[$0] }
            print("  \(p.name) (\(pid)) → unit of \(r?.name ?? "?") via host \(p.domainOwnerName ?? "-")")
        }
    }

    /// `ProcXRay --btm-rule <dumpbtm output file>`: what the Smart tree's rule 3c (Background Items owner)
    /// changes, given a saved `sfltool dumpbtm` (see --btm-dump).
    static func btmRule(_ file: String) {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { print("can't read \(file)"); return }
        let items = BTM.parse(text)
        let index = BTM.ownerIndex(items)
        let procs = Store.snapshot(prev: [:], signCache: [:]).procs
        let ls = LSAppInfo.list()
        let before = SmartTree.unitRoots(.init(procs: procs, lsApps: ls))
        let after = SmartTree.unitRoots(.init(procs: procs, lsApps: ls, btmOwners: index))
        let matched = procs.values.filter { p in
            p.path.flatMap { index["path:" + $0] } != nil || p.launchdLabel.flatMap { index["label:" + $0] } != nil
        }
        print("\(items.count) records, \(index.count) owner keys; \(matched.count) running processes have one")
        let moved = procs.keys.filter { before[$0] != after[$0] }
        print("\(moved.count) processes moved by rule 3c")
        for pid in moved {
            let p = procs[pid]!
            print("  \(p.name) (\(pid)): unit of \(before[pid].flatMap { procs[$0]?.name } ?? "?") → \(after[pid].flatMap { procs[$0]?.name } ?? "?")")
        }
        for p in matched where !moved.contains(p.pid) {
            let ids = p.path.flatMap { index["path:" + $0] } ?? p.launchdLabel.flatMap { index["label:" + $0] } ?? []
            print("  unchanged: \(p.name) (\(p.pid)) owners \(ids)")
        }
    }

    /// `ProcXRay --shell-test`: checks Shell.exec's guarantees (output, status, stderr, limits, cancel).
    static func shellTest() -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            print((cond ? "ok   " : "FAIL ") + name + (detail.isEmpty ? "" : "  [\(detail)]"))
            ok = ok && cond
        }
        func timed(_ f: () -> Shell.Result) -> (Shell.Result, Double) {
            let t = Date(); let r = f(); return (r, -t.timeIntervalSinceNow)
        }
        var r = Shell.exec("/bin/echo", ["hello", "world"])
        check("stdout", r.output == "hello world\n" && r.status == 0, r.output)
        r = Shell.exec("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])
        check("stderr merged, exit status", r.output.contains("out") && r.output.contains("err") && r.status == 3, "\(r.status)")
        r = Shell.exec("/bin/sh", ["-c", "echo out; echo err >&2"], mergeStderr: false)
        check("stderr dropped", r.output == "out\n", r.output)
        r = Shell.exec("/bin/cat", [])
        check("stdin is /dev/null", r.output.isEmpty && r.status == 0)
        r = Shell.exec("/nonexistent/tool", [])
        check("missing tool", r.status == -1 && r.output.hasPrefix("failed to run"), r.output)
        var (t, secs) = timed { Shell.exec("/bin/sleep", ["10"], timeout: 1) }
        check("timeout", t.timedOut && secs < 2, String(format: "%.2f s, status %d", secs, t.status))
        (t, secs) = timed { Shell.exec("/bin/sh", ["-c", "trap '' TERM; sleep 10"], timeout: 0.5) }
        check("SIGKILL after ignored SIGTERM", t.timedOut && secs < 4, String(format: "%.2f s, status %d", secs, t.status))
        (t, _) = timed { Shell.exec("/usr/bin/yes", [], maxBytes: 100_000) }
        check("output cap", t.truncated && t.output.utf8.count <= 100_000, "\(t.output.utf8.count) bytes")
        (t, secs) = timed { Shell.exec("/bin/sh", ["-c", "echo hi; sleep 10 &"]) }
        check("background child keeps pipe", t.output == "hi\n" && secs < 2, String(format: "%.2f s", secs))
        let c = Shell.Cancel()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { c.cancel() }
        (t, secs) = timed { Shell.Cancel.$current.withValue(c) { Shell.exec("/bin/sleep", ["10"]) } }
        check("cancel", secs < 2, String(format: "%.2f s, status %d", secs, t.status))
        var fds: [Int32] = [0, 0]; pipe(&fds)   // an app descriptor that must not reach the tool
        r = Shell.exec("/bin/sh", ["-c", "ls /dev/fd | wc -l"])
        check("no inherited descriptors", Int(r.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 99 <= 5, r.output)
        close(fds[0]); close(fds[1])
        let t0 = Date()
        for _ in 0..<50 { _ = Shell.exec("/usr/bin/true", []) }
        print(String(format: "spawn cost: %.1f ms each", -t0.timeIntervalSinceNow * 20))
        return ok
    }

    /// `ProcXRay --tree-stats`: rows per grouping, what identical-sibling collapse saves, pivot groups and
    /// chip counts, on one snapshot with signatures read.
    @MainActor static func treeStats() {
        var procs = Store.snapshot(prev: [:], signCache: [:]).procs
        let s1 = Store.snapshot(prev: [:], signCache: [:])   // a second sample, for CPU %
        Thread.sleep(forTimeInterval: 1)
        let s2 = Store.snapshot(prev: s1.samples, signCache: [:])
        procs = s2.procs
        for (pid, p) in procs {
            let s = CodeSign.inspect(pid: pid, path: p.path)
            procs[pid]!.signer = s.shortSigner
        }
        let store = Store(); store.procs = procs; store.lsApps = s2.ls
        func rows(_ ns: [ProcNode]) -> Int { ns.reduce(0) { $0 + 1 + rows($1.children ?? []) } }
        func collapsed(_ ns: [ProcNode]) -> [(String, Int)] {
            ns.flatMap { n -> [(String, Int)] in
                (n.title.contains(" ×") && n.proc == nil ? [(n.title, n.children?.count ?? 0)] : []) + collapsed(n.children ?? [])
            }
        }
        for g in Grouping.allCases {
            let ns = store.nodes(grouping: g, filter: "", sort: .pid)
            let c = collapsed(ns)
            let hidden = c.reduce(0) { $0 + $1.1 }
            print("\(g.label): \(ns.count) top rows, \(rows(ns)) rows; \(c.count) identical sets hold \(hidden) processes"
                  + (g == .smart ? ": " + c.sorted { $0.1 > $1.1 }.prefix(8).map(\.0).joined(separator: ", ") : ""))
            if Grouping.pivots.contains(g) {
                print("   groups: " + ns.sorted { $0.totalCount > $1.totalCount }.prefix(8).map { "\($0.title) \($0.totalCount)" }.joined(separator: ", "))
            }
        }
        let now = Date()
        for c in FilterChip.allCases {
            let n = procs.values.filter { c.matches($0, now: now) }.count
            let shown = store.nodes(grouping: .smart, filter: "", chips: [c], sort: .pid)
            print("chip \(c.title): \(n) processes; Smart tree keeps \(rows(shown)) rows")
        }
    }

    /// `ProcXRay --extras [--root]`: what each extra read adds to a snapshot, and how many processes get a value.
    static func extras(root: Bool) {
        let ls = LSAppInfo.list(), jobs = Launchd.list(), other = Launchd.otherDomains()
        func snap(_ e: ExtraReads, prev: [String: Sample] = [:]) -> (Store.Snapshot, Double) {
            let priv = root ? HelperClient.shared.allMetrics(extras: e) : nil
            let t = Date()
            // LaunchServices and launchd passed in: their tool runs would swamp the difference being measured.
            let s = Store.snapshot(prev: prev, signCache: [:], extras: e, priv: { priv }, ls: ls, jobs: jobs, otherJobs: other)
            return (s, -t.timeIntervalSinceNow * 1000)
        }
        _ = snap([])
        var base = 0.0
        for _ in 0..<5 { base += snap([]).1 }
        base /= 5
        print(String(format: "snapshot without extras: %.1f ms%@", base, root ? " (helper metrics fetched before timing)" : ""))
        if root {
            for (name, e) in [("none", ExtraReads()), ("files+nice+compressed", [.openFiles, .nice, .compressed] as ExtraReads),
                              ] {
                _ = HelperClient.shared.allMetrics(extras: e)
                let t = Date()
                for _ in 0..<5 { _ = HelperClient.shared.allMetrics(extras: e) }
                print(String(format: "helper allMetrics, extras %@: %.1f ms", name as NSString, -t.timeIntervalSinceNow * 200))
            }
        }
        let cases: [(String, ExtraReads, (ProcInfo) -> Bool)] = [
            ("open files", .openFiles, { $0.openFiles != nil }),
            ("nice", .nice, { $0.nice != nil }),
            ("compressed", .compressed, { $0.compressed != nil }),
            ("assertions", .assertions, { ExtraRead.preventing($0.assertions ?? []) != nil }),
            ("gpu", .gpu, { $0.gpuNanos != nil }),
        ]
        for (name, e, has) in cases {
            var ms = 0.0
            var last: Store.Snapshot?
            for _ in 0..<5 { let (s, t) = snap(e); ms += t; last = s }
            let procs = last!.procs.values
            print(String(format: "%-11@ +%5.1f ms   %d of %d processes have a value", name as NSString, ms / 5 - base,
                         procs.filter(has).count, procs.count))
        }
        let (a, _) = snap(.gpu)
        Thread.sleep(forTimeInterval: 2)
        let (b, _) = snap(.gpu, prev: a.samples)
        let top = b.procs.values.compactMap { p in p.rates?.gpuPercent.map { (p.name, $0) } }.sorted { $0.1 > $1.1 }.prefix(5)
        print("GPU % over 2 s: " + top.map { String(format: "%@ %.1f", $0.0, $0.1) }.joined(separator: ", "))
        let prio = Dictionary(grouping: b.procs.values.compactMap(\.priority), by: { $0 }).mapValues(\.count).sorted { $0.value > $1.value }.prefix(5)
        print("priority values: " + prio.map { "\($0.key)×\($0.value)" }.joined(separator: ", "))
        NetSampler.shared.want(true)
        Thread.sleep(forTimeInterval: 12)
        let net = NetSampler.shared.current() ?? [:]
        NetSampler.shared.want(false)
        let names = b.procs.mapValues(\.name)
        let busiest = net.sorted { $0.value.inPerSec + $0.value.outPerSec > $1.value.inPerSec + $1.value.outPerSec }.prefix(5)
        print("network: \(net.count) processes with rates; " + busiest.map { "\(names[$0.key] ?? "?") in \(Int($0.value.inPerSec)) B/s out \(Int($0.value.outPerSec)) B/s" }.joined(separator: "; "))
    }

    /// `ProcXRay --qos <pid>`: CPU time by QoS class against total CPU time, over 2 s.
    /// The Sandbox card's checks for each pid, as a table (0 allowed, 1 denied, ? unknown), and their cost.
    static func sandbox(_ pids: [pid_t]) {
        func v(_ x: SandboxProbes.Verdict) -> String { switch x { case .allowed: "0"; case .denied: "1"; case .unknown: "?" } }
        for pid in pids {
            guard let p = Native.process(pid) else { print("pid \(pid): not found"); continue }
            let t0 = DispatchTime.now().uptimeNanoseconds
            guard let r = SandboxProbes.run(pid: pid, start: p.start) else { print("pid \(pid): gone"); continue }
            let us = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000
            print("pid \(pid) sandboxed=\(String(describing: Native.sandboxed(pid, start: p.start))) \(String(format: "%.0f", us)) µs")
            for l in r.locations { print("  \(l.id.padding(toLength: 30, withPad: " ", startingAt: 0)) read \(v(l.read)) write \(v(l.write))") }
            for c in r.capabilities { print("  \(c.id.padding(toLength: 30, withPad: " ", startingAt: 0)) \(v(c.verdict))") }
            if let dir = ProcessInfo.processInfo.environment["SANDBOX_PNG_DIR"] { renderSandbox(pid, r, dir: dir) }
        }
    }

    /// The Sandbox card's contents for `pid`, rendered to <dir>/sandbox-<pid>.png (2x), to check the layout.
    private static func renderSandbox(_ pid: pid_t, _ r: SandboxProbes.Report, dir: String) {
        let ent: [String: Any] = Native.path(pid).flatMap { path in
            let out = Shell.exec("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", path], mergeStderr: false).output
            return out.data(using: .utf8).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        } ?? [:]
        MainActor.assumeIsolated {
            let view = Card(title: "Sandbox", systemImage: "square.dashed") {
                Text(SandboxCard.summary(true, entitlements: ent)).fixedSize(horizontal: false, vertical: true)
                SandboxProbeTable(report: r, entitlements: ent, recheck: {})
            }
            .frame(width: 560).padding(10).background(Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let img = renderer.nsImage, let tiff = img.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                print("  render failed"); return
            }
            let url = URL(fileURLWithPath: dir).appendingPathComponent("sandbox-\(pid).png")
            try? png.write(to: url)
            print("  rendered \(url.path) \(Int(img.size.width))x\(Int(img.size.height)) pt")
        }
    }

    static func qos(_ pid: pid_t) {
        if pid == 0 {
            // Every process: the QoS rates should add up to CPU %, both from one pair of snapshots.
            let a = Store.snapshot(prev: [:], signCache: [:])
            Thread.sleep(forTimeInterval: 2)
            let b = Store.snapshot(prev: a.samples, signCache: [:])
            var n = 0, off = 0, worst = 0.0, busy = 0
            for p in b.procs.values {
                guard let c = p.rates?.cpuPercent, let q = p.rates?.qosPercent else { continue }
                n += 1
                let d = abs(q.reduce(0, +) - c)
                if c > 1 { busy += 1 }
                if d > 0.5 { off += 1 }
                worst = max(worst, d)
            }
            print(String(format: "%d processes compared (%d above 1 %% CPU); %d differ by more than 0.5 points; largest difference %.2f points", n, busy, off, worst))
            return
        }
        guard let a = Native.rusage(pid), let qa = Native.cpuTimeByQoS(pid) else { print("unreadable"); return }
        let t0 = DispatchTime.now().uptimeNanoseconds
        Thread.sleep(forTimeInterval: 2)
        guard let b = Native.rusage(pid), let qb = Native.cpuTimeByQoS(pid) else { return }
        let secs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        let cpu = Double(Native.machToNanos((b.ri_user_time &+ b.ri_system_time) &- (a.ri_user_time &+ a.ri_system_time)))
        let q = zip(qa, qb).map { (x, y) in (x.0, Double(y.1 &- x.1)) }
        print(String(format: "CPU %.1f %%; QoS sum %.1f %%", cpu / 1e9 / secs * 100, q.reduce(0) { $0 + $1.1 } / 1e9 / secs * 100))
        for (n, v) in q where v > 0 { print(String(format: "  %@ %.1f %%", n as NSString, v / 1e9 / secs * 100)) }
        print("totals: cpu \(Native.machToNanos(b.ri_user_time &+ b.ri_system_time) / 1_000_000) ms, qos sum \(qb.reduce(0) { $0 + $1.1 } / 1_000_000) ms")
    }
}
