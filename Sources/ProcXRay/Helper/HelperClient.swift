import Foundation
import ServiceManagement

/// What a refresh asks the helper for: the processes the app couldn't read itself last time, and whatever
/// started since then (seconds since 1970). See HelperProtocol.metrics.
struct HelperAsk: Sendable {
    var pids: [Int32]
    var since: Double
}

/// App-side access to the root helper. Thread-safe; calls are synchronous and meant for background tasks.
final class HelperClient: @unchecked Sendable {
    static let shared = HelperClient()

    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var lastMetrics: (at: UInt64, metrics: [Int32: PrivMetrics])?
    /// Called (on an XPC queue) when the shared connection is interrupted or invalidated: the helper
    /// died, was disabled or was replaced, so whoever shows its state should probe again.
    var onConnectionLost: (@Sendable () -> Void)?

    var service: SMAppService { SMAppService.daemon(plistName: HelperConfig.plistName) }

    enum State: Equatable {
        case notInstalled, needsApproval, notFound, running(pid: Int32), unreachable(String)
        var label: String {
            switch self {
            case .notInstalled: "Helper not installed"
            case .needsApproval: "Helper needs approval in Login Items"
            case .notFound: "Helper plist missing from bundle"
            case .running(let pid): "Helper running as root (pid \(pid))"
            case .unreachable(let e): "Helper unreachable: \(e)"
            }
        }
        var isRunning: Bool { if case .running = self { true } else { false } }
    }

    func register() throws { try service.register() }
    func unregister() throws {
        invalidate()
        try service.unregister()
    }
    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    /// Checks registration, then pings the helper (which launchd starts on demand).
    func probe() -> State {
        switch service.status {
        case .notRegistered: return .notInstalled
        case .requiresApproval: return .needsApproval
        case .notFound:
            // SMAppService also reports .notFound for a daemon that was simply never registered.
            let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(HelperConfig.plistName)")
            return FileManager.default.fileExists(atPath: plist.path) ? .notInstalled : .notFound
        case .enabled: break
        @unknown default: return .unreachable("unknown SMAppService status")
        }
        var result: State = .unreachable("no reply")
        let sem = DispatchSemaphore(value: 0)
        let proxy = proxy { err in result = .unreachable(err.localizedDescription); sem.signal() }
        proxy?.version { v, pid in
            result = v == HelperConfig.protocolVersion ? .running(pid: pid) : .unreachable("helper protocol v\(v), app v\(HelperConfig.protocolVersion)")
            sem.signal()
        }
        if proxy == nil { return .unreachable("no connection") }
        if sem.wait(timeout: .now() + 3) == .timedOut { return .unreachable("timed out") }
        return result
    }

    func allMetrics(extras: ExtraReads = [], timeout: Double = 15) -> [Int32: PrivMetrics]? {
        allMetricsTimed(extras: extras, timeout: timeout)?.metrics
    }

    /// allMetrics with when it was read (uptime nanoseconds, halfway through the call), for working out rates.
    func allMetricsTimed(extras: ExtraReads = [], timeout: Double = 15) -> (at: UInt64, metrics: [Int32: PrivMetrics])? {
        metrics(HelperAsk?.none, extras: extras, timeout: timeout)
    }

