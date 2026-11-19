import Darwin
import Foundation

/// What the helper's trace calls need from a running trace, whichever way it reads the kernel.
protocol TraceSource: AnyObject, Sendable {
    /// Data written since the last call (at most `max` bytes, whole records), whether the trace still runs, and
    /// notes since the last call.
    func read(max: Int) -> (Data, Bool, String)
    func stop()
    /// Images behind stack frames found since the last call (StackRegion JSON); empty without stacks.
    func newRegions() -> Data
}

extension TraceSource {
    func newRegions() -> Data { Data() }
}

/// A mapped file in the traced process, for symbolicating stack frames: [start, size, path]. `path` is empty
/// for memory with no file behind it (JIT code, a region the kernel wouldn't describe).
struct StackRegion: Codable, Sendable {
    var start: UInt64
    var size: UInt64
    var path: String
}

/// Syscall trace read straight from the kernel's kdebug buffer (sysctl CTL_KERN/KERN_KDEBUG), the facility
/// `ktrace trace` reads. Same filter as SyscallTraceConfig, with the pid filter in the kernel.
///
/// Why not ktrace (measured in a 4-CPU macOS 27.2 VM): ktrace formats each event as ~250 bytes of JSON and tops
/// out near 410k events/s, a whole core; above that it drops events without saying so (41% kept at 330k
/// syscalls/s, 47% with a 1 GB buffer). This reader kept all 36.7M events of 2.4M syscalls/s for 0.8 s of CPU,
/// and starts in ~0.25 s instead of ~0.8 s. Needs root only, not SIP off: checked on a Mac with SIP on as well.
///
/// Output is `Record`s, 64 bytes each: the kernel's kd_buf with the timestamp rewritten to nanoseconds since
/// the trace started. The kernel marks a gap (its buffer wrapped before we read it) with a TRACE_LOST_EVENTS
/// record where the gap was; those are passed on and counted in a note.
///
/// Stacks (opt-in): kperf, the kernel sampler behind Instruments, samples the user stack at each BSD syscall and
/// Mach trap entry (a kdebug trigger). The stack is taken on the way back to user space, so its PERF_STK events
/// follow the call's return on the same thread. kperf only samples threads that pass the kdebug pid filter: a
/// busy untraced process ran at the same rate with and without it. Measured: ~7 events per call instead of ~3;
/// the traced process ran 12% slower at 270k syscalls/s, 36% at 1.5M. Works with SIP on (checked on the host).
/// kperf has to be reset on the way out, or the kernel keeps the session in the foreground under a dead owner
/// and background tracing (tailspind) can't take it back.
///
/// One trace system-wide: while another tool holds kdebug (ktrace, Instruments, fs_usage) setup fails with
/// EBUSY. Background tracing (tailspind) gives way and takes it back after `cleanUp`. If the helper dies
/// mid-trace, the next configure takes the facility over from the dead owner (checked with kill -9).
final class KdebugTrace: TraceSource, @unchecked Sendable {
    enum StartError: Error {
        /// No point trying ktrace: another tool owns kdebug (the text says which), or there is no such process.
        case refused(String)
        /// Anything else: the caller can fall back to ktrace.
        case failed(String)
    }

    /// The kernel's kd_buf on LP64, as written to `read`'s Data.
    struct Record {
        var timestamp: UInt64
        var arg1: UInt64, arg2: UInt64, arg3: UInt64, arg4: UInt64
        /// The thread id.
        var arg5: UInt64
        var debugid: UInt32
        var cpuid: UInt32
        var unused: UInt64
    }
    static let recordSize = 64
    /// Threads seen making a call: the traced process's. Only the pump thread touches it.
    private var ownThreads: Set<UInt64> = []
    static let lostEvents: UInt32 = 0x0702_0008   // TRACE_LOST_EVENTS in /usr/share/misc/trace.codes
    /// PERF_STK_UData: four frames of a user stack.
    static let stackData: UInt32 = 0x2502_0010
    /// DBG_DYLD_TIMING_STATIC_INITIALIZER | DBG_FUNC_START.
    static let initializerStart: UInt32 = 0x1f07_0001

