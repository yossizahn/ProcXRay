import Foundation

/// Runs as root under launchd when the binary is started with `--helper`.
enum HelperDaemon {
    static func run() -> Never {
        // Anything a tool writes as root stays private to root.
        umask(0o077)
        let delegate = ListenerDelegate()
        let listener = NSXPCListener(machServiceName: HelperConfig.machService)
        // Reject any client that isn't ProcXRay signed by our team (enforced by the kernel/XPC, not by us parsing anything).
        listener.setConnectionCodeSigningRequirement(HelperConfig.peerRequirement)
        listener.delegate = delegate
        listener.resume()
        NSLog("ProcXRay helper %d listening on %@", getpid(), HelperConfig.machService)
        withExtendedLifetime((listener, delegate)) { dispatchMain() }
    }

    final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
        private var live = 0
        private let q = DispatchQueue(label: "helper.connections")

        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
            c.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
            let service = Service(callerUID: c.effectiveUserIdentifier)
            c.exportedObject = service
            q.sync { live += 1 }
            // The app drops a tool's connection when nobody waits for the result any more: stop the tool.
            c.invalidationHandler = { [weak self] in
                service.cancel.cancel()
                service.endTrace()
                self?.connectionEnded()
            }
            c.resume()
            return true
        }

        /// Exit ~10s after the last client goes away; launchd relaunches on demand.
        private func connectionEnded() {
            q.async {
                self.live -= 1
                guard self.live <= 0 else { return }
                self.q.asyncAfter(deadline: .now() + 10) {
                    if self.live <= 0 { NSLog("ProcXRay helper idle, exiting"); exit(0) }
                }
            }
        }
    }

    /// One per connection. The helper hands a caller nothing it couldn't get on its own or with sudo:
    /// another user's process (arguments, environment, tools) only for an admin caller.
    final class Service: NSObject, HelperProtocol {
        private let callerUID: uid_t
        private let callerIsAdmin: Bool
        /// Fired when this connection ends; terminates tools still running for it.
        let cancel = Shell.Cancel()

        init(callerUID: uid_t) {
            self.callerUID = callerUID
            callerIsAdmin = Native.isAdmin(callerUID)
        }

        private func mayInspect(_ pid: Int32) -> Bool {
            if callerIsAdmin { return true }
            guard let p = Native.process(pid) else { return false }
            return p.uid == callerUID && p.ruid == callerUID
        }

        func version(reply: @escaping (Int, Int32) -> Void) { reply(HelperConfig.protocolVersion, getpid()) }

        func allMetrics(extras: Int, reply: @escaping (Data) -> Void) {
            let extras = ExtraReads(rawValue: extras).intersection(.viaHelper)
            var out: [PrivMetrics] = []
            let jetsam = extras.contains(.jetsam) ? Jetsam.all() : nil
            for k in Native.allProcesses() where k.pid > 0 {
                // Usage of another user's process is root-only in the kernel (proc_pid_rusage checks
                // same-user): a standard user gets it for their own processes only, as without the helper.
                var m = mayInspect(k.pid) ? PrivMetrics.read(k.pid) : PrivMetrics(pid: k.pid)
                if mayInspect(k.pid) { m.readExtras(extras); m.jetsam = jetsam?[k.pid] }
                m.responsible = Native.responsible(k.pid)
                m.sandboxed = Native.sandboxed(k.pid, start: k.start)
                out.append(m)
            }
            reply((try? JSONEncoder().encode(out)) ?? Data())
        }

        func argsEnv(pid: Int32, reply: @escaping (Data?) -> Void) {
            guard pid > 0, mayInspect(pid), let a = Native.argsEnv(pid) else { reply(nil); return }
            let v = PrivArgsEnv(execPath: a.execPath, args: a.args, env: a.env, cwd: Native.cwd(pid))
            reply(try? JSONEncoder().encode(v))
        }

        func securityConfig(pid: Int32, reply: @escaping (Data?) -> Void) {
            guard pid > 0, mayInspect(pid), let d = SecurityDetail.read(pid) else { reply(nil); return }
            reply(try? JSONEncoder().encode(d))
        }

        func threads(pid: Int32, reply: @escaping (Data?) -> Void) {
            guard pid > 0, mayInspect(pid), let t = ThreadReader.read(pid) else { reply(nil); return }
            reply(try? JSONEncoder().encode(t))
        }

        func machPorts(reply: @escaping (Data?, String?) -> Void) {
            guard callerIsAdmin else { reply(nil, "Mach ports of every process can only be read for an admin user."); return }
            let cancel = self.cancel
            DispatchQueue.global(qos: .userInitiated).async {
                switch MachPortCache.run(cancel: cancel) {
                case .success(let snap): reply(try? JSONEncoder().encode(snap), nil)
                case .failure(let e): reply(nil, e.message)
                }
            }
        }

        func machPortDetail(pid: Int32, peer: Int32, reply: @escaping (Data?, String?) -> Void) {
            guard callerIsAdmin else { reply(nil, "Mach ports of every process can only be read for an admin user."); return }
            let cancel = self.cancel
            DispatchQueue.global(qos: .userInitiated).async {
                // From the last run (the one the app's snapshot came from), unless the helper has restarted
                // since (it exits when idle): then a run of its own.
                if MachPortCache.last() == nil, case .failure(let e) = MachPortCache.run(cancel: cancel) { reply(nil, e.message); return }
                guard let c = MachPortCache.last() else { reply(nil, "no Mach snapshot"); return }
                let r = MachPortDetailReply(at: c.at, ports: c.ports[PortPair(pid, peer)] ?? [])
                reply(try? JSONEncoder().encode(r), nil)
            }
        }

        /// Runs off the connection's queue: messages on one connection are delivered one at a time, so a
        /// 13 s sample run inline held up the app's metrics refresh and health probe behind it.
        func runTool(_ tool: Int, pid: Int32, reply: @escaping (String) -> Void) {
            guard let t = HelperTool(rawValue: tool), let (path, args) = t.argv(pid: pid) else {
                reply("helper: rejected tool \(tool) pid \(pid)")
                return
            }
            guard t == .btmDump || t == .lsofAll || t == .powermetrics ? callerIsAdmin : mayInspect(pid) else {
                reply("helper: only an admin user can inspect another user's processes or all background items")
                return
            }
            let cancel = self.cancel
            DispatchQueue.global(qos: .userInitiated).async {
                if let text = NativeTools.run(t, pid: pid) { reply(text); return }
                let r = Shell.Cancel.$current.withValue(cancel) {
                    Shell.exec(path, args, timeout: t.timeout, maxBytes: HelperTool.maxOutput)
                }
                reply(r.annotated)
            }
        }

        func groupFootprint(_ pids: Data, reply: @escaping (String?, String?) -> Void) {
            guard let list = try? JSONDecoder().decode([Int32].self, from: pids), list.count <= GroupFootprint.maxPids else {
                reply(nil, "helper: rejected pid list"); return
            }
            let ok = Array(Set(list.filter { $0 > 0 && mayInspect($0) })).sorted()
            guard !ok.isEmpty else { reply(nil, "none of these processes can be read for this user"); return }
            let cancel = self.cancel
            // Off the connection's queue, like runTool: a long run mustn't hold up the metrics refresh.
            DispatchQueue.global(qos: .utility).async {
                let r = Shell.Cancel.$current.withValue(cancel) {
                    Shell.exec(GroupFootprint.tool, GroupFootprint.argv(ok), mergeStderr: false, timeout: GroupFootprint.timeout)
                }
                r.timedOut || r.status == -1 ? reply(nil, r.annotated) : reply(r.output, nil)
            }
        }

        func bankLedger(seconds: Int, reply: @escaping (Data?, String?) -> Void) {
            guard callerIsAdmin else { reply(nil, "Recording who works for whom covers every process: only an admin user can."); return }
            guard seconds > 0 else { reply(nil, "helper: rejected duration \(seconds)"); return }
            let cancel = self.cancel
            DispatchQueue.global(qos: .userInitiated).async {
                switch BankLedger.record(seconds: Double(min(seconds, BankLedger.maxSeconds)), cancel: cancel) {
                case .success(let r): reply(try? JSONEncoder().encode(r), nil)
                case .failure(.refused(let why)), .failure(.failed(let why)): reply(nil, why)
                }
            }
        }

        // MARK: syscall trace

        private let traceLock = NSLock()
        private var trace: TraceSource?
        private var tracedPid: Int32 = 0
        private var traceRunning: Bool { trace.map { $0.read(max: 0).1 } ?? false }

        func traceStart(pid: Int32, stacks: Bool, reply: @escaping (String?, Int) -> Void) {
            guard let (path, args) = SyscallTraceConfig.argv(pid: pid) else { reply("helper: rejected pid \(pid)", 0); return }
            guard mayInspect(pid) else { reply("Only an admin user can trace another user's processes.", 0); return }
            traceLock.lock(); defer { traceLock.unlock() }
            if traceRunning { reply("A trace is already running on this connection.", 0); return }
            // The helper's own kdebug reader unless told to use Apple's tools; ktrace when the reader can't set up
            // for any reason but another tracer holding kdebug (which ktrace would hit too).
            var note = ""
            if NativeTools.enabled {
                switch KdebugTrace.start(pid: pid, stacks: stacks, maxPending: SyscallTraceConfig.maxPending, maxSeconds: SyscallTraceConfig.maxSeconds) {
                case .success(let t):
                    trace = t
                    tracedPid = pid
                    reply(nil, SyscallTraceConfig.Format.kdebug.rawValue)
                    return
                case .failure(.refused(let why)):
                    reply(why, 0)
                    return
                case .failure(.failed(let why)):
                    NSLog("ProcXRay helper: kdebug reader failed (%@), using ktrace", why)
                    note = "The helper could not read the kernel trace itself (\(why)): using ktrace, which loses events above ~80k calls/s without saying so.\n"
                }
            }
            let t = TraceProcess(maxPending: SyscallTraceConfig.maxPending, note: note)
            if let err = t.start(path, args) { reply(err, 0); return }
            trace = t
            tracedPid = pid
            reply(nil, SyscallTraceConfig.Format.ndjson.rawValue)
        }

        func traceRead(reply: @escaping (Data, Bool, String, Data) -> Void) {
            traceLock.lock(); let t = trace; traceLock.unlock()
            guard let t else { reply(Data(), false, "", Data()); return }
            let (d, running, notes) = t.read(max: SyscallTraceConfig.maxRead)
            // After the read: the regions for every frame in `d` were queued before its records were.
            reply(d, running, notes, t.newRegions())
        }

        func traceDescribeFds(_ fds: Data, reply: @escaping (Data) -> Void) {
            traceLock.lock(); let pid = trace == nil ? 0 : tracedPid; traceLock.unlock()
            guard pid > 0, let list = try? JSONDecoder().decode([Int32].self, from: fds) else { reply(Data()); return }
            let d = NativeLsof.describe(pid, fds: Set(list.prefix(4096)))
            reply((try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: d.map { (String($0.key), $0.value) }))) ?? Data())
        }

        func traceStop(reply: @escaping () -> Void) {
            endTrace()
            reply()
        }

        /// Also called when the connection ends: a trace never outlives the app that asked for it.
        func endTrace() {
            traceLock.lock(); let t = trace; traceLock.unlock()
            t?.stop()
        }
    }
}

