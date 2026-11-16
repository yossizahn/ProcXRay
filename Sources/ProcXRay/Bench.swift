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

    /// `ProcXRay --helper-call <status|argsenv|threads|lsof|lsofall|vmmap|sample|procinfo|btm|taskinfo|stacks|powermetrics> [pid] [--full]`:
    /// one helper call from the shell, for testing the helper without the UI. Only this exact binary is accepted by the helper.
    /// The helper's trace path without XPC: start, read every 250 ms as the app does, decode, pair.
    static func trace(pid: Int32, seconds: Double, ktrace: Bool, out: String?) {
        let t0 = Date()
        let source: TraceSource
        if ktrace {
            let t = TraceProcess(maxPending: SyscallTraceConfig.maxPending)
            guard let (path, args) = SyscallTraceConfig.argv(pid: pid) else { print("bad pid"); return }
            if let err = t.start(path, args) { print(err); return }
            source = t
        } else {
            switch KdebugTrace.start(pid: pid, maxPending: SyscallTraceConfig.maxPending, maxSeconds: SyscallTraceConfig.maxSeconds) {
            case .success(let t): source = t
            case .failure(.refused(let s)), .failure(.failed(let s)): print(s); return
            }
        }
        let started = -t0.timeIntervalSinceNow
        var dec = SyscallDecoder()
        var fds = FdLabeler()
        var recs: [SyscallRecord] = []
        var events = 0, bytes = 0, bad = 0
        var decodeTime = 0.0
        var stopped = false
        while true {
            if !stopped && -t0.timeIntervalSinceNow > seconds { source.stop(); stopped = true }
            let (d, running, notes) = source.read(max: SyscallTraceConfig.maxRead)
            if !notes.isEmpty { print("note: " + notes.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let d0 = Date()
            let (evs, b) = ktrace ? KdebugEvent.decode(d) : (KdebugEvent.decodeRaw(d), 0)
            var batch = dec.feed(evs)
            fds.label(&batch) { NativeLsof.describe(pid, fds: $0) }
            recs += batch
            decodeTime += -d0.timeIntervalSinceNow
            events += evs.count; bytes += d.count; bad += b
            if !running { break }
            if d.count < SyscallTraceConfig.maxRead / 2 { usleep(250_000) }
        }
        var tail = dec.flush()
        fds.label(&tail) { NativeLsof.describe(pid, fds: $0) }
        recs += tail
        let inFlight = dec.pending()
        var ru = rusage(), rc = rusage(); getrusage(RUSAGE_SELF, &ru); getrusage(RUSAGE_CHILDREN, &rc)
        func secs(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        print(String(format: "%@: started in %.0f ms; %d events, %d bytes, %d bad, %d gaps; %d records + %d in flight; decode+pair %.3f s; CPU %.3f s here + %.3f s ktrace",
                     ktrace ? "ktrace" : "kdebug", started * 1000, events, bytes, bad, dec.gaps, recs.count, inFlight.count, decodeTime,
                     secs(ru.ru_utime) + secs(ru.ru_stime), secs(rc.ru_utime) + secs(rc.ru_stime)))
        guard let out else { return }
        var text = ""
        for r in recs + inFlight {
            text += "\(r.name)\t\(r.argsText)\t\(r.resultText)\t\(r.pathText)\t\(r.state)\n"
        }
        FileManager.default.createFile(atPath: out, contents: Data(text.utf8))
    }

    static func helperCall(_ args: [String]) {
        let c = HelperClient.shared
        print(c.probe().label)
        guard let what = args.first else { return }
        let pid = args.dropFirst().first.flatMap { Int32($0) } ?? 0
        let tools: [String: HelperTool] = ["lsof": .lsof, "vmmap": .vmmap, "sample": .sample,
                                           "procinfo": .launchctlProcinfo, "btm": .btmDump, "lsofall": .lsofAll,
                                           "taskinfo": .taskinfo, "powermetrics": .powermetrics, "stacks": .stacks]
        if what == "jetsam" {
            // jetsam [pid…]: the helper's jetsam reads (allMetrics with .jetsam), counted, and the given pids.
            let t0 = Date()
            guard let m = c.allMetrics(extras: .jetsam) else { print("jetsam: no reply"); return }
            let got = m.values.compactMap(\.jetsam)
            print(String(format: "jetsam: %d of %d processes in %.1f ms (whole allMetrics call), %d with no limit, %d with different active/inactive limits",
                         got.count, m.count, -t0.timeIntervalSinceNow * 1000, got.filter { $0.limitMB == nil }.count, got.filter(\.limitsDiffer).count))
            for p in args.dropFirst().compactMap({ Int32($0) }) { print("  \(p): \(m[p]?.jetsam.map { "\($0)" } ?? "none")") }
            return
        }
        if what == "security" {
            // security <pid>: SecurityConfig through the helper, next to the local read.
            func names(_ d: SecurityDetail?) -> String {
                guard let d else { return "unreadable" }
                let flags: [String] = SecurityConfig.all.filter { d.config.contains($0.0) }.map(\.name)
                var out = String(format: "0x%llx ", d.config.rawValue) + flags.joined(separator: ", ")
                if let k = d.kernel { out += String(format: "; kernel 0x%x", k.raw) }
                if let i = d.ipcPolicy { out += String(format: "; ipc 0x%x", i.raw) }
                return out
            }
            print("local:  \(names(SecurityDetail.read(pid)))")
            print("helper: \(names(c.securityDetail(pid)))")
            return
        }
        if what == "mach" {
            let t0 = Date()
            switch c.machPorts() {
            case .success(let s): machSummary(s, seconds: -t0.timeIntervalSinceNow, pids: args.dropFirst().compactMap { Int32($0) })
            case .failure(let e): print("mach: \(e.message)")
            }
            return
        }
        if what == "machports", let peer = args.dropFirst(2).first.flatMap({ Int32($0) }) {
            let t0 = Date()
            switch c.machPortDetail(pid: pid, peer: peer) {
            case .success(let r):
                print(String(format: "machports %d ↔ %d: %d ports in %.2f s, run at %@", pid, peer, r.ports.count, -t0.timeIntervalSinceNow, "\(r.at)"))
                for d in r.ports.prefix(12) { print("  \(d)") }
            case .failure(let e): print("machports: \(e.message)")
            }
            return
        }
        if what == "bank" {
            // bank <seconds>: voucher settlements per pair through the helper.
            switch c.bankLedger(seconds: Int(pid > 0 ? pid : 10)) {
            case .success(let r):
                print(String(format: "bank: %.1f s, %d pairs, %d lost marks", r.seconds, r.flows.count, r.lost))
                for f in r.flows.prefix(20) {
                    print(String(format: "  %@(%d) for %@(%d): %.3f ms, %.3f mJ, %d", f.merchantName, f.merchant, f.holderName, f.holder,
                                 Double(f.cpuNanos) / 1e6, Double(f.energyNJ) / 1e6, f.count))
                }
            case .failure(let e): print("bank: \(e.message)")
            }
            return
        }
        if what == "survey" {
            // survey <seconds> <processes>: traces the busiest processes one after another (one trace at a time) and
            // lists the calls still shown as raw numbers, by count: no argument table, no argument names, or a result
            // without a meaning.
            let secs = args.dropFirst().first.flatMap { Double($0) } ?? 3
            let n = args.dropFirst(2).first.flatMap { Int($0) } ?? 12
            let ps = Shell.exec("/bin/ps", ["-A", "-r", "-o", "pid=,comm="], timeout: 10, maxBytes: 1 << 20).output
            let me = getpid()
            let pids = ps.split(separator: "\n").compactMap { line -> (Int32, String)? in
                let f = line.split(separator: " ", maxSplits: 1)
                guard f.count == 2, let p = Int32(f[0]), p != me, !f[1].contains("ProcXRay") else { return nil }
                return (p, String(f[1].split(separator: "/").last ?? ""))
            }.prefix(n)
            struct Agg { var count = 0; var reasons: Set<String> = []; var examples: [String] = []; var procs: Set<String> = [] }
            var agg: [String: Agg] = [:]
            var total = 0, fdArgs = 0, fdLabeled = 0
            var socketExamples: [String] = []
            for (pid, comm) in pids {
                let s = HelperTraceSession()
                guard case .success(let format) = s.start(pid: pid) else { s.close(); continue }
                var dec = SyscallDecoder(), recs: [SyscallRecord] = [], stopped = false
                var fds = FdLabeler()
                let t0 = Date()
                while let (d, running, _, _) = s.read() {
                    if !stopped && -t0.timeIntervalSinceNow > secs { s.stop(); stopped = true }
                    var batch = dec.feed(format == .kdebug ? KdebugEvent.decodeRaw(d) : KdebugEvent.decode(d).events)
                    fds.label(&batch) { s.describeFds($0) }
                    recs += batch
                    if !running { break }
                    if d.count < SyscallTraceConfig.maxRead / 2 { usleep(250_000) }
                }
                s.close()
                recs += dec.flush()
                total += recs.count
                print("\(comm) (\(pid)): \(recs.count) calls")
                for r in recs {
                    let base = r.name.hasSuffix("_nocancel") ? String(r.name.dropLast(9)) : r.name
                    for (i, _) in FdLabeler.fdArgs(r) {
                        fdArgs += 1
                        if r.argValues[i].contains(" (") { fdLabeled += 1 }
                        if socketExamples.count < 8, r.argValues[i].contains("TCP") || r.argValues[i].contains("UDP"),
                           !socketExamples.contains(where: { $0.hasPrefix(r.name) }) {
                            socketExamples.append("\(r.name)(\(r.argsText)) = \(r.resultText)  [\(comm)]")
                        }
                    }
                    var why: [String] = []
                    if let a = r.args, !a.isEmpty, !r.argValues.isEmpty, r.argValues != ["…"] {
                        if SyscallFormat.signature(base) == nil && !SyscallFormat.specialNames.contains(base) { why.append("no args table") }
                        if SyscallFormat.argNames(r).isEmpty { why.append("no names") }
                    }
                    if !r.mach && r.error == 0 && r.state == .done && r.ret != 0 && SyscallFormat.returns[base] == nil
                        && !["fcntl", "pipe"].contains(base) { why.append("result unnamed") }
                    guard !why.isEmpty else { continue }
                    var g = agg[r.name] ?? Agg()
                    g.count += 1; g.reasons.formUnion(why); g.procs.insert(comm)
                    let ex = "\(r.name)(\(r.namedArgsText)) = \(r.resultText)"
                    if g.examples.count < 2 && !g.examples.contains(ex) { g.examples.append(ex) }
                    agg[r.name] = g
                }
            }
            print("\nfd arguments: \(fdLabeled) of \(fdArgs) labelled")
            for e in socketExamples { print("  " + e.prefix(220)) }
            print("\n\(total) calls in all; still raw, by count:")
            for (name, g) in agg.sorted(by: { $0.value.count > $1.value.count }).prefix(60) {
                print("  \(g.count)  \(name)  [\(g.reasons.sorted().joined(separator: ", "))]  in \(g.procs.sorted().prefix(3).joined(separator: ", "))")
                for e in g.examples { print("        " + e.prefix(200)) }
            }
            return
        }
        if what == "trace" {
            // trace <pid> <seconds> [stacks]: through the helper over XPC, as SyscallTracer does.
            let secs = args.dropFirst(2).first.flatMap { Double($0) } ?? 3
            let stacks = args.contains("stacks")
            let s = HelperTraceSession()
            let t0 = Date()
            let format: SyscallTraceConfig.Format
            switch s.start(pid: pid, stacks: stacks) {
            case .success(let f): format = f
            case .failure(let e): print("trace: \(e.message)"); return
            }
            print(String(format: "trace: format %@, started in %.0f ms", "\(format)", -t0.timeIntervalSinceNow * 1000))
            var dec = SyscallDecoder(stacks: stacks); var recs = 0, events = 0, stopped = false
            var fds = FdLabeler(), shown = 0
            let show = args.contains("show")
            var names: [String: Int] = [:]
            let symbols = StackSymbols()
            var withStack = 0, callers: [String: Int] = [:], examples: [String: SyscallRecord] = [:]
            func take(_ rs: [SyscallRecord]) {
                for r in rs {
                    recs += 1; names[r.name, default: 0] += 1
                    guard !r.stack.isEmpty else { continue }
                    withStack += 1
                    let c = symbols.caller(r.stack)
                    callers["\(r.name) ← \(c)", default: 0] += 1
                    if examples[r.name] == nil || examples.count < 400 { examples["\(r.name)#\(examples.count)"] = r }
                }
            }
            while let (d, running, notes, regions) = s.read() {
                symbols.add(regions)
                if !stopped && -t0.timeIntervalSinceNow > secs { s.stop(); stopped = true }
                if !notes.isEmpty { print("note: " + notes.trimmingCharacters(in: .whitespacesAndNewlines)) }
                let evs = format == .kdebug ? KdebugEvent.decodeRaw(d) : KdebugEvent.decode(d).events
                events += evs.count
                var batch = dec.feed(evs)
                fds.label(&batch) { s.describeFds($0) }
                if show { for r in batch where shown < 40 && !r.name.contains("semwait") { print("  \(r.name)(\(r.namedArgsText)) = \(r.resultText)"); shown += 1 } }
                take(batch)
                if !running { break }
                if d.count < SyscallTraceConfig.maxRead / 2 { usleep(250_000) }
            }
            take(dec.flush())
            // Calls whose arguments have no signature yet (shown as raw words), by count.
            let unknown = names.filter { SyscallFormat.signature($0.key) == nil && $0.key != "mach_msg2_trap" && !["fcntl", "fcntl_nocancel", "open", "open_nocancel", "openat", "openat_nocancel", "setsockopt", "getsockopt", "proc_info", "proc_info_extended_id"].contains($0.key) }
            print("no signature: " + unknown.sorted { $0.value > $1.value }.prefix(15).map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            print("trace: \(events) events, \(recs) records, \(dec.gaps) gaps; top: " + names.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            if stacks {
                print("stacks: \(withStack) of \(recs) records")
                // Distinct frames, and how many got a name, by where they live.
                var seen: [UInt64: StackSymbols.Frame] = [:]
                for r in examples.values { for f in symbols.frames(r.stack) { seen[f.address] = f } }
                print("  example frames: \(seen.count), named \(seen.values.filter { $0.symbol != nil }.count), image only \(seen.values.filter { $0.symbol == nil && !$0.image.isEmpty }.count), unknown \(seen.values.filter { $0.image.isEmpty }.map { "0x" + String($0.address, radix: 16) }.joined(separator: " "))")
                for (k, n) in callers.sorted(by: { $0.value > $1.value }).prefix(8) { print("  \(n)  \(k)") }
                for (name, r) in examples.sorted(by: { $0.key < $1.key }).prefix(4) {
                    print("  \(name):")
                    for f in symbols.frames(r.stack) { print("      " + f.text) }
                }
            }
            return
        }
        if what == "threads" {
            let t0 = Date()
            let local = ThreadReader.read(pid)
            let localMs = -t0.timeIntervalSinceNow * 1000
            let t1 = Date()
            let viaHelper = c.threads(pid)
            let helperMs = -t1.timeIntervalSinceNow * 1000
            print(String(format: "threads %d: local %@ in %.2f ms, helper %@ in %.1f ms", pid,
                         local.map { "\($0.threads.count)" } ?? "nil", localMs, viaHelper.map { "\($0.threads.count)" } ?? "nil", helperMs))
            if let s = viaHelper ?? local {
                if let w = s.workqueue { print("  workqueue \(w.total) running \(w.running) blocked \(w.blocked)") }
                for t in s.threads.prefix(8) {
                    print("  \(t.id) '\(t.name)' cpu \(Fmt.secs(t.cpuNanos)) \(t.stateText) pri \(t.curPriority)/\(t.basePriority)/\(t.maxPriority) \(t.policyText)")
                }
                // Stacks and QoS, as the Threads pane captures them.
                let t2 = Date()
                let stacks = c.run(.stacks, pid: pid) ?? ""
                let st = -t2.timeIntervalSinceNow * 1000
                let t3 = Date()
                let ti = c.run(.taskinfo, pid: pid) ?? ""
                let tt = -t3.timeIntervalSinceNow * 1000
                var d = ThreadDetails()
                d.mergeSample(stacks); d.mergeTaskinfo(ti)
                let ids = Set(s.threads.map(\.id))
                print(String(format: "  stacks %.0f ms (%d threads), taskinfo %.0f ms (%d with QoS); matched %d of %d", st,
                             d.byID.values.filter { !$0.stack.isEmpty }.count, tt, d.byID.values.filter { $0.schedMode != nil }.count,
                             ids.filter { d.byID[$0] != nil }.count, ids.count))
                for t in s.threads.prefix(8) {
                    let x = d.byID[t.id]
                    print("  \(t.id) wait: \(ThreadsView.waitText(x)) | queue: \(x?.queue ?? "-") | qos: \(x?.effectiveQoS ?? "-") \(x?.schedMode ?? "")")
                }
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
        guard let (s, ports) = MachSnapshot.parseWithPorts(data) else { print("not lsmp JSON"); return }
        let pids = args.dropFirst().compactMap { Int32($0) }
        machSummary(s, seconds: -t0.timeIntervalSinceNow, pids: pids)
        print("port details: \(ports.values.reduce(0) { $0 + $1.count }) for \(ports.count) pairs")
        if pids.count == 2 {
            let d = ports[PortPair(pids[0], pids[1])] ?? []
            print("ports \(pids[0]) ↔ \(pids[1]): \(d.count)")
            for x in d.prefix(12) { print("  \(x)") }
        }
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
        let byHandler = Dictionary(grouping: s.exceptionRoutes.filter { $0.handler != $0.process }, by: \.handler)
        print("exception routes: \(s.exceptionRoutes.count), \(s.exceptionRoutes.filter { $0.handler == $0.process }.count) in-process; handlers: "
              + byHandler.sorted { $0.value.count > $1.value.count }.prefix(6).map {
                  "\(Native.process($0.key)?.comm ?? "\($0.key)") \($0.value.count)\(s.isCommonExceptionHandler($0.key) ? " (common)" : "")"
              }.joined(separator: ", "))
        print("links with replies owed \(s.links.filter { $0.repliesOwed > 0 }.count), full queues \(s.links.filter { $0.fullQueues > 0 }.count) (\(s.links.reduce(0) { $0 + $1.fullQueues }) ports), boosts \(s.links.filter { $0.boosts > 0 }.count), no-senders \(s.links.filter { $0.noSenders > 0 }.count)")
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
            guard let p = store.compiledPredicate(c.source) else { print("chip \(c.title): doesn't parse"); continue }
            let n = procs.values.filter { p.test($0, now) }.count
            let shown = store.nodes(grouping: .smart, filter: "", predicate: c.source, sort: .pid)
            print("chip \(c.title): \(n) processes; Smart tree keeps \(rows(shown)) rows")
        }
    }

    /// `ProcXRay --filter <predicate>`: the processes a filter predicate keeps, on a snapshot with CPU % and
    /// signatures read, and what it costs per process. False when it doesn't parse.
    @MainActor static func filter(_ source: String) -> Bool {
        let store = Store()
        let p: PredicateFields.Compiled?
        do { p = try PredicateFields.compile(source, store: store) } catch let e as PredicateError {
            print("error at \(e.offset + 1): \(e.message)")
            return false
        } catch { return false }
        guard let p else { print("blank predicate"); return true }
        let reads = PredicateFields.reads(p)
        let s1 = Store.snapshot(prev: [:], signCache: [:], extras: reads)
        Thread.sleep(forTimeInterval: 1)
        var procs = Store.snapshot(prev: s1.samples, signCache: [:], extras: reads).procs
        for (pid, q) in procs { procs[pid]!.signer = CodeSign.inspect(pid: pid, path: q.path).shortSigner }
        store.procs = procs
        let now = Date()
        let t0 = Date()
        let rounds = 20
        var hits: [ProcInfo] = []
        for _ in 0..<rounds { hits = procs.values.filter { p.test($0, now) } }
        let us = -t0.timeIntervalSinceNow / Double(rounds * max(1, procs.count)) * 1e6
        print("fields: \(p.fields.sorted().joined(separator: ", "))")
        for h in hits.sorted(by: { $0.pid < $1.pid }) { print(String(format: "%6d  %@", h.pid, h.name)) }
        print(String(format: "%d of %d processes; %.2f µs per process", hits.count, procs.count, us))
        return true
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
                              ("jetsam", .jetsam)] {
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
            ("jetsam", .jetsam, { $0.jetsam != nil }),
            ("idle exit", .idleExit, { $0.idleExit != nil }),
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

    /// `ProcXRay --net [seconds]`: NetSampler's rates every 2 s (the five busiest processes), and the CPU time
    /// this process spent reading them. PROCXRAY_APPLE_TOOLS=1 reads them from nettop instead.
    static func net(seconds: Double) {
        // Children too: nettop's own CPU time is the cost of reading through it.
        func cpu() -> Double {
            var u = rusage(), c = rusage(); getrusage(RUSAGE_SELF, &u); getrusage(RUSAGE_CHILDREN, &c)
            func secs(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
            return secs(u.ru_utime) + secs(u.ru_stime) + secs(c.ru_utime) + secs(c.ru_stime)
        }
        let c0 = cpu(), t0 = Date()
        NetSampler.shared.want(true)
        while Date().timeIntervalSince(t0) < seconds {
            Thread.sleep(forTimeInterval: 2)
            NetSampler.shared.want(true)
            guard let net = NetSampler.shared.current() else { print(String(format: "%5.1f s  no rates yet", Date().timeIntervalSince(t0))); continue }
            let top = net.sorted { $0.value.inPerSec + $0.value.outPerSec > $1.value.inPerSec + $1.value.outPerSec }.prefix(5)
            print(String(format: "%5.1f s  %d procs  ", Date().timeIntervalSince(t0), net.count) + top.map {
                "\(Native.process($0.key)?.comm ?? "?")[\($0.key)] in \(Int($0.value.inPerSec)) out \(Int($0.value.outPerSec)) total \($0.value.inTotal.map(String.init) ?? "-")/\($0.value.outTotal.map(String.init) ?? "-")" }.joined(separator: "; "))
        }
        NetSampler.shared.want(false)
        print(String(format: "CPU (self + children): %.3f s over %.1f s", cpu() - c0, Date().timeIntervalSince(t0)))
    }

    /// `ProcXRay --qos <pid>`: CPU time by QoS class against total CPU time, over 2 s.
    /// The Sandbox card's checks for each pid, as a table (0 allowed, 1 denied, ? unknown), and their cost.
    /// The Trust tab for `pid` laid out offscreen at the inspector's width: its content height, and PNGs of the
    /// top and of the content around y = 9000 pt (to <dir>, SANDBOX_PNG_DIR), for checking tall tabs.
    static func trustLayout(_ pid: pid_t) {
        let snap = Store.snapshot(prev: [:], signCache: [:], priv: { nil })
        guard let p = snap.procs[pid] else { print("pid \(pid): not found"); return }
        let sign = CodeSign.inspect(pid: pid, path: p.path)
        MainActor.assumeIsolated {
            let store = Store(); store.procs = snap.procs; store.lsApps = snap.ls
            let host = NSHostingView(rootView: TrustTab(proc: p, sign: sign).environment(store))
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            win.contentView = host
            // Let the cards' .task reads (sandbox checks, TCC) finish and lay out again.
            for _ in 0..<40 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)); host.layoutSubtreeIfNeeded() }
            func find(_ v: NSView) -> NSScrollView? {
                if let s = v as? NSScrollView, (s.documentView?.frame.height ?? 0) > s.frame.height { return s }
                for c in v.subviews { if let s = find(c) { return s } }
                return nil
            }
            guard let sv = find(host), let doc = sv.documentView else { print("no tall scroll view"); return }
            print("pid \(pid) \(p.name): entitlement keys \(sign.entitlementKeys.count), content \(Int(doc.frame.width))x\(Int(doc.frame.height)) pt, \(Int(doc.frame.height * (win.backingScaleFactor))) px at \(win.backingScaleFactor)x")
            guard let dir = ProcessInfo.processInfo.environment["SANDBOX_PNG_DIR"] else { return }
            for (name, y) in [("top", 0.0), ("1500", 1500.0), ("2300", 2300.0), ("9000", 9000.0)] where y < doc.frame.height {
                sv.contentView.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? y : max(0, doc.frame.height - y - sv.frame.height)))
                sv.reflectScrolledClipView(sv.contentView)
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: rep)
                let url = URL(fileURLWithPath: dir).appendingPathComponent("trust-\(pid)-\(name).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print("  rendered \(url.path)")
            }
        }
    }

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
        let proc = Native.process(pid).map { k -> ProcInfo in
            var p = ProcInfo(pid: k.pid, ppid: k.ppid, pgid: k.pgid, uid: k.uid, user: "", comm: k.comm,
                             path: Native.path(k.pid), start: k.start, stat: k.stat, pflags: k.flags)
            p.sandboxed = Native.sandboxed(k.pid, start: k.start)
            return p
        }
        MainActor.assumeIsolated {
            if let p = proc {
                let probe = TCCCard(proc: p, responsible: nil, entitlements: ent)
                let tcc = TCCCard(proc: p, responsible: nil, entitlements: ent, preloaded: TCCGrants.read(clients: probe.clients))
                    .frame(width: 560).padding(10).background(Color(nsColor: .windowBackgroundColor))
                writePNG(tcc, dir: dir, name: "tcc-\(pid).png")
            }
            let view = Card(title: "Sandbox", systemImage: "square.dashed") {
                Text(SandboxCard.summary(true, entitlements: ent)).fixedSize(horizontal: false, vertical: true)
                SandboxProbeTable(report: r, entitlements: ent, recheck: {})
                if let p = proc {
                    Divider()
                    SandboxProfileSection(proc: p, entitlements: ent, preloaded: SandboxProfileInfo.read(pid: pid))
                }
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

    @MainActor private static func writePNG(_ v: some View, dir: String, name: String) {
        let renderer = ImageRenderer(content: v)
        renderer.scale = 2
        guard let img = renderer.nsImage, let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            print("  render failed"); return
        }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
        try? png.write(to: url)
        print("  rendered \(url.path) \(Int(img.size.width))x\(Int(img.size.height)) pt")
    }

    /// `ProcXRay --threads <pid>`: the Threads pane's data without the UI, read as the caller (no helper):
    /// read time, kind from one local sample, and the per-core counters.
    static func threads(_ pid: pid_t) {
        var best = Double.infinity
        var s: ThreadSnapshot?
        for _ in 0..<20 {
            let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            s = ThreadReader.read(pid)
            best = min(best, Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6)
        }
        guard let s else { print("threads \(pid): not readable"); return }
        print(String(format: "threads %d: %d threads, read in %.3f ms (best of 20), %d with core counters", pid, s.threads.count, best,
                     s.threads.filter { $0.cores != nil }.count))
        var d = ThreadDetails()
        d.listedUserNanos = Dictionary(s.threads.map { ($0.id, $0.userNanos) }, uniquingKeysWith: { a, _ in a })
        if let (path, args) = HelperTool.stacks.argv(pid: pid) { d.mergeSample(Shell.run(path, args, timeout: HelperTool.stacks.timeout)) }
        let main = s.threads.first?.id
        for t in s.threads {
            let kind = d.kind(t.id) ?? (t.id == main ? ThreadKind.main : nil)
            let cores = (t.cores ?? []).map { "\(Fmt.secs($0.nanos)) \(ThreadsView.joules($0.energyNJ))" }.joined(separator: " | ")
            print("  \(t.id) \(kind?.text ?? "-") '\(t.name)' cpu \(Fmt.secs(t.cpuNanos)) P \(t.perfShare.map(Fmt.pct) ?? "-") % IPC \(t.ipc.map { String(format: "%.2f", $0) } ?? "-") [\(cores)] queue \(d.byID[t.id]?.queue ?? "-")")
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

    @MainActor static func logLive(pid: Int32, seconds: Double, out: String) {
        guard let start = Native.process(pid)?.start else { print("no process \(pid)"); return }
        let s = LogSession()
        let t0 = Date()
        s.startLive(pid: pid, start: start)
        var histAt: Date?
        while Date().timeIntervalSince(t0) < seconds {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if histAt == nil, !s.loadingHistory { histAt = Date() }
        }
        let stopAt = Date()
        s.stop()
        while s.isActive { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let stopped = Date().timeIntervalSince(stopAt)
        print(String(format: "history in %.2f s; stopped %.2f s after Stop; %d entries, %d raw lines, revisions %d, notes %@",
                     histAt.map { $0.timeIntervalSince(t0) } ?? -1, stopped, s.entries.count, s.rawLines.count, s.revision,
                     s.notes.description))
        let ids = s.entries.map(\.id)
        print("entry ids strictly increasing: \(zip(ids, ids.dropFirst()).allSatisfy { $0 < $1 })")
        FileManager.default.createFile(atPath: out, contents: s.rawLines.joined(separator: "\n").data(using: .utf8))
    }
}

extension Bench {
    /// As root: --bank <seconds>. Records BANK settlements (BankLedger) and checks them against the rusage totals
    /// they should add up to: per merchant against the change in ri_serviced_*, per holder against ri_billed_*.
    static func bank(seconds: Double) {
        func totals() -> [Int32: (serviced: UInt64, billed: UInt64, sNJ: UInt64, bNJ: UInt64)] {
            var out: [Int32: (UInt64, UInt64, UInt64, UInt64)] = [:]
            for k in Native.allProcesses() where k.pid > 0 {
                if let r = Native.rusage(k.pid) {
                    out[k.pid] = (Native.machToNanos(r.ri_serviced_system_time), Native.machToNanos(r.ri_billed_system_time),
                                  r.ri_serviced_energy, r.ri_billed_energy)
                }
            }
            return out
        }
        let before = totals()
        let rec: BankLedger.Recording
        switch BankLedger.record(seconds: seconds) {
        case .success(let r): rec = r
        case .failure(.refused(let why)), .failure(.failed(let why)): print("bank: \(why)"); return
        }
        let after = totals()
        let cpu = rec.flows.reduce(0) { $0 + $1.cpuNanos }, nrg = rec.flows.reduce(0) { $0 + $1.energyNJ }
        print(String(format: "%.1f s: %d pairs, %d settlements, %.3f s CPU, %.3f J, %d lost marks", rec.seconds, rec.flows.count,
                     rec.flows.reduce(0) { $0 + $1.count }, Double(cpu) / 1e9, Double(nrg) / 1e9, rec.lost))
        for f in rec.flows.prefix(15) {
            print(String(format: "  %@(%d) for %@(%d): %.3f ms, %.3f mJ, %d", f.merchantName, f.merchant, f.holderName, f.holder,
                         Double(f.cpuNanos) / 1e6, Double(f.energyNJ) / 1e6, f.count))
        }
        func check(_ label: String, _ key: (BankLedger.Flow) -> Int32, _ delta: (Int32) -> Int64?) {
            var byPid: [Int32: UInt64] = [:]
            for f in rec.flows { byPid[key(f), default: 0] += f.cpuNanos }
            var exact = 0, off = 0, gone = 0
            var worst: [(Int32, Int64, UInt64)] = []
            for (pid, sum) in byPid {
                guard let d = delta(pid) else { gone += 1; continue }
                // Allow 1 µs of rounding from summing ticks then converting, against converting each total.
                if abs(d - Int64(sum)) <= 1_000 { exact += 1 } else { off += 1; worst.append((pid, d, sum)) }
            }
            print("\(label): \(exact) match, \(off) differ, \(gone) exited")
            for (pid, d, s) in worst.sorted(by: { abs($0.1 - Int64($0.2)) > abs($1.1 - Int64($1.2)) }).prefix(6) {
                print(String(format: "    pid %d: rusage delta %.3f ms, events %.3f ms", pid, Double(d) / 1e6, Double(s) / 1e6))
            }
        }
        check("merchants vs serviced", \.merchant) { p in before[p].flatMap { b in after[p].map { Int64($0.serviced) - Int64(b.serviced) } } }
        check("holders vs billed", \.holder) { p in before[p].flatMap { b in after[p].map { Int64($0.billed) - Int64(b.billed) } } }
        // Processes whose totals moved with no settlement seen.
        var unseen = 0
        let merchants = Set(rec.flows.map(\.merchant))
        for (p, a) in after { if let b = before[p], a.serviced > b.serviced, !merchants.contains(p) { unseen += 1 } }
        print("serviced totals that moved with no event: \(unseen); settlements with a debit: \(rec.debits)")
        var dS: Int64 = 0, dB: Int64 = 0
        for (p, a) in after { if let b = before[p] { dS += Int64(a.serviced) - Int64(b.serviced); dB += Int64(a.billed) - Int64(b.billed) } }
        print(String(format: "all processes: serviced +%.3f s, billed +%.3f s, events %.3f s", Double(dS) / 1e9, Double(dB) / 1e9, Double(cpu) / 1e9))
    }
}