    /// The helper's reading of the processes in `ask` (nil: of every process), with when it was read.
    func metrics(_ ask: HelperAsk?, extras: ExtraReads = [], timeout: Double = 15) -> (at: UInt64, metrics: [Int32: PrivMetrics])? {
        let sent = DispatchTime.now().uptimeNanoseconds
        guard let data = PerfStages.measure(.helperCall, {
            call({ p, done in
                if let ask {
                    let pids = ask.pids.withUnsafeBufferPointer { Data(buffer: $0) }
                    p.metrics(pids: pids, since: ask.since, extras: extras.rawValue) { done($0) }
                } else {
                    p.allMetrics(extras: extras.rawValue) { done($0) }
                }
            }, timeout: timeout) as Data?
        }) else { return nil }
        let at = sent + (DispatchTime.now().uptimeNanoseconds - sent) / 2
        guard let list = PerfStages.measure(.helperDecode, { try? JSONDecoder().decode([PrivMetrics].self, from: data) })
        else { return nil }
        let out = (at: at, metrics: Dictionary(list.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a }))
        lock.lock(); lastMetrics = out; lock.unlock()
        return out
    }

    /// The last allMetrics reply when it's at most `maxAge` seconds old: the menu bar monitor reuses the process
    /// list's instead of asking the helper again (each reply costs the helper ~40 ms of CPU, billed to the app).
    func recentMetrics(maxAge: Double) -> (at: UInt64, metrics: [Int32: PrivMetrics])? {
        lock.lock(); defer { lock.unlock() }
        guard let m = lastMetrics, DispatchTime.now().uptimeNanoseconds &- m.at <= UInt64(maxAge * 1e9) else { return nil }
        return m
    }

    func argsEnv(_ pid: Int32) -> PrivArgsEnv? {
        guard let data = call({ p, done in p.argsEnv(pid: pid) { done($0) } }) ?? nil else { return nil }
        return try? JSONDecoder().decode(PrivArgsEnv.self, from: data)
    }

    func securityDetail(_ pid: Int32) -> SecurityDetail? {
        guard let data = call({ p, done in p.securityConfig(pid: pid) { done($0) } }, timeout: 3) ?? nil else { return nil }
        return try? JSONDecoder().decode(SecurityDetail.self, from: data)
    }

    func taskDetail(_ pid: Int32) -> TaskDetail? {
        guard let data = call({ p, done in p.taskDetail(pid: pid) { done($0) } }, timeout: 3) ?? nil else { return nil }
        return try? JSONDecoder().decode(TaskDetail.self, from: data)
    }

    func threads(_ pid: Int32) -> ThreadSnapshot? {
        guard let data = call({ p, done in p.threads(pid: pid) { done($0) } }, timeout: 3) ?? nil else { return nil }
        return try? JSONDecoder().decode(ThreadSnapshot.self, from: data)
    }

    /// System counters only root reads (HelperProtocol.systemCounters); nil when the helper didn't answer.
    func systemCounters(timeout: Double = 3) -> HelperCounters? {
        guard let data = call({ p, done in p.systemCounters { done($0) } }, timeout: timeout) as Data? else { return nil }
        return try? JSONDecoder().decode(HelperCounters.self, from: data)
    }

    /// The helper's network reading (HelperProtocol.netRates); nil when it didn't answer or can't read.
    func netRates(every: Double, timeout: Double = 3) -> NetRatesReply? {
        guard let data = call({ p, done in p.netRates(every: every) { done($0) } }, timeout: timeout) as Data? else { return nil }
        return try? JSONDecoder().decode(NetRatesReply.self, from: data)
    }

    /// `footprint`'s output for these processes, run as root (HelperProtocol.groupFootprint); nil when the helper
    /// couldn't run it.
    func groupFootprint(_ pids: [Int32]) -> String? {
        guard let data = try? JSONEncoder().encode(pids) else { return nil }
        let r: (String?, String?)? = call({ p, done in p.groupFootprint(data) { done(($0, $1)) } }, timeout: GroupFootprint.timeout + 5)
        return r?.0
    }

    /// Runs on a connection of its own: when the caller's `Shell.Cancel` fires (the window closed, the
    /// selection moved on), the connection is invalidated and the helper stops the tool, as the local path
    /// does. On the shared connection the helper would run it to completion as root for nobody.
    func run(_ tool: HelperTool, pid: Int32 = 0, timeout: Double = 60) -> String? {
        let cancel = Shell.Cancel.current
        let c = makeConnection()
        defer { c.invalidate() }
        let lock = NSLock()
        var out: String?
        let sem = DispatchSemaphore(value: 0)
        guard let p = c.remoteObjectProxyWithErrorHandler({ _ in sem.signal() }) as? HelperProtocol else { return nil }
        p.runTool(tool.rawValue, pid: pid) { v in lock.lock(); out = v; lock.unlock(); sem.signal() }
        let deadline = DispatchTime.now() + timeout
        while sem.wait(timeout: .now() + 0.1) == .timedOut {
            if cancel?.isCancelled == true || DispatchTime.now() >= deadline { break }
        }
        lock.lock(); defer { lock.unlock() }
        return out
    }

    /// The machine's Mach port links (see MachSnapshot). Its own connection, like `run`, so a closed tab
    /// stops lsmp in the helper.
    func machPorts(timeout: Double = 60) -> Swift.Result<MachSnapshot, MachLoader.Failure> {
        let cancel = Shell.Cancel.current
        let c = makeConnection()
        defer { c.invalidate() }
        let lock = NSLock()
        var out: (Data?, String?) = (nil, "the helper did not answer")
        let sem = DispatchSemaphore(value: 0)
        guard let p = c.remoteObjectProxyWithErrorHandler({ e in
            lock.lock(); out = (nil, "helper: \(e.localizedDescription)"); lock.unlock(); sem.signal()
        }) as? HelperProtocol else { return .failure(.init(message: "no helper connection")) }
        p.machPorts { d, e in lock.lock(); out = (d, e); lock.unlock(); sem.signal() }
        let deadline = DispatchTime.now() + timeout
        while sem.wait(timeout: .now() + 0.1) == .timedOut {
            if cancel?.isCancelled == true || DispatchTime.now() >= deadline { break }
        }
        lock.lock(); defer { lock.unlock() }
        if let d = out.0, let s = try? JSONDecoder().decode(MachSnapshot.self, from: d) { return .success(s) }
        return .failure(.init(message: out.1 ?? "unreadable reply from the helper"))
    }

    /// The ports between two processes (HelperProtocol.machPortDetail), on a connection of its own.
    func machPortDetail(pid: Int32, peer: Int32, timeout: Double = 60) -> Swift.Result<MachPortDetailReply, MachLoader.Failure> {
        let c = makeConnection()
        defer { c.invalidate() }
        let lock = NSLock()
        var out: (Data?, String?) = (nil, "the helper did not answer")
        let sem = DispatchSemaphore(value: 0)
        guard let p = c.remoteObjectProxyWithErrorHandler({ e in
            lock.lock(); out = (nil, "helper: \(e.localizedDescription)"); lock.unlock(); sem.signal()
        }) as? HelperProtocol else { return .failure(.init(message: "no helper connection")) }
        p.machPortDetail(pid: pid, peer: peer) { d, e in lock.lock(); out = (d, e); lock.unlock(); sem.signal() }
        _ = sem.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }
        if let d = out.0, let r = try? JSONDecoder().decode(MachPortDetailReply.self, from: d) { return .success(r) }
        return .failure(.init(message: out.1 ?? "unreadable reply from the helper"))
    }

    /// One process's port names that lead to no other process (HelperProtocol.machPortKinds).
    func machPortKinds(pid: Int32, timeout: Double = 60) -> Swift.Result<[UInt32: String], MachLoader.Failure> {
        let c = makeConnection()
        defer { c.invalidate() }
        let lock = NSLock()
        var out: (Data?, String?) = (nil, "the helper did not answer")
        let sem = DispatchSemaphore(value: 0)
        guard let p = c.remoteObjectProxyWithErrorHandler({ e in
            lock.lock(); out = (nil, "helper: \(e.localizedDescription)"); lock.unlock(); sem.signal()
        }) as? HelperProtocol else { return .failure(.init(message: "no helper connection")) }
        p.machPortKinds(pid: pid) { d, e in lock.lock(); out = (d, e); lock.unlock(); sem.signal() }
        _ = sem.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }
        if let d = out.0, let r = try? JSONDecoder().decode([UInt32: String].self, from: d) { return .success(r) }
        return .failure(.init(message: out.1 ?? "unreadable reply from the helper"))
    }

    /// Voucher settlements per pair of processes over `seconds` (HelperProtocol.bankLedger), on a connection of
    /// its own so a cancelled caller (Shell.Cancel.current) stops the recording in the helper.
    func bankLedger(seconds: Int) -> Swift.Result<BankLedger.Recording, MachLoader.Failure> {
        let cancel = Shell.Cancel.current
        let c = makeConnection()
        defer { c.invalidate() }
        let lock = NSLock()
        var out: (Data?, String?) = (nil, "the helper did not answer")
        let sem = DispatchSemaphore(value: 0)
        guard let p = c.remoteObjectProxyWithErrorHandler({ e in
            lock.lock(); out = (nil, "helper: \(e.localizedDescription)"); lock.unlock(); sem.signal()
        }) as? HelperProtocol else { return .failure(.init(message: "no helper connection")) }
        p.bankLedger(seconds: seconds) { d, e in lock.lock(); out = (d, e); lock.unlock(); sem.signal() }
        let deadline = DispatchTime.now() + .seconds(seconds + 15)
        while sem.wait(timeout: .now() + 0.1) == .timedOut {
            if cancel?.isCancelled == true || DispatchTime.now() >= deadline { break }
        }
        lock.lock(); defer { lock.unlock() }
        if let d = out.0, let r = try? JSONDecoder().decode(BankLedger.Recording.self, from: d) { return .success(r) }
        return .failure(.init(message: out.1 ?? "unreadable reply from the helper"))
    }

    /// HelperProtocol.launch: a program started by the helper, as root or another user.
    func launch(_ r: Launcher.Request, authorization: Data) -> Result<(Launcher.Child, FileHandle?, FileHandle?), LaunchError> {
        guard let body = try? JSONEncoder().encode(r) else { return .failure(LaunchError(message: "Couldn't encode the launch.")) }
        typealias Reply = (Data?, FileHandle?, FileHandle?, String?)
        guard let (data, out, err, why) = call({ (p: HelperProtocol, done: @escaping (Reply) -> Void) in
            p.launch(body, authorization: authorization) { done(($0, $1, $2, $3)) }
        }, timeout: 20) else { return .failure(LaunchError(message: "The helper didn't answer.")) }
        if let why { return .failure(LaunchError(message: why)) }
        guard let data, let child = try? JSONDecoder().decode(Launcher.Child.self, from: data) else {
            return .failure(LaunchError(message: "The helper's reply couldn't be read."))
        }
        return .success((child, out, err))
    }

    /// HelperProtocol.launched: signals a program the helper launched (0: none) and says whether it has ended.
    /// Nil when the helper can't be asked.
    @discardableResult
    func launched(pid: Int32, signal: Int32 = 0) -> (exit: Launcher.Exit?, error: String?)? {
        typealias Reply = (Data?, String?)
        guard let (data, why) = call({ (p: HelperProtocol, done: @escaping (Reply) -> Void) in
            p.launched(pid: pid, signal: signal) { done(($0, $1)) }
        }, timeout: 5) else { return nil }
        return (data.flatMap { try? JSONDecoder().decode(Launcher.Exit.self, from: $0) }, why)
    }

    // MARK: plumbing

    private func call<T>(_ body: (HelperProtocol, @escaping (T) -> Void) -> Void, timeout: Double = 15) -> T? {
        // The reply can arrive after we stopped waiting; the lock keeps that late write from racing the read.
        let lock = NSLock()
        var out: T?
        let sem = DispatchSemaphore(value: 0)
        guard let p = proxy({ _ in sem.signal() }) else { return nil }
        body(p) { v in lock.lock(); out = v; lock.unlock(); sem.signal() }
        _ = sem.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }
        return out
    }

    private func proxy(_ onError: @escaping (Error) -> Void) -> HelperProtocol? {
        lock.lock(); defer { lock.unlock() }
        if connection == nil {
            let c = makeConnection()
            c.invalidationHandler = { [weak self] in self?.dropConnection(c) }
            c.interruptionHandler = { [weak self] in self?.dropConnection(c) }
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler(onError) as? HelperProtocol
    }

    private func makeConnection() -> NSXPCConnection {
        let c = NSXPCConnection(machServiceName: HelperConfig.machService, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        // Only talk to a helper that is our own signed binary.
        c.setCodeSigningRequirement(HelperConfig.peerRequirement)
        c.resume()
        return c
    }

    private func dropConnection(_ c: NSXPCConnection) {
        lock.lock()
        let current = connection === c
        if current { connection = nil }
        let notify = onConnectionLost
        lock.unlock()
        if current { notify?() }
    }

    private func invalidate() {
        lock.lock(); let c = connection; connection = nil; lock.unlock()
        c?.invalidate()
    }
}