/// The helper's lsmp runs: each one's snapshot goes to the app, and its per-pair ports stay here for
/// `machPortDetail` (~60 k entries for 800 processes).
enum MachPortCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (at: Date, ports: [PortPair: [MachPortDetail]])?

    static func last() -> (at: Date, ports: [PortPair: [MachPortDetail]])? { lock.lock(); defer { lock.unlock() }; return cached }

    static func run(cancel: Shell.Cancel?) -> Swift.Result<MachSnapshot, MachLoader.Failure> {
        if NativeTools.enabled, let procs = NativeMach.processes() {
            let parsed = MachSnapshot.parseWithPorts(processes: procs)
            lock.lock(); cached = (parsed.snapshot.at, parsed.ports); lock.unlock()
            return .success(parsed.snapshot)
        }
        // lsmp writes its JSON to a path. A directory of root's own (umask 077), so no other user can
        // read the port map or plant a file there.
        var template = Array((NSTemporaryDirectory() + "procxray-lsmp.XXXXXX").utf8CString)
        guard let dir = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress) }).map({ String(cString: $0) }) else {
            return .failure(.init(message: "helper: no temporary directory"))
        }
        let file = dir + "/ports.json"
        defer { unlink(file); rmdir(dir) }
        let r = Shell.Cancel.$current.withValue(cancel) {
            // Its text listing (as long as the JSON) goes nowhere; stderr comes back for errors.
            Shell.exec("/usr/bin/lsmp", ["-a", "-j", file], timeout: 40, discardStdout: true)
        }
        guard let data = FileManager.default.contents(atPath: file), let parsed = MachSnapshot.parseWithPorts(data) else {
            let why = r.timedOut ? "lsmp ran past its time limit" : r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.init(message: "lsmp failed: \(why.isEmpty ? "exit \(r.status)" : why)"))
        }
        lock.lock(); cached = (parsed.snapshot.at, parsed.ports); lock.unlock()
        return .success(parsed.snapshot)
    }
}