    // <sys/kdebug_private.h>; not in the SDK.
    static let KERN_KDENABLE: Int32 = 3, KERN_KDSETBUF: Int32 = 4, KERN_KDSETUP: Int32 = 6,
                       KERN_KDREMOVE: Int32 = 7, KERN_KDREADTR: Int32 = 10, KERN_KDPIDTR: Int32 = 11,
                       KERN_KDSET_TYPEFILTER: Int32 = 22, KERN_KDBUFWAIT: Int32 = 23
    static let KDBG_TYPENONE: UInt32 = 0x80
    static let KDEBUG_ENABLE_TRACE: Int32 = 1
    struct RegType { var type: UInt32; var value1: UInt32; var value2: UInt32; var value3: UInt32; var value4: UInt32 }

    /// Kernel buffer, in events (64 bytes each: 16 MB). The reader is woken at half full, not on a timer.
    /// Measured: no kernel loss at 2.4M syscalls/s in the 4-CPU VM, and up to 1.1M (not at 1.7M) on the SIP-on
    /// host; on both, the app's decoding falls behind first (~1.7M and ~2.3M events/s), and those drops are said.
    static let kernelEvents = 256 << 10
    /// How long the reader waits for the buffer to fill before reading anyway.
    private static let waitMs = 50

    private let lock = NSLock()
    /// Records waiting for the app, as the reads from the kernel came. A queue of chunks, so neither side moves
    /// the whole backlog while holding the lock (one Data trimmed from the front stalled the kernel reader into
    /// losing events at 2.8M syscalls/s).
    private var chunks: [Data] = []
    private var headOffset = 0
    private var pendingBytes = 0
    private var notes = ""
    private var running = true
    private var stopRequested = false
    /// Events dropped because the app didn't read them in time, in all.
    private var droppedRecords = 0
    private var lostMarks = 0
    private let maxPending: Int
    private let deadline: UInt64
    private let start: UInt64
    private let numer: UInt64, denom: UInt64
    private let pid: Int32
    private let stacks: Bool
    /// Regions looked up so far (sorted by start), and the ones the app hasn't been sent yet.
    private var regions: [StackRegion] = []
    private var unsent: [StackRegion] = []
    private let cache = SharedCache.range

    private init(pid: Int32, stacks: Bool, maxPending: Int, start: UInt64, maxSeconds: Int) {
        self.pid = pid
        self.stacks = stacks
        self.maxPending = maxPending
        self.start = start
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        numer = UInt64(tb.numer); denom = UInt64(tb.denom)
        deadline = start + UInt64(maxSeconds) * 1_000_000_000 * denom / numer
    }

