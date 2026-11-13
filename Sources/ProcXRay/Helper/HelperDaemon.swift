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
            for k in Native.allProcesses() where k.pid > 0 {
                // Usage of another user's process is root-only in the kernel (proc_pid_rusage checks
                // same-user): a standard user gets it for their own processes only, as without the helper.
                var m = mayInspect(k.pid) ? PrivMetrics.read(k.pid) : PrivMetrics(pid: k.pid)
                if mayInspect(k.pid) { m.readExtras(extras) }
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

        func machPorts(reply: @escaping (Data?, String?) -> Void) {
            guard callerIsAdmin else { reply(nil, "Mach ports of every process can only be read for an admin user."); return }
            let cancel = self.cancel
            DispatchQueue.global(qos: .userInitiated).async {
                // lsmp writes its JSON to a path. A directory of root's own (umask 077), so no other user can
                // read the port map or plant a file there.
                var template = Array((NSTemporaryDirectory() + "procxray-lsmp.XXXXXX").utf8CString)
                guard let dir = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress) }).map({ String(cString: $0) }) else {
                    reply(nil, "helper: no temporary directory"); return
                }
                let file = dir + "/ports.json"
                defer { unlink(file); rmdir(dir) }
                let r = Shell.Cancel.$current.withValue(cancel) {
                    // Its text listing (as long as the JSON) goes nowhere; stderr comes back for errors.
                    Shell.exec("/usr/bin/lsmp", ["-a", "-j", file], timeout: 40, discardStdout: true)
                }
                guard let data = FileManager.default.contents(atPath: file), let snap = MachSnapshot.parse(data) else {
                    let why = r.timedOut ? "lsmp ran past its time limit" : r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    reply(nil, "lsmp failed: \(why.isEmpty ? "exit \(r.status)" : why)"); return
                }
                reply(try? JSONEncoder().encode(snap), nil)
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
                let r = Shell.Cancel.$current.withValue(cancel) {
                    Shell.exec(path, args, timeout: t.timeout, maxBytes: HelperTool.maxOutput)
                }
                reply(r.annotated)
            }
        }

        // MARK: syscall trace

        private let traceLock = NSLock()
        private var trace: TraceProcess?

        func traceStart(pid: Int32, reply: @escaping (String?) -> Void) {
            guard let (path, args) = SyscallTraceConfig.argv(pid: pid) else { reply("helper: rejected pid \(pid)"); return }
            guard mayInspect(pid) else { reply("Only an admin user can trace another user's processes."); return }
            traceLock.lock(); defer { traceLock.unlock() }
            if let t = trace, t.read(max: 0).1 { reply("A trace is already running on this connection."); return }
            let t = TraceProcess(maxPending: SyscallTraceConfig.maxPending)
            if let err = t.start(path, args) { reply(err); return }
            trace = t
            reply(nil)
        }

        func traceRead(reply: @escaping (Data, Bool, String) -> Void) {
            traceLock.lock(); let t = trace; traceLock.unlock()
            guard let t else { reply(Data(), false, ""); return }
            let (d, running, notes) = t.read(max: SyscallTraceConfig.maxRead)
            reply(d, running, notes)
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
