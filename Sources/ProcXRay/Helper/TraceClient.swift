import Foundation

/// One syscall trace in the helper, on a connection of its own: when this object goes away (or `close()`
/// is called) the connection ends and the helper stops ktrace, whatever state the app is in.
struct TraceStartError: Error { let message: String }

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

    /// The data format when the trace started, else why not.
    func start(pid: Int32) -> Result<SyscallTraceConfig.Format, TraceStartError> {
        guard let (err, f) = call(timeout: 10, { p, done in p.traceStart(pid: pid) { done(($0, $1)) } }) else {
            return .failure(TraceStartError(message: "The helper did not answer."))
        }
        if let err { return .failure(TraceStartError(message: err)) }
        guard let format = SyscallTraceConfig.Format(rawValue: f) else {
            return .failure(TraceStartError(message: "The helper sent trace format \(f), which this app doesn't read: quit and reopen the app."))
        }
        return .success(format)
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