    /// Configures kdebug for `pid` and starts reading. Needs root.
    static func start(pid: Int32, stacks: Bool = false, maxPending: Int, maxSeconds: Int) -> Result<KdebugTrace, StartError> {
        guard pid > 0 else { return .failure(.failed("bad pid \(pid)")) }
        // Only clears a session we may configure: someone else's gives EBUSY here and is left alone. A kperf
        // configuration left behind (a tracer that died) goes with it.
        if op(KERN_KDREMOVE) == nil { Kperf.reset() }
        if let e = op(KERN_KDSETBUF, Int32(kernelEvents)) { return .failure(e == EBUSY ? .refused(busyText()) : .failed("KDSETBUF: \(errText(e))")) }
        func fail(_ what: String, _ e: Int32) -> Result<KdebugTrace, StartError> {
            _ = op(KERN_KDREMOVE)
            if e == EBUSY { return .failure(.refused(busyText())) }
            if e == ESRCH { return .failure(.refused("No process \(what).")) }
            return .failure(.failed("\(what): \(errText(e))"))
        }
        if let e = op(KERN_KDSETUP) { return fail("KDSETUP", e) }
        // One bit per class<<8|subclass.
        var filter = [UInt8](repeating: 0, count: 8192)
        for cs in SyscallTraceConfig.classSubclasses + (stacks ? [Kperf.stackSubclass] : []) { filter[Int(cs) / 8] |= 1 << (cs % 8) }
        if let e = filter.withUnsafeMutableBytes({ input(KERN_KDSET_TYPEFILTER, $0.baseAddress!, $0.count) }) { return fail("typefilter", e) }
        var reg = RegType(type: KDBG_TYPENONE, value1: UInt32(bitPattern: pid), value2: 1, value3: 0, value4: 0)
        if let e = withUnsafeMutableBytes(of: &reg, { input(KERN_KDPIDTR, $0.baseAddress!, $0.count) }) {
            return fail(e == ESRCH ? "\(pid)" : "pid filter", e)
        }
        var stackNote: String?
        if stacks, let why = Kperf.configure() {
            Kperf.reset()
            stackNote = "No stacks: kperf refused (\(why)).\n"
        }
        let t = KdebugTrace(pid: pid, stacks: stacks && stackNote == nil, maxPending: maxPending, start: mach_absolute_time(), maxSeconds: maxSeconds)
        if let stackNote { t.notes = stackNote }
        if let e = op(KERN_KDENABLE, KDEBUG_ENABLE_TRACE) { Kperf.reset(); return fail("KDENABLE", e) }
        Thread.detachNewThread { t.pump() }
        return .success(t)
    }

    func read(max: Int) -> (Data, Bool, String) {
        lock.lock(); defer { lock.unlock() }
        let budget = min(pendingBytes, max) / Self.recordSize * Self.recordSize
        var out = Data(capacity: budget)
        while out.count < budget, let first = chunks.first {
            let take = min(first.count - headOffset, budget - out.count)
            out.append(first[headOffset..<headOffset + take])
            headOffset += take
            if headOffset == first.count { chunks.removeFirst(); headOffset = 0 }
        }
        pendingBytes -= out.count
        let text = notes
        notes = ""
        return (out, running || pendingBytes > 0, text)
    }

    func stop() {
        lock.lock(); stopRequested = true; lock.unlock()
    }

    func newRegions() -> Data {
        lock.lock(); let r = unsent; unsent = []; lock.unlock()
        return r.isEmpty ? Data() : ((try? JSONEncoder().encode(r)) ?? Data())
    }

    private func pump() {
        let cap = Self.kernelEvents
        let buf = UnsafeMutableRawPointer.allocate(byteCount: cap * Self.recordSize, alignment: 8)
        defer { buf.deallocate() }
        var failure: String?
        var last = false
        while true {
            lock.lock(); let stopping = stopRequested; lock.unlock()
            if stopping || mach_absolute_time() >= deadline {
                // Stop logging, then drain what is left.
                _ = Self.op(Self.KERN_KDENABLE, 0)
                last = true
            } else {
                var ms = Self.waitMs
                _ = Self.call([CTL_KERN, KERN_KDEBUG, Self.KERN_KDBUFWAIT], nil, &ms)
            }
            var n = cap   // in and out: a count of events, not bytes
            if let e = Self.call([CTL_KERN, KERN_KDEBUG, Self.KERN_KDREADTR], buf, &n) {
                failure = "Reading the kernel trace failed: \(Self.errText(e))."
                break
            }
            if n > 0 { take(buf, n) }
            if last { break }
        }
        Self.cleanUp()
        lock.lock()
        if let failure { notes += failure + "\n" }
        if !stopRequested && failure == nil { notes += "The trace reached its \(SyscallTraceConfig.maxSeconds / 60)-minute limit.\n" }
        if droppedRecords > 0 { notes += "\(droppedRecords) trace events were dropped in all because the app fell behind.\n" }
        running = false
        lock.unlock()
    }

