import Foundation

/// Per-process network throughput from NetworkStatistics.framework, the private framework nettop is built on.
/// One long-lived manager hears of every TCP and UDP socket on the Mac. As root it hears of every user's, and of
/// user-space (Network.framework, QUIC) flows; otherwise only of the caller's own kernel sockets. Each query
/// reports every socket's cumulative counts (~6 ms for ~130 sockets), and a socket that closes reports its final
/// counts as it goes, so unlike consecutive nettop runs this counts connections that open and close between two
/// readings. It also keeps each process's total: every byte of every socket it has seen the process use, over
/// that socket's whole life. A process that started after the reader is fully covered; for an older one the
/// total misses sockets it closed before the reader started, so it is a lower bound (`since`).
/// Signatures are taken from nettop's own calls (`dyld_info -imports /usr/bin/nettop`, `otool -tV`).
final class NativeNetStats: @unchecked Sendable {
    typealias Rates = [pid_t: NetSampler.Rate]
    private typealias Ref = OpaquePointer
    private typealias AddedBlock = @convention(block) (Ref?, UnsafeMutableRawPointer?) -> Void
    private typealias DictBlock = @convention(block) (CFDictionary?) -> Void
    private typealias VoidBlock = @convention(block) () -> Void

    private struct API {
        let create: @convention(c) (CFAllocator?, DispatchQueue, AddedBlock) -> Ref?
        let destroy: @convention(c) (Ref) -> Void
        /// (manager, interface filter, events): filter 0 takes every interface, loopback included, as nettop does.
        let addTCP: @convention(c) (Ref, UInt64, UInt64) -> Int32
        let addUDP: @convention(c) (Ref, UInt64, UInt64) -> Int32
        /// Asks every source for its counts and owner (the counts of plain NStatManagerQueryAllSources carry pid 0);
        /// the block runs once they have all answered.
        let query: @convention(c) (Ref, VoidBlock?) -> Int32
        let setCounts: @convention(c) (Ref, DictBlock) -> Void
        let setRemoved: @convention(c) (Ref, VoidBlock) -> Void
        let keyPID: CFString, keyUPID: CFString, keyRx: CFString, keyTx: CFString
    }

