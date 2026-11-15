import Darwin
import Foundation

/// What the helper's trace calls need from a running trace, whichever way it reads the kernel.
protocol TraceSource: AnyObject, Sendable {
    /// Data written since the last call (at most `max` bytes, whole records), whether the trace still runs, and
    /// notes since the last call.
    func read(max: Int) -> (Data, Bool, String)
    func stop()
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
    static let lostEvents: UInt32 = 0x0702_0008   // TRACE_LOST_EVENTS in /usr/share/misc/trace.codes

    // <sys/kdebug_private.h>; not in the SDK.
    private static let KERN_KDENABLE: Int32 = 3, KERN_KDSETBUF: Int32 = 4, KERN_KDSETUP: Int32 = 6,
                       KERN_KDREMOVE: Int32 = 7, KERN_KDREADTR: Int32 = 10, KERN_KDPIDTR: Int32 = 11,
                       KERN_KDSET_TYPEFILTER: Int32 = 22, KERN_KDBUFWAIT: Int32 = 23
    private static let KDBG_TYPENONE: UInt32 = 0x80
    private static let KDEBUG_ENABLE_TRACE: Int32 = 1
    private struct RegType { var type: UInt32; var value1: UInt32; var value2: UInt32; var value3: UInt32; var value4: UInt32 }

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

    private init(maxPending: Int, start: UInt64, maxSeconds: Int) {
        self.maxPending = maxPending
        self.start = start
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        numer = UInt64(tb.numer); denom = UInt64(tb.denom)
        deadline = start + UInt64(maxSeconds) * 1_000_000_000 * denom / numer
    }

    /// Configures kdebug for `pid` and starts reading. Needs root.
    static func start(pid: Int32, maxPending: Int, maxSeconds: Int) -> Result<KdebugTrace, StartError> {
        guard pid > 0 else { return .failure(.failed("bad pid \(pid)")) }
        // Only clears a session we may configure: someone else's gives EBUSY here and is left alone.
        _ = op(KERN_KDREMOVE)
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
        for cs in SyscallTraceConfig.classSubclasses { filter[Int(cs) / 8] |= 1 << (cs % 8) }
        if let e = filter.withUnsafeMutableBytes({ input(KERN_KDSET_TYPEFILTER, $0.baseAddress!, $0.count) }) { return fail("typefilter", e) }
        var reg = RegType(type: KDBG_TYPENONE, value1: UInt32(bitPattern: pid), value2: 1, value3: 0, value4: 0)
        if let e = withUnsafeMutableBytes(of: &reg, { input(KERN_KDPIDTR, $0.baseAddress!, $0.count) }) {
            return fail(e == ESRCH ? "\(pid)" : "pid filter", e)
        }
        let t = KdebugTrace(maxPending: maxPending, start: mach_absolute_time(), maxSeconds: maxSeconds)
        if let e = op(KERN_KDENABLE, KDEBUG_ENABLE_TRACE) { return fail("KDENABLE", e) }
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

    /// Rewrites timestamps and queues the records.
    private func take(_ buf: UnsafeMutableRawPointer, _ n: Int) {
        let recs = buf.bindMemory(to: Record.self, capacity: n)
        var lost = 0
        for i in 0..<n {
            let ts = recs[i].timestamp
            recs[i].timestamp = ts > start ? (ts - start) * numer / denom : 0
            if recs[i].debugid == Self.lostEvents { lost += 1 }
        }
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

    private static func cleanUp() {
        _ = op(KERN_KDENABLE, 0)
        _ = op(KERN_KDREMOVE)
    }

    /// "in use by ktrace[61040]", from the kernel's own record of the owner.
    private static func busyText() -> String {
        func int(_ n: String) -> Int32? { var v: Int32 = 0; var l = 4; return sysctlbyname(n, &v, &l, nil, 0) == 0 ? v : nil }
        var name = [CChar](repeating: 0, count: 64); var l = name.count
        let who = sysctlbyname("ktrace.configured_by", &name, &l, nil, 0) == 0 ? String(cString: name) : "another tool"
        let pid = int("ktrace.owning_pid").map { $0 > 0 ? "[\($0)]" : "" } ?? ""
        return "The kernel trace facility is in use by \(who)\(pid). It allows one trace at a time: stop the other one (another trace here, Instruments or fs_usage) and trace again."
    }

    private static func errText(_ e: Int32) -> String { String(cString: strerror(e)) }

    /// An operation with an optional value in the name (KDSETBUF's size, KDENABLE's mode). nil = success, else errno.
    private static func op(_ o: Int32, _ value: Int32? = nil) -> Int32? {
        var z = 0
        return call([CTL_KERN, KERN_KDEBUG, o] + (value.map { [$0] } ?? []), nil, &z)
    }

    /// kdebug takes its input through oldp (sysctl's newp is refused with EPERM).
    private static func input(_ o: Int32, _ p: UnsafeMutableRawPointer, _ size: Int) -> Int32? {
        var l = size
        return call([CTL_KERN, KERN_KDEBUG, o], p, &l)
    }

    private static func call(_ mib: [Int32], _ old: UnsafeMutableRawPointer?, _ len: inout Int) -> Int32? {
        var m = mib
        return sysctl(&m, u_int(m.count), old, &len, nil, 0) == 0 ? nil : errno
    }
}