    /// Rewrites timestamps, drops other processes' scheduler events and queues the records.
    ///
    /// The kernel's pid filter doesn't hold back scheduler events (DBG_MACH_SCHED) or thread names: a 6 s trace of
    /// Finder got scheduler events from 354 threads, 145k events for 1,061 calls. Kept: those of threads that made a call, which are the traced
    /// process's (syscall events do pass the filter) and the only ones SyscallDecoder uses.
    private func take(_ buf: UnsafeMutableRawPointer, _ count: Int) {
        let recs = buf.bindMemory(to: Record.self, capacity: count)
        var lost = 0
        var n = 0
        for i in 0..<count {
            let id = recs[i].debugid
            // Thread names (TRACE_STRING_THREADNAME, 0x0701) leak from other processes the same way.
            if id >> 16 == 0x0140 || id >> 16 == 0x0701 {
                guard ownThreads.contains(recs[i].arg5) else { continue }
            } else if id >> 16 == 0x010c || id >> 16 == 0x040c {
                ownThreads.insert(recs[i].arg5)
            }
            if n != i { recs[n] = recs[i] }
            let ts = recs[n].timestamp
            recs[n].timestamp = ts > start ? (ts - start) * numer / denom : 0
            if id == Self.lostEvents { lost += 1 }
            if stacks && id & ~3 == Self.stackData {
                for a in [recs[n].arg1, recs[n].arg2, recs[n].arg3, recs[n].arg4] { noteFrame(a) }
            }
            // A static initializer's start: [seq, image header, function]. Its image, for naming the function.
            if id == Self.initializerStart { noteFrame(recs[n].arg3) }
            n += 1
        }
        guard n > 0 else { return }
        let bytes = n * Self.recordSize
        lock.lock()
        let full = pendingBytes + bytes > maxPending
        lock.unlock()
        // Copied outside the lock; nothing to copy when it would be dropped anyway.
        let copy = full ? Data() : Data(bytes: buf, count: bytes)
        lock.lock()
        if lost > 0 {
            if lostMarks == 0 { notes += "The kernel's trace buffer overflowed: some calls are missing, so calls in flight then show without arguments or results.\n" }
            lostMarks += lost
        }
        if pendingBytes + bytes > maxPending {
            // Said once here (notes are shown deduplicated), with the total when the trace ends.
            if droppedRecords == 0 { notes += "The app fell behind the trace: events are being dropped.\n" }
            droppedRecords += n
        } else {
            chunks.append(copy)
            pendingBytes += bytes
        }
        lock.unlock()
    }

    /// Looks up the image behind a frame outside the shared cache (which the app resolves in its own process)
    /// the first time an address in it turns up. Only the pump thread touches `regions` writes.
    private func noteFrame(_ a: UInt64) {
        guard a >= 0x1000, !cache.contains(a) else { return }
        var lo = 0, hi = regions.count
        while lo < hi { let m = (lo + hi) / 2; if regions[m].start + regions[m].size <= a { lo = m + 1 } else { hi = m } }
        if lo < regions.count, regions[lo].start <= a { return }
        var info = proc_regionwithpathinfo()
        let r: StackRegion
        if proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, a, &info, Int32(MemoryLayout.size(ofValue: info))) == Int32(MemoryLayout.size(ofValue: info)),
           info.prp_prinfo.pri_address <= a, a < info.prp_prinfo.pri_address + info.prp_prinfo.pri_size {
            let path = withUnsafeBytes(of: info.prp_vip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            r = StackRegion(start: info.prp_prinfo.pri_address, size: info.prp_prinfo.pri_size, path: path)
        } else {
            // Not described (the process may be gone): one page, so the address isn't looked up again.
            r = StackRegion(start: a & ~0x3fff, size: 0x4000, path: "")
        }
        regions.insert(r, at: lo)
        lock.lock(); unsent.append(r); lock.unlock()
    }

    private static func cleanUp() {
        Kperf.reset()
        _ = op(KERN_KDENABLE, 0)
        _ = op(KERN_KDREMOVE)
    }

