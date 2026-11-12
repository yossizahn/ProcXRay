import Foundation

/// One syscall trace in the helper, on a connection of its own: when this object goes away (or `close()`
/// is called) the connection ends and the helper stops ktrace, whatever state the app is in.
final class HelperTraceSession: @unchecked Sendable {
    private let connection: NSXPCConnection

    init() {
        let c = NSXPCConnection(machServiceName: HelperConfig.machService, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        c.setCodeSigningRequirement(HelperConfig.peerRequirement)
        c.resume()
        connection = c
    }

    deinit { connection.invalidate() }

    /// nil when the trace started, else why not.
    func start(pid: Int32) -> String? {
        let r: String?? = call(timeout: 10) { p, done in p.traceStart(pid: pid) { done($0) } }
        return r ?? "The helper did not answer."
    }

    /// nil when the helper can't be reached any more.
    func read() -> (Data, Bool, String)? {
        call(timeout: 10) { p, done in p.traceRead { d, r, n in done((d, r, n)) } }
    }

    func stop() {
        _ = call(timeout: 5) { p, done in p.traceStop { done(()) } }
    }

    func close() { connection.invalidate() }

    /// nil when no reply came (connection error or timeout).
    private func call<T>(timeout: Double, _ body: (HelperProtocol, @escaping (T) -> Void) -> Void) -> T? {
        let lock = NSLock()
        var out: T?
        let sem = DispatchSemaphore(value: 0)
        guard let p = connection.remoteObjectProxyWithErrorHandler({ _ in sem.signal() }) as? HelperProtocol else { return nil }
        body(p) { v in lock.lock(); out = v; lock.unlock(); sem.signal() }
        _ = sem.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }
        return out
    }
}
