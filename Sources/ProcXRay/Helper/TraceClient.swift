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
    func start(pid: Int32, stacks: Bool = false) -> Result<SyscallTraceConfig.Format, TraceStartError> {
        guard let (err, f) = call(timeout: 10, { p, done in p.traceStart(pid: pid, stacks: stacks) { done(($0, $1)) } }) else {
            return .failure(TraceStartError(message: "The helper did not answer."))
        }
        if let err { return .failure(TraceStartError(message: err)) }
        guard let format = SyscallTraceConfig.Format(rawValue: f) else {
            return .failure(TraceStartError(message: "The helper sent trace format \(f), which this app doesn't read: quit and reopen the app."))
        }
        return .success(format)
    }

    /// nil when the helper can't be reached any more.
    /// (records, still running, notes, regions behind new stack frames).
    func read() -> (Data, Bool, String, [StackRegion])? {
        call(timeout: 10) { p, done in
            p.traceRead { d, r, n, g in done((d, r, n, g.isEmpty ? [] : (try? JSONDecoder().decode([StackRegion].self, from: g)) ?? [])) }
        }
    }

    /// What the traced process's descriptors are now; empty when the helper can't say.
    func describeFds(_ fds: Set<Int32>) -> [Int32: String] {
        guard !fds.isEmpty, let req = try? JSONEncoder().encode(Array(fds)),
              let d: Data = call(timeout: 5, { p, done in p.traceDescribeFds(req) { done($0) } }),
              let m = try? JSONDecoder().decode([String: String].self, from: d) else { return [:] }
        return Dictionary(uniqueKeysWithValues: m.compactMap { k, v in Int32(k).map { ($0, v) } })
    }

    /// The process of each thread (HelperProtocol.traceThreadOwners); empty when the helper can't say.
    func threadOwners(_ tids: Set<UInt64>) -> [UInt64: Int32] {
        guard !tids.isEmpty, let req = try? JSONEncoder().encode(Array(tids)),
              let d: Data = call(timeout: 5, { p, done in p.traceThreadOwners(req) { done($0) } }),
              let m = try? JSONDecoder().decode([String: Int32].self, from: d) else { return [:] }
        return Dictionary(uniqueKeysWithValues: m.compactMap { k, v in UInt64(k).map { ($0, v) } })
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