    /// "in use by ktrace[61040]", from the kernel's own record of the owner.
    static func busyText() -> String {
        func int(_ n: String) -> Int32? { var v: Int32 = 0; var l = 4; return sysctlbyname(n, &v, &l, nil, 0) == 0 ? v : nil }
        var name = [CChar](repeating: 0, count: 64); var l = name.count
        let who = sysctlbyname("ktrace.configured_by", &name, &l, nil, 0) == 0 ? String(cString: name) : "another tool"
        let pid = int("ktrace.owning_pid").map { $0 > 0 ? "[\($0)]" : "" } ?? ""
        return "The kernel trace facility is in use by \(who)\(pid). It allows one trace at a time: stop the other one (another trace here, Instruments or fs_usage) and trace again."
    }

    static func errText(_ e: Int32) -> String { String(cString: strerror(e)) }

    /// An operation with an optional value in the name (KDSETBUF's size, KDENABLE's mode). nil = success, else errno.
    static func op(_ o: Int32, _ value: Int32? = nil) -> Int32? {
        var z = 0
        return call([CTL_KERN, KERN_KDEBUG, o] + (value.map { [$0] } ?? []), nil, &z)
    }

    /// kdebug takes its input through oldp (sysctl's newp is refused with EPERM).
    static func input(_ o: Int32, _ p: UnsafeMutableRawPointer, _ size: Int) -> Int32? {
        var l = size
        return call([CTL_KERN, KERN_KDEBUG, o], p, &l)
    }

    static func call(_ mib: [Int32], _ old: UnsafeMutableRawPointer?, _ len: inout Int) -> Int32? {
        var m = mib
        return sysctl(&m, u_int(m.count), old, &len, nil, 0) == 0 ? nil : errno
    }
}

/// kperf's sysctls (xnu bsd/kern/kern_kpc.c, osfmk/kperf/kperfbsd.c; not in the SDK). Unlike kdebug's, they take
/// their input through newp.
enum Kperf {
    /// PERF_STK: the stack samples' kdebug events.
    static let stackSubclass: UInt16 = 0x2502
    private static let samplerUserStack: UInt64 = 1 << 3

    /// One action sampling the user stack, fired by every BSD syscall and Mach trap entry. nil = done, else why not.
    static func configure() -> String? {
        var count: UInt32 = 1
        if let e = set("kperf.action.count", &count) { return e }
        var samplers: (UInt64, UInt64) = (1, samplerUserStack)   // action 1
        if let e = set("kperf.action.samplers", &samplers) { return e }
        var action: Int32 = 1
        if let e = set("kperf.kdebug.action", &action) { return e }
        // Filter types, a nibble each from the low end: 3 = class, subclass and function. Function 1 = entry.
        var filter: (UInt64, UInt64, UInt32, UInt32) = (0x33, 0, 0x040c_0001, 0x010c_0001)
        if let e = set("kperf.kdebug.filter", &filter) { return e }
        var on: Int32 = 1
        return set("kperf.sampling", &on)
    }

    /// Sampling off and every action and trigger cleared.
    static func reset() {
        var off: Int32 = 0
        _ = set("kperf.sampling", &off)
        var one: Int32 = 1
        _ = set("kperf.reset", &one)
    }

    private static func set<T: BitwiseCopyable>(_ name: String, _ v: inout T) -> String? {
        let r = withUnsafeMutableBytes(of: &v) { sysctlbyname(name, nil, nil, $0.baseAddress, $0.count) }
        return r == 0 ? nil : "\(name): \(String(cString: strerror(errno)))"
    }
}

/// The dyld shared cache's range in this process. Every process maps the same cache at the same address (checked:
/// dladdr here named another process's stack frames correctly), so frames inside it are resolved locally.
enum SharedCache {
    static let range: Range<UInt64> = {
        typealias Fn = @convention(c) (UnsafeMutablePointer<Int>) -> UnsafeRawPointer?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_dyld_get_shared_cache_range") else { return 0..<0 }
        var len = 0
        guard let p = unsafeBitCast(sym, to: Fn.self)(&len) else { return 0..<0 }
        let start = UInt64(UInt(bitPattern: p))
        return start..<start + UInt64(len)
    }()
}