    private static let api: API? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics", RTLD_NOW)
        else { return nil }
        func fn<T>(_ name: String, _: T.Type) -> T? { dlsym(h, name).map { unsafeBitCast($0, to: T.self) } }
        func key(_ name: String) -> CFString? { dlsym(h, name).map { $0.load(as: Unmanaged<CFString>.self).takeUnretainedValue() } }
        guard let create = fn("NStatManagerCreate", (@convention(c) (CFAllocator?, DispatchQueue, AddedBlock) -> Ref?).self),
              let destroy = fn("NStatManagerDestroy", (@convention(c) (Ref) -> Void).self),
              let addTCP = fn("NStatManagerAddAllTCPWithFilter", (@convention(c) (Ref, UInt64, UInt64) -> Int32).self),
              let addUDP = fn("NStatManagerAddAllUDPWithFilter", (@convention(c) (Ref, UInt64, UInt64) -> Int32).self),
              let query = fn("NStatManagerQueryAllSourcesUpdate", (@convention(c) (Ref, VoidBlock?) -> Int32).self),
              let setCounts = fn("NStatSourceSetCountsBlock", (@convention(c) (Ref, DictBlock) -> Void).self),
              let setRemoved = fn("NStatSourceSetRemovedBlock", (@convention(c) (Ref, VoidBlock) -> Void).self),
              let pid = key("kNStatSrcKeyPID"), let upid = key("kNStatSrcKeyUPID"), let rx = key("kNStatSrcKeyRxBytes"), let tx = key("kNStatSrcKeyTxBytes")
        else { return nil }
        return API(create: create, destroy: destroy, addTCP: addTCP, addUDP: addUDP, query: query, setCounts: setCounts,
                   setRemoved: setRemoved, keyPID: pid, keyUPID: upid, keyRx: rx, keyTx: tx)
    }()

    static var available: Bool { api != nil }

    private let api: API
    private let q = DispatchQueue(label: "procxray.nstat", qos: .utility)
    private var manager: Ref?
    private var timer: DispatchSourceTimer?
    private let onRates: @Sendable (Rates) -> Void
    // All on q.
    private var sources: [Ref: (rx: UInt64, tx: UInt64)] = [:]
    private var pending: [pid_t: (rx: UInt64, tx: UInt64)] = [:]
    /// Per pid, the process's unique id (a reused pid gets a new one, and starts again from zero) and its bytes.
    private var totals: [pid_t: (upid: Int64, rx: UInt64, tx: UInt64)] = [:]
    private var ticks = 0
    /// When the reader started: totals of processes started before it are lower bounds.
    let since = Date()
    /// Set once the first query has answered: counts seen before it are the baseline of sockets that were
    /// already open; a socket first seen after it opened since, and all of its bytes count.
    private var primed = false
    private var lastAt: UInt64 = 0

    /// Starts reading; `onRates` gets, once per `interval` from the second query on, the bytes per second of
    /// every process with a socket seen (0 for one that moved none) and its total. nil when the framework or one of its symbols is missing.
    init?(interval: Double = 2, onRates: @escaping @Sendable (Rates) -> Void) {
        guard let api = Self.api else { return nil }
        self.api = api
        self.onRates = onRates
        let ok: Bool = q.sync {
            // Blocks go through a typed local: passed inline to a C function, Swift treats them as non-escaping.
            let onAdded: AddedBlock = { [weak self] src, _ in if let src { self?.added(src) } }
            guard let m = api.create(kCFAllocatorDefault, q, onAdded) else { return false }
            manager = m
            _ = api.addTCP(m, 0, 0)
            _ = api.addUDP(m, 0, 0)
            let t = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(Int(interval * 200)))
            self.interval = interval
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
            return true
        }
        if !ok { return nil }
    }

    /// Reads every `seconds` from now on. Nothing is lost at a slower pace: counts are cumulative, and a socket
    /// that closes reports its last ones.
    func setInterval(_ seconds: Double) {
        q.async { [self] in
            guard let t = timer, seconds != interval else { return }
            interval = seconds
            t.schedule(deadline: .now() + seconds, repeating: seconds, leeway: .milliseconds(Int(seconds * 200)))
        }
    }
    private var interval: Double = 2

    func stop() {
        q.async { [self] in
            timer?.cancel(); timer = nil
            if let m = manager { api.destroy(m) }
            manager = nil
            sources = [:]; pending = [:]; totals = [:]
        }
    }

    private func added(_ src: Ref) {
        let onCounts: DictBlock = { [weak self] d in if let d { self?.counts(src, d) } }
        let onRemoved: VoidBlock = { [weak self] in self?.sources[src] = nil }
        api.setCounts(src, onCounts)
        api.setRemoved(src, onRemoved)
    }

    private func value(_ d: CFDictionary, _ key: CFString) -> Int64? {
        guard let v = CFDictionaryGetValue(d, Unmanaged.passUnretained(key).toOpaque()) else { return nil }
        let n = unsafeBitCast(v, to: CFNumber.self)
        guard CFGetTypeID(n) == CFNumberGetTypeID() else { return nil }
        var out: Int64 = 0
        return CFNumberGetValue(n, .sInt64Type, &out) ? out : nil
    }

    private func counts(_ src: Ref, _ d: CFDictionary) {
        guard let rawPID = value(d, api.keyPID), let rx = value(d, api.keyRx).map({ UInt64(max(0, $0)) }),
              let tx = value(d, api.keyTx).map({ UInt64(max(0, $0)) }) else { return }
        let pid = pid_t(truncatingIfNeeded: rawPID), upid = value(d, api.keyUPID) ?? -1
        let seen = sources[src]
        sources[src] = (rx, tx)
        // The total takes a new socket's whole count; the rate only what moved since it was last read.
        let base = seen ?? (0, 0)
        let tRx = rx > base.rx ? rx - base.rx : 0, tTx = tx > base.tx ? tx - base.tx : 0
        var t = totals[pid].flatMap { $0.upid == upid ? $0 : nil } ?? (upid: upid, rx: 0, tx: 0)
        t.rx += tRx; t.tx += tTx
        totals[pid] = t
        // Before the first query answers, a socket's count is what it moved before the reader started.
        guard seen != nil || primed, tRx > 0 || tTx > 0 else { return }
        let p = pending[pid, default: (0, 0)]
        pending[pid] = (p.rx + tRx, p.tx + tTx)
    }

    private func tick() {
        guard let m = manager else { return }
        let done: VoidBlock = { [weak self] in self?.answered() }
        _ = api.query(m, done)
    }

    private func answered() {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if primed, now > lastAt {
            let secs = Double(now - lastAt) / 1e9
            var out: Rates = [:]
            for (pid, t) in totals {
                let p = pending[pid] ?? (0, 0)
                out[pid] = NetSampler.Rate(inPerSec: Double(p.rx) / secs, outPerSec: Double(p.tx) / secs, inTotal: t.rx, outTotal: t.tx)
            }
            onRates(out)
        }
        // Every minute or so, forget the totals of processes that have exited.
        ticks += 1
        if ticks % 30 == 0 { totals = totals.filter { kill($0.key, 0) == 0 || errno != ESRCH } }
        primed = true
        pending = [:]
        lastAt = now
    }
}
