import Darwin
import Foundation

// Syscall trace: kdebug events, read by the helper (KdebugTrace, raw records) or from `ktrace trace --ndjson`
// (see SyscallTraceConfig), paired into strace-style records.
//
// What the events carry (checked against a real trace of Finder):
//   debugid: class << 24 | subclass << 16 | code << 2 | func. Syscalls are class 4 / subclass 0x0c (BSD) and
//            1 / 0x0c (Mach traps) with the syscall number as the code; func 1 = entry, 2 = return.
//   entry:   args = the first four syscall arguments (always four, whatever the call's arity).
//   return:  BSD args = [errno, rval0, rval1, pid]; errno is the kernel's, so -1 (ERESTART) and -2
//            (EJUSTRETURN: e.g. workq_kernreturn parking the thread) show up too.
//            Mach args[0] = the kern_return_t / mach_msg_return_t.
//   VFS_LOOKUP (3 / 0x01, code 0x24): the looked-up path as raw bytes, little-endian, packed into the args.
//            First event (func 1): args[0] is a vnode id, args[1...3] are path bytes; later events (func 0,
//            and the last with func 2) carry four words of path each. NUL-padded. It arrives on the
//            thread between the entry and return of the syscall doing the lookup.
//   Scheduler (1 / 0x40), logged on the thread doing the scheduling, so the pid filter keeps the traced process's:
//            MACH_MKRUNNABLE (code 0x6) args[0] = the thread made runnable; MACH_BLOCK (0xf), MACH_WAIT (0x10),
//            MACH_SCHED (0x0) and MACH_STKHANDOFF (0x2) = this thread gave up its CPU, args[1] = the thread that
//            got it (so the events of other processes' threads that hand a CPU to a traced one are kept too:
//            SyscallDecoder.switched; the helper marks whose each is, KdebugEvent.ours); the same thread there means it kept its CPU. The runs these give add up
//            to the kernel's own count of the process's CPU time (proc_pid_rusage over the same stretch) within
//            0.3% for WindowServer, Finder, logd and scripts that compute, sleep and connect (VM, 27.2). Checked on Finder against
//            lsmp (27.2): a message send that wakes a thread wakes one of the receiving process (60 of 60), and
//            a send-and-receive whose reply came without the thread blocking went to a kernel object (38 of 38;
//            every call to another process blocked). The kernel's per-message IPC events (MACH_IPC_kmsg_info,
//            which name the receiver) are only compiled into development kernels (checked in the 27.2 KDK).
//   Strings (7 / 0x01): TRACE_STRING_GLOBAL (code 0) gives a string an id for later events: first event (func 1)
//            args = [the owning event's debugid, the id, then text], more text in later events, the last has func 2;
//            the same id sent again empty releases it. TRACE_STRING_THREADNAME (code 4) and _PREV (code 5, its old
//            name, sent at a rename or exit) carry the event thread's name in all four args.
//   dyld (0x1f), from dyld's Tracing.h, each a start/end pair with args[0] a sequence number shared by both:
//            dlopen (0x08/0): [seq, path string id, mode] → [seq, handle]; dlclose (0x08/2): [seq, handle];
//            dlsym (0x08/3): [seq, handle, symbol string id] → [seq, address]; dladdr (0x08/4): [seq, address];
//            static initializer (0x07/0): [seq, image header, function]; launch (0x07/1, LAUNCH_EXECUTABLE):
//            [seq, main executable's header], ending when dyld calls main (a test program's first call came 73 µs
//            later); bootstrap (0x07/13, no pair) when dyld starts, twice when it restarts itself from the shared
//            cache. Only a trace from a program's first instruction (Launch and Trace) has these. Image loads (0x05/0 then 0x05/1, no pair):
//            [uuid, uuid, load address] then [_, path string id]. Checked with a test program in the VM (27.2).
//   MIG (0xff): ipc_kobject_server logs each message a kernel object handles, start and end, on the sender's
//            thread inside its mach_msg2_trap, with the routine's kobject filter index in the code bits (no args).
//            The index counts every kernel MIG routine in order; MIGRoutines reads the names in that order.

/// One syscall, paired.
struct SyscallRecord: Identifiable, Sendable, Hashable {
    enum State: Sendable, Hashable {
        case done
        /// Still in the kernel when the trace stopped (a blocking read, a parked thread).
        case inProgress
        /// Entered before the trace started: only its return was seen, so no arguments.
        case entryMissed
    }
    let id: Int
    /// Nanoseconds since the trace started.
    var start: UInt64?
    var end: UInt64?
    let thread: UInt64
    let mach: Bool
    let number: Int
    let name: String
    var args: [UInt64]?
    /// BSD: errno (0 = success). Mach: the kern_return.
    var error: Int64 = 0
    /// BSD: the kernel's two 32-bit return words. A 64-bit result (a pointer, an offset, an ssize_t) is split
    /// across them, low word first (checked: mmap's 0x1_0024_c000 came back as 0x24c000 and 1); pipe returns
    /// two descriptors in them.
    var ret: UInt64 = 0
    var ret1: UInt64 = 0
    var paths: [String] = []
    var state: State = .done
    /// The user stack at the call (traces with stacks): innermost first, the syscall stub's pc, then its caller.
    var stack: [UInt64] = []
    /// The first thread the call made runnable before it blocked (0: none seen): a message's receiver.
    var woke: UInt64 = 0
    /// Whether the thread gave up its CPU during the call; nil while the trace has shown no scheduler events.
    var blocked: Bool?
    /// The process `woke` belongs to (ThreadLabeler).
    var receiver: Int32?
    /// Time the thread was on a CPU between the call's entry and its return, from the scheduler's context
    /// switches; the rest of its duration it was off one (blocked, or waiting its turn). nil: not measured (no
    /// scheduler events, the entry missed, events lost during the call).
    var cpu: UInt64?
    /// A message a kernel object handled: the kernel routine's index (MIGRoutines), from the MIG trace events.
    var kernelRoutine: Int?
    /// `number` of a dyld call (dlopen, dlsym…, from dyld's trace events): no syscall has it.
    static let libraryCall = -1
    var isLibraryCall: Bool { number == Self.libraryCall }
    /// dyld's setup of a launched program and the moment main() starts: points in the launch, not calls.
    var isLaunchMarker: Bool { isLibraryCall && (name == "dyld setup" || name == "main()") }

    // Display text, built once (off the main thread) so the table only reads strings.
    /// The first frame outside libsystem_kernel (the syscall stubs), symbolicated; empty without a stack.
    var caller = ""
    /// The OS function the process's own code called that made this call ("IOServiceGetMatchingServices  (IOKit)"),
    /// and where in that code ("BetterDisplay + 0xa29068"): StackSymbols.entry. Empty without a stack, or when the
    /// call is a framework's own work.
    var api = ""
    var site = ""
    /// What set the call off, and the next frame of the process's code inside it: StackSymbols.trigger.
    var trigger = ""
    var triggerInner = ""
    /// Resolved resource for syscalls whose first argument is a descriptor.
    var firstFDLabel: String?
    /// One display text per argument shown ("…" alone when the entry, and so the arguments, wasn't seen).
    var argValues: [String] = []
    var argsText: String { argValues.joined(separator: ", ") }
    /// "fd: 3, cbuf: 0x…, nbyte: 21": names as xnu declares them, or as the decoded command defines them.
    var namedArgsText: String {
        let names = SyscallFormat.argNames(self)
        return argValues.enumerated().map { i, v in i < names.count && !names[i].isEmpty && args != nil ? names[i] + ": " + v : v }
            .joined(separator: ", ")
    }
    var resultText = ""
    var failed = false
    /// An error return that is the answer the caller asked for, not a failure: mkdir's EEXIST under "create if
    /// missing", readlink's EINVAL for "not a symlink", a timed wait running out. Not `failed`; shown muted.
    var expected = false

    var duration: UInt64? {
        guard let s = start, let e = end, e >= s else { return nil }
        return e - s
    }
    /// Sort keys for the table.
    var time: UInt64 { start ?? end ?? 0 }
    var durationKey: UInt64 { duration ?? 0 }
    var pathText: String { paths.joined(separator: "  ") }
}

/// One kdebug event: the fields this needs, from the helper's raw records or `ktrace --ndjson`.
struct KdebugEvent: Sendable {
    var ts: UInt64 = 0
    var eventname: String?
    var debugid: UInt32 = 0
    var arg: [UInt64] = []
    var thread: UInt64 = 0
    /// Context switches from the helper (KdebugTrace.take): 1 = the thread leaving the CPU is the traced process's,
    /// 2 = the thread taking it is. 0 from anything else, which doesn't say.
    var ours: UInt8 = 0

    var cls: UInt32 { debugid >> 24 }
    var subclass: UInt32 { (debugid >> 16) & 0xff }
    var code: Int { Int((debugid >> 2) & 0x3fff) }
    var fn: UInt32 { debugid & 3 }

    static let lostEvents: UInt32 = 0x0702_0008   // TRACE_LOST_EVENTS: the kernel lost events here
    static let stackHeader: UInt32 = 0x2502_0018  // PERF_STK_UHdr: flags, frame count
    static let stackData: UInt32 = 0x2502_0010    // PERF_STK_UData: four frames
    static let makeRunnable: UInt32 = 0x0140_0018 // MACH_MKRUNNABLE: args[0] = the thread
    static let contextSwitch: Set<UInt32> = [0x0140_0000, 0x0140_0008]   // SCHED, STKHANDOFF: args[1] = the thread coming on
    static let gaveUpCPU: Set<UInt32> = [0x0140_003c, 0x0140_0040, 0x0140_0000, 0x0140_0008]   // BLOCK, WAIT, SCHED, STKHANDOFF

    /// The helper's KdebugTrace.Record layout (the kernel's kd_buf, timestamp in ns since the trace started).
    /// Names come from trace.codes, as ktrace's do.
    static func decodeRaw(_ chunk: Data) -> [KdebugEvent] {
        let size = 64
        let names = KdebugNames.table
        var out: [KdebugEvent] = []
        out.reserveCapacity(chunk.count / size)
        chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var o = 0
            while o + size <= raw.count {
                let debugid = raw.loadUnaligned(fromByteOffset: o + 48, as: UInt32.self)
                out.append(KdebugEvent(ts: raw.loadUnaligned(fromByteOffset: o, as: UInt64.self),
                                       eventname: names[debugid & ~3],
                                       debugid: debugid,
                                       arg: [raw.loadUnaligned(fromByteOffset: o + 8, as: UInt64.self),
                                             raw.loadUnaligned(fromByteOffset: o + 16, as: UInt64.self),
                                             raw.loadUnaligned(fromByteOffset: o + 24, as: UInt64.self),
                                             raw.loadUnaligned(fromByteOffset: o + 32, as: UInt64.self)],
                                       thread: raw.loadUnaligned(fromByteOffset: o + 40, as: UInt64.self),
                                       ours: UInt8(truncatingIfNeeded: raw.loadUnaligned(fromByteOffset: o + 56, as: UInt64.self))))
                o += size
            }
        }
        return out
    }

    private struct JSON: Decodable {
        let timestampns: String
        let eventname: String?
        let debugid: UInt32
        let args: [String]
        let threadid: String
    }

    /// One chunk of ndjson (complete lines). Each line goes through a scanner for ktrace's flat one-object
    /// lines, ~10x faster than JSONDecoder (which took ~1 s per 200,000 events, a whole core for a busy
    /// process); a line the scanner can't read goes to JSONDecoder.
    static func decode(_ chunk: Data) -> (events: [KdebugEvent], bad: Int) {
        var out: [KdebugEvent] = []
        out.reserveCapacity(chunk.count / 240)
        var bad = 0
        chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i < b.count {
                var j = i
                while j < b.count && b[j] != 0x0A { j += 1 }
                if j > i {
                    if let e = scan(b, i, j) {
                        out.append(e)
                    } else if let js = try? JSONDecoder().decode(JSON.self, from: Data(b[i..<j])) {
                        out.append(KdebugEvent(ts: UInt64(js.timestampns) ?? 0, eventname: js.eventname, debugid: js.debugid,
                                               arg: js.args.map(number), thread: UInt64(js.threadid) ?? 0))
                    } else {
                        bad += 1
                    }
                }
                i = j + 1
            }
        }
        return (out, bad)
    }

    private static func number(_ s: String) -> UInt64 {
        UInt64(s) ?? (Int64(s).map { UInt64(bitPattern: $0) } ?? 0)
    }

    /// Reads `"key": value` pairs of one flat object. Values are a string, a number, or an array of strings
    /// (args). nil when anything else turns up, or a needed field is missing.
    private static func scan(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> KdebugEvent? {
        var e = KdebugEvent()
        var have = 0
        var i = start
        @inline(__always) func skipSpace() { while i < end, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0D { i += 1 } }
        /// At an opening quote: the string's bounds, with i past the closing quote. No escapes expected.
        @inline(__always) func string() -> Range<Int>? {
            guard i < end, b[i] == 0x22 else { return nil }
            let s = i + 1
            var k = s
            while k < end, b[k] != 0x22 { if b[k] == 0x5C { return nil }; k += 1 }
            guard k < end else { return nil }
            i = k + 1
            return s..<k
        }
        @inline(__always) func digits(_ r: Range<Int>) -> UInt64? {
            var neg = false, v: UInt64 = 0, k = r.lowerBound
            if k < r.upperBound, b[k] == 0x2D { neg = true; k += 1 }
            guard k < r.upperBound else { return nil }
            while k < r.upperBound {
                let d = b[k] &- 0x30
                guard d < 10 else { return nil }
                v = v &* 10 &+ UInt64(d)
                k += 1
            }
            return neg ? UInt64(bitPattern: -Int64(bitPattern: v)) : v
        }
        func key(_ r: Range<Int>, _ s: StaticString) -> Bool {
            guard r.count == s.utf8CodeUnitCount else { return false }
            return memcmp(b.baseAddress! + r.lowerBound, s.utf8Start, r.count) == 0
        }
        skipSpace()
        guard i < end, b[i] == 0x7B else { return nil }   // {
        i += 1
        while true {
            skipSpace()
            if i < end, b[i] == 0x7D { break }               // }
            guard let k = string() else { return nil }
            skipSpace()
            guard i < end, b[i] == 0x3A else { return nil }   // :
            i += 1
            skipSpace()
            guard i < end else { return nil }
            if b[i] == 0x22 {
                guard let v = string() else { return nil }
                if key(k, "timestampns") { guard let n = digits(v) else { return nil }; e.ts = n; have |= 1 }
                else if key(k, "threadid") { guard let n = digits(v) else { return nil }; e.thread = n; have |= 2 }
                else if key(k, "eventname") { e.eventname = String(decoding: UnsafeBufferPointer(rebasing: b[v]), as: UTF8.self) }
            } else if b[i] == 0x5B {                          // [
                i += 1
                var args: [UInt64] = []
                args.reserveCapacity(4)
                while true {
                    skipSpace()
                    if i < end, b[i] == 0x5D { i += 1; break }
                    guard let v = string(), let n = digits(v) else { return nil }
                    args.append(n)
                    skipSpace()
                    if i < end, b[i] == 0x2C { i += 1 }
                }
                if key(k, "args") { e.arg = args; have |= 4 }
            } else {
                let s = i
                while i < end, b[i] != 0x2C, b[i] != 0x7D, b[i] != 0x20 { i += 1 }
                if key(k, "debugid") {
                    guard let n = digits(s..<i), n <= UInt64(UInt32.max) else { return nil }
                    e.debugid = UInt32(n); have |= 8
                }
            }
            skipSpace()
            if i < end, b[i] == 0x2C { i += 1 }               // ,
        }
        return have == 15 ? e : nil
    }
}

/// Event names by debugid (function bits clear), from /usr/share/misc/trace.codes: the file ktrace names
/// events from. Lines are "0x40c0548\tBSC_stat64".
enum KdebugNames {
    static let table: [UInt32: String] = load("/usr/share/misc/trace.codes")

    static func load(_ path: String) -> [UInt32: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var t: [UInt32: String] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard f.count >= 2, f[0].hasPrefix("0x"), let id = UInt32(f[0].dropFirst(2), radix: 16) else { continue }
            t[id] = String(f[1])
        }
        return t
    }
}

/// Pairs entries with returns, per thread, and hangs path lookups on the call making them.
struct SyscallDecoder: Sendable {
    private struct Open: Sendable {
        var rec: SyscallRecord
        let debugBase: UInt32
        /// The thread's time on a CPU so far as the call was entered (`cpuTime`), and the gap count then.
        var cpuAtEntry: UInt64 = 0
        var gapsAtEntry = 0
    }

    /// A stretch one of the traced process's threads spent on a CPU, in ns since the trace started.
    struct Run: Sendable, Equatable {
        let thread: UInt64
        let start: UInt64
        let end: UInt64
    }
    /// When each of the process's threads now on a CPU came on, as far as the trace shows: at a context switch to
    /// it, or at its first sign of running (a call, or the scheduler leaving it on at the end of its quantum),
    /// when the switch came before the trace or before the helper knew the thread. So a run's start can be late
    /// (by a quantum at most, about 10 ms) and never early.
    private var onSince: [UInt64: UInt64] = [:]
    /// Each thread's finished runs added up.
    private var ranFor: [UInt64: UInt64] = [:]
    private var runs: [Run] = []
    private var lastTime: UInt64 = 0
    /// The helper marks whose each context switch is (KdebugEvent.ours): without that, a switch to one of the
    /// process's threads can't be told from any other, and nothing is measured (an older helper, ktrace).
    private var marked = false
    /// Runs and calls' time on a CPU can be trusted: the switches are marked and no events were lost.
    var cpuMeasured: Bool { marked && gaps == 0 }

    /// The runs still going at the last event, up to it.
    func openRuns() -> [Run] {
        onSince.compactMap { t, since in lastTime > since ? Run(thread: t, start: since, end: lastTime) : nil }
    }

    /// The runs finished since the last call.
    mutating func takeRuns() -> [Run] {
        defer { runs = [] }
        return runs
    }

    /// The runs still going when the trace ended, ended there.
    mutating func endRuns() -> [Run] {
        for (t, since) in onSince where lastTime > since { runs.append(Run(thread: t, start: since, end: lastTime)) }
        onSince = [:]
        return takeRuns()
    }

    /// One of the process's threads shows it is running.
    private mutating func running(_ thread: UInt64, _ ts: UInt64) {
        if onSince[thread] == nil { onSince[thread] = ts }
    }

    /// The thread's time on a CPU up to `ts`.
    private func cpuTime(_ thread: UInt64, _ ts: UInt64) -> UInt64 {
        (ranFor[thread] ?? 0) + (onSince[thread].map { ts > $0 ? ts - $0 : 0 } ?? 0)
    }

    /// A context switch: the event's thread leaves its CPU and args[1] takes it.
    private mutating func switched(_ e: KdebugEvent) {
        if e.ours & 1 != 0, let since = onSince.removeValue(forKey: e.thread), e.ts > since {
            ranFor[e.thread, default: 0] += e.ts - since
            runs.append(Run(thread: e.thread, start: since, end: e.ts))
        }
        if e.ours & 2 != 0 { onSince[e.arg[1]] = e.ts }
    }
    private var open: [UInt64: [Open]] = [:]
    private var lookups: [UInt64: Data] = [:]
    private var nextID = 0
    /// Places where the kernel lost events.
    private(set) var gaps = 0
    /// Traces with stacks: a returned call waits here for its stack, which the kernel samples on the way back to
    /// user space and so logs after the return, on the same thread.
    private let stacks: Bool
    private var held: [UInt64: SyscallRecord] = [:]
    private var building: [UInt64: (count: Int, words: [UInt64])] = [:]
    /// The trace has scheduler events: a call without one didn't block (and not because the events are missing).
    private var schedSeen = false
    /// TRACE_STRING_GLOBAL ids → text (dyld's paths and symbol names), and strings still arriving, per thread.
    private var strings: [UInt64: String] = [:]
    private var stringParts: [UInt64: (id: UInt64, bytes: Data)] = [:]
    /// Thread names from the trace (TRACE_STRING_THREADNAME), and names still arriving.
    private(set) var threadNames: [UInt64: String] = [:]
    private var nameParts: [UInt64: Data] = [:]
    /// dyld calls between their start and end, by sequence number; image headers and dlopen handles → paths.
    private var dyldOpen: [UInt64: SyscallRecord] = [:]
    private var images: [UInt64: String] = [:]
    private var handles: [UInt64: String] = [:]
    private var imageLoad: [UInt64: (ts: UInt64, header: UInt64)] = [:]
    /// When dyld first started (DBG_DYLD_TIMING_BOOTSTRAP_START): the start of the launch's setup.
    private var bootstrap: UInt64?

    init(stacks: Bool = false) { self.stacks = stacks }

    /// Completed records, in the order they returned.
    mutating func feed(_ events: [KdebugEvent]) -> [SyscallRecord] {
        var out: [SyscallRecord] = []
        for e in events {
            lastTime = max(lastTime, e.ts)
            if e.debugid == KdebugEvent.lostEvents {
                // A call open across the gap may have returned in it: pairing its entry with a later return of the
                // same call would be wrong, so start over. Returns of calls entered before show as entryMissed.
                // Nor is it known who was on a CPU across the gap.
                onSince = [:]
                open = [:]; lookups = [:]; gaps += 1; dyldOpen = [:]; stringParts = [:]; nameParts = [:]; imageLoad = [:]
                out += held.values; held = [:]; building = [:]
                continue
            }
            if stacks && e.cls == 0x25 {
                stackEvent(e, &out)
                continue
            }
            if e.cls == 3 && e.subclass == 1 && e.code == 0x24 { lookup(e); continue }
            if e.cls == 1 && e.subclass == 0x40 { sched(e); continue }
            if e.cls == 7 && e.subclass == 1 { traceString(e); continue }
            if e.cls == 0x1f { dyld(e, &out); continue }
            if e.cls == 0xff {
                // MIG start: the routine handling the message of the innermost open call (a mach_msg2_trap).
                if e.fn & 1 != 0, var stack = open[e.thread], !stack.isEmpty, stack[stack.count - 1].rec.name.hasPrefix("mach_msg") {
                    stack[stack.count - 1].rec.kernelRoutine = Int((e.debugid & 0xff_ffff) >> 2)
                    open[e.thread] = stack
                }
                continue
            }
            guard e.subclass == 0x0c, e.cls == 4 || e.cls == 1 else { continue }
            let base = e.debugid & ~3
            let mach = e.cls == 1
            running(e.thread, e.ts)
            switch e.fn {
            case 1:
                // A new call on the thread: the last one's stack isn't coming.
                if let h = held.removeValue(forKey: e.thread) { out.append(h) }
                var r = SyscallRecord(id: nextID, start: e.ts, end: nil, thread: e.thread, mach: mach,
                                      number: e.code, name: Self.name(e.eventname, mach: mach, code: e.code))
                nextID += 1
                r.args = e.arg
                open[e.thread, default: []].append(Open(rec: r, debugBase: base, cpuAtEntry: cpuTime(e.thread, e.ts), gapsAtEntry: gaps))
            case 2:
                var r: SyscallRecord
                if var stack = open[e.thread], let i = stack.lastIndex(where: { $0.debugBase == base }) {
                    r = stack[i].rec
                    if marked, stack[i].gapsAtEntry == gaps { r.cpu = cpuTime(e.thread, e.ts) - stack[i].cpuAtEntry }
                    // Anything opened after it on this thread never returned in the trace: drop it.
                    stack.removeSubrange(i...)
                    open[e.thread] = stack.isEmpty ? nil : stack
                } else {
                    r = SyscallRecord(id: nextID, start: nil, end: nil, thread: e.thread, mach: mach,
                                      number: e.code, name: Self.name(e.eventname, mach: mach, code: e.code))
                    nextID += 1
                    r.state = .entryMissed
                }
                r.end = e.ts
                if r.state == .done, schedSeen { r.blocked = r.blocked ?? false }
                let a = e.arg
                if mach {
                    r.error = Int64(Int32(truncatingIfNeeded: a.first ?? 0))
                } else {
                    r.error = Int64(bitPattern: a.first ?? 0)
                    r.ret = a.count > 1 ? a[1] : 0
                    r.ret1 = a.count > 2 ? a[2] : 0
                }
                SyscallFormat.fill(&r)
                if stacks {
                    if let h = held.updateValue(r, forKey: e.thread) { out.append(h) }
                } else {
                    out.append(r)
                }
            default:
                continue
            }
        }
        return out
    }

    /// Frames come as the pc, the frame-pointer chain (ending in 0), then the link register at the time, which
    /// is the stub's caller: a syscall stub is a leaf without a frame of its own, so the chain starts one further
    /// out. Checked on a test program: stat's pc, LR in leaf(), then middle(), main(), dyld's start.
    private mutating func stackEvent(_ e: KdebugEvent, _ out: inout [SyscallRecord]) {
        if e.debugid & ~3 == KdebugEvent.stackHeader {
            let flags = e.arg.first ?? 0, n = e.arg.count > 1 ? Int(e.arg[1]) : 0
            building[e.thread] = flags & 1 != 0 && n > 0 && n <= 1024 ? (n, []) : nil   // CALLSTACK_VALID
            return
        }
        guard e.debugid & ~3 == KdebugEvent.stackData, var b = building[e.thread] else { return }
        b.words += e.arg
        guard b.words.count >= b.count else { building[e.thread] = b; return }
        building[e.thread] = nil
        let f = Array(b.words.prefix(b.count))
        var frames = [f[0]]
        if f.count > 1, let lr = f.last, lr != 0 { frames.append(lr) }
        if f.count > 2 { frames += f[1..<(f.count - 1)].filter { $0 != 0 } }
        guard var r = held.removeValue(forKey: e.thread) else { return }
        r.stack = frames
        out.append(r)
    }

    /// Calls that returned and were still waiting for a stack: due when the trace ends.
    mutating func flush() -> [SyscallRecord] {
        let r = Array(held.values)
        held = [:]
        return r
    }

    /// Calls still inside the kernel; shown when the trace stops.
    func pending() -> [SyscallRecord] {
        open.values.flatMap { $0.map { o in
            var r = o.rec
            r.state = .inProgress
            SyscallFormat.fill(&r)
            return r
        } }.sorted { $0.time < $1.time }
    }

    private static func bytes(_ words: ArraySlice<UInt64>) -> Data {
        var d = Data()
        for w in words { withUnsafeBytes(of: w.littleEndian) { d.append(contentsOf: $0) } }
        return d
    }

    private static func text(_ d: Data) -> String {
        String(decoding: d.prefix { $0 != 0 }, as: UTF8.self)
    }

    private mutating func traceString(_ e: KdebugEvent) {
        switch e.code {
        case 0:   // TRACE_STRING_GLOBAL
            if e.fn & 1 != 0 {
                guard e.arg.count > 1 else { return }
                stringParts[e.thread] = (e.arg[1], Self.bytes(e.arg.dropFirst(2)))
            } else if var p = stringParts[e.thread] {
                p.bytes += Self.bytes(e.arg[...])
                stringParts[e.thread] = p
            }
            guard e.fn & 2 != 0, let p = stringParts.removeValue(forKey: e.thread) else { return }
            let s = Self.text(p.bytes)
            // The release of an id comes as the same id sent empty, after the events that used it: keep the text.
            if !s.isEmpty { strings[p.id] = s }
        case 4, 5:   // TRACE_STRING_THREADNAME, _PREV
            var d = e.fn & 1 != 0 ? Data() : nameParts[e.thread] ?? Data()
            d += Self.bytes(e.arg[...])
            guard e.fn & 2 != 0 || e.fn == 0 && d.count >= 64 else { nameParts[e.thread] = d; return }
            nameParts[e.thread] = nil
            let s = Self.text(d)
            // _PREV is the name a thread had before a rename: it names the thread only if nothing newer did.
            if !s.isEmpty, e.code == 4 || threadNames[e.thread] == nil { threadNames[e.thread] = s }
        default: break
        }
    }

    /// RTLD_DEFAULT and the other pseudo-handles of dlsym, by value.
    private static let pseudoHandles: [UInt64: String] = [
        UInt64(bitPattern: -1): "RTLD_NEXT", UInt64(bitPattern: -2): "RTLD_DEFAULT",
        UInt64(bitPattern: -3): "RTLD_SELF", UInt64(bitPattern: -5): "RTLD_MAIN_ONLY",
    ]

    private func handleText(_ h: UInt64) -> String {
        Self.pseudoHandles[h] ?? handles[h].map(SyscallFormat.quote) ?? "handle 0x" + String(h, radix: 16)
    }

    private mutating func dyld(_ e: KdebugEvent, _ out: inout [SyscallRecord]) {
        let a = e.arg
        switch (e.subclass, e.code) {
        case (0x05, 0):   // DYLD_uuid_map_a: the path follows in _b
            if a.count > 2 { imageLoad[e.thread] = (e.ts, a[2]) }
            return
        case (0x05, 1):
            guard let load = imageLoad.removeValue(forKey: e.thread), a.count > 1 else { return }
            let path = strings[a[1]] ?? "image at 0x" + String(load.header, radix: 16)
            images[load.header] = path
            var r = SyscallRecord(id: nextID, start: load.ts, end: e.ts, thread: e.thread, mach: false,
                                  number: SyscallRecord.libraryCall, name: "load image")
            nextID += 1
            r.args = [load.header]
            r.paths = [path]
            r.argValues = [SyscallFormat.quote(path)]
            r.resultText = "at 0x" + String(load.header, radix: 16)
            out.append(r)
            return
        case (0x07, 13):
            if bootstrap == nil { bootstrap = e.ts }
            return
        case (0x08, 0), (0x08, 2), (0x08, 3), (0x08, 4), (0x07, 0), (0x07, 1): break
        default: return
        }
        guard let seq = a.first else { return }
        if e.fn & 1 != 0 {
            let name = switch (e.subclass, e.code) {
            case (0x08, 0): "dlopen"
            case (0x08, 2): "dlclose"
            case (0x08, 3): "dlsym"
            case (0x08, 4): "dladdr"
            case (0x07, 1): "dyld setup"
            default: "initializer"
            }
            var r = SyscallRecord(id: nextID, start: e.ts, end: nil, thread: e.thread, mach: false,
                                  number: SyscallRecord.libraryCall, name: name)
            nextID += 1
            r.args = Array(a.dropFirst())
            switch (e.subclass, e.code) {
            case (0x08, 0):
                let path = a.count > 1 ? strings[a[1]] ?? "" : ""
                if !path.isEmpty { r.paths = [path] }
                r.argValues = [path.isEmpty ? "NULL" : SyscallFormat.quote(path), a.count > 2 ? "0x" + String(a[2], radix: 16) : "…"]
            case (0x08, 2):
                let h = a.count > 1 ? a[1] : 0
                if let p = handles[h] { r.paths = [p] }
                r.argValues = [handleText(h)]
            case (0x08, 3):
                let h = a.count > 1 ? a[1] : 0
                if let p = handles[h] { r.paths = [p] }
                r.argValues = [handleText(h), SyscallFormat.quote(a.count > 2 ? strings[a[2]] ?? "?" : "?")]
            case (0x08, 4):
                r.argValues = [a.count > 1 ? "0x" + String(a[1], radix: 16) : "…"]
            case (0x07, 1):
                // From dyld's own start when seen: the whole of dyld's work before main.
                if let b = bootstrap, b < e.ts { r.start = b }
            default:
                let header = a.count > 1 ? a[1] : 0
                if let p = images[header] { r.paths = [p] }
                r.argValues = [images[header].map(SyscallFormat.quote) ?? "image at 0x" + String(header, radix: 16),
                               a.count > 2 ? "0x" + String(a[2], radix: 16) : "…"]
                if a.count > 2, a[2] != 0 { r.stack = [a[2]] }
            }
            dyldOpen[seq] = r
            return
        }
        guard e.fn & 2 != 0, var r = dyldOpen.removeValue(forKey: seq) else { return }
        r.end = e.ts
        let v = a.count > 1 ? a[1] : 0
        switch r.name {
        case "dlopen":
            r.failed = v == 0
            r.resultText = v == 0 ? "NULL (failed)" : "handle 0x" + String(v, radix: 16)
            if v != 0, let p = r.paths.first { handles[v] = p }
        case "dlsym":
            r.failed = v == 0
            r.resultText = v == 0 ? "NULL (not found)" : "0x" + String(v, radix: 16)
        case "dlclose":
            r.resultText = v == 0 ? "0" : "-1"
            r.failed = v != 0
        case "dladdr":
            r.resultText = v == 0 ? "0 (not in an image)" : String(v)
        case "dyld setup":
            // The main executable's header was the start's argument; its path came with its image load since.
            let header = r.args?.first ?? 0
            let path = images[header]
            if let path { r.paths = [path] }
            r.argValues = [path.map(SyscallFormat.quote) ?? "image at 0x" + String(header, radix: 16)]
            r.resultText = "done: main() starts"
            out.append(r)
            var m = SyscallRecord(id: nextID, start: e.ts, end: e.ts, thread: e.thread, mach: false,
                                  number: SyscallRecord.libraryCall, name: "main()")
            nextID += 1
            m.args = []
            m.paths = r.paths
            m.argValues = []
            m.resultText = "the program's own code starts"
            out.append(m)
            return
        default:
            r.resultText = "done"
        }
        out.append(r)
    }

    /// Scheduler events land on the innermost open call of their thread: who it woke first, whether it blocked.
    private mutating func sched(_ e: KdebugEvent) {
        schedSeen = true
        if KdebugEvent.contextSwitch.contains(e.debugid & ~3) {
            // The scheduler also logs a "switch" from a thread to itself when it looks for something better to
            // run and finds nothing (seen after MACH_REDISPATCH in a thread computing through its quantum): the
            // thread keeps its CPU, so it neither left it nor blocked.
            if e.ours != 0 { marked = true }
            if e.arg.count > 1, e.arg[1] == e.thread {
                if e.ours != 0 { running(e.thread, e.ts) }
                return
            }
            if e.arg.count > 1 { switched(e) }
        }
        guard var stack = open[e.thread], !stack.isEmpty else { return }
        let base = e.debugid & ~3
        var r = stack[stack.count - 1].rec
        if KdebugEvent.gaveUpCPU.contains(base) {
            r.blocked = true
        } else if base == KdebugEvent.makeRunnable, r.blocked != true, r.woke == 0, let t = e.arg.first, t != e.thread {
            r.woke = t
        } else {
            return
        }
        stack[stack.count - 1].rec = r
        open[e.thread] = stack
    }

    private mutating func lookup(_ e: KdebugEvent) {
        let a = e.arg
        var bytes = lookups[e.thread] ?? Data()
        let words = e.fn & 1 != 0 ? a.dropFirst() : a[...]   // the first event's args[0] is the vnode id
        if e.fn & 1 != 0 { bytes = Data() }
        for w in words { withUnsafeBytes(of: w.littleEndian) { bytes.append(contentsOf: $0) } }
        guard e.fn & 2 != 0 else { lookups[e.thread] = bytes; return }
        lookups[e.thread] = nil
        var path = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        // The event carries the lookup's path buffer as it ended: after a symlink, its target with the rest of the
        // path, relative to the link's folder. /etc, /tmp and /var link to private/… from the root, so
        // open("/etc/hosts") arrives as "private/etc/hosts". A deeper relative link's folder isn't in the event.
        if path.hasPrefix("private/") { path = "/" + path }
        guard !path.isEmpty, var stack = open[e.thread], !stack.isEmpty else { return }
        stack[stack.count - 1].rec.paths.append(path)
        open[e.thread] = stack
    }

    /// trace.codes names a few calls with a sys_ prefix (sys_close, sys_fcntl, sys_fstat64...): dropped, as
    /// strace and the man pages name them.
    static func name(_ eventName: String?, mach: Bool, code: Int) -> String {
        var n = eventName ?? ""
        if n.count > 4, n.hasPrefix("BSC_") || n.hasPrefix("MSC_") { n = String(n.dropFirst(4)) }
        if n.hasPrefix("sys_"), n.count > 4 { n = String(n.dropFirst(4)) }
        // trace.codes lags the kernel: a call it doesn't know is "kern_invalid_63" or has no name at all.
        if n.isEmpty || n.hasPrefix("0x") || n.hasPrefix("kern_invalid") {
            if let known = (mach ? SyscallArgNames.machNumbers : SyscallArgNames.bsdNumbers)[code] {
                return known.hasPrefix("sys_") ? String(known.dropFirst(4)) : known
            }
            return mach ? "mach_trap_\(code)" : "syscall_\(code)"
        }
        return n
    }
}

/// Adds what each fd argument is: "read(3 (/etc/hosts), …)", "sendto(7 (UDP 10.0.0.2:5353->224.0.0.251:5353), …)".
///
/// fds can be closed and their numbers reused between a call and any lookup, so the trace itself comes first:
/// an fd returned by open/openat carries that call's path until it's closed, dup copies a label, close ends it.
/// Only fds the trace can't explain (open before the trace started, received over a socket, made from a fileport)
/// and sockets (whose endpoints change on connect) are asked of the helper, once per batch of records, and a
/// helper answer is applied only after the fd's last open/close/dup in the batch. An fd closed and reopened by
/// something the trace doesn't show, between the call and the lookup, can still get a stale label.
///
/// A connection is often over before that lookup, so the helper also reads a socket's endpoints as its calls
/// come by (SeenSocket): such a reading names the socket from the call it was made for to the socket's close.
struct FdLabeler {
    /// Labels the trace itself established.
    private var known: [Int32: String] = [:]
    /// fds whose trace label is only a kind ("UDP socket"): a valid helper answer (with endpoints) wins.
    private var refreshable: Set<Int32> = []
    /// When each descriptor last changed hands (opened, made, copied onto, closed).
    private var changed: [Int32: UInt64] = [:]
    /// The helper's readings of sockets' endpoints not yet matched to a call.
    private var seen: [Int32: [SeenSocket]] = [:]

    /// (argument index, fd) for each fd argument of a record.
    static func fdArgs(_ r: SyscallRecord) -> [(Int, Int32)] {
        guard let a = r.args else { return [] }
        let base = r.name.hasSuffix("_nocancel") ? String(r.name.dropLast(9)) : r.name
        var idx: [Int] = []
        if ["fcntl", "setsockopt", "getsockopt", "openat", "connectx"].contains(base) { idx = [0] }
        else if let sig = SyscallFormat.signature(base) { idx = sig.indices.filter { sig[$0] == .fd || sig[$0] == .dirfd } }
        return idx.compactMap { i in
            guard i < a.count, i < r.argValues.count else { return nil }
            let fd = Int32(truncatingIfNeeded: a[i])
            return fd >= 0 ? (i, fd) : nil   // AT_FDCWD is -2
        }
    }

    private enum Effect { case open(Int32, String), socket(Int32, String), unknown(Int32), copy(from: Int32, to: Int32), close(Int32) }

    /// "UDP socket" from socket()'s own arguments, for when the socket is gone before anyone can ask about it.
    private static func socketKind(_ a: [UInt64]) -> String {
        guard a.count >= 2 else { return "socket" }
        let domain = Int32(truncatingIfNeeded: a[0]), type = Int32(truncatingIfNeeded: a[1])
        switch domain {
        case AF_INET, AF_INET6:
            let v = domain == AF_INET6 ? "6" : ""
            return type == SOCK_STREAM ? "TCP\(v) socket" : type == SOCK_DGRAM ? "UDP\(v) socket" : "IPv\(domain == AF_INET6 ? 6 : 4) raw socket"
        case AF_UNIX: return "unix socket"
        default: return SyscallFlags.one(UInt64(UInt32(bitPattern: domain)), SyscallFlags.domains) + " socket"
        }
    }

    /// What a successful call did to the descriptor table, as far as the trace shows.
    private static func effects(_ r: SyscallRecord) -> [Effect] {
        guard r.state == .done, r.error == 0, !r.mach, let a = r.args else { return [] }
        let base = r.name.hasSuffix("_nocancel") ? String(r.name.dropLast(9)) : r.name
        let ret = Int32(truncatingIfNeeded: r.ret)
        let arg0 = a.isEmpty ? -1 : Int32(truncatingIfNeeded: a[0])
        switch base {
        case "close", "guarded_close_np": return [.close(arg0)]
        case "dup": return [.copy(from: arg0, to: ret)]
        case "dup2": return a.count > 1 ? [.copy(from: arg0, to: Int32(truncatingIfNeeded: a[1]))] : []
        case "fcntl":
            let cmd = a.count > 1 ? Int32(truncatingIfNeeded: a[1]) : -1
            return cmd == F_DUPFD || cmd == F_DUPFD_CLOEXEC ? [.copy(from: arg0, to: ret)] : []
        case "pipe": return [.unknown(ret), .unknown(Int32(truncatingIfNeeded: r.ret1))]
        default:
            guard case .fd = SyscallFormat.returns[base] else { return [] }
            if let p = r.paths.first, base.contains("open") { return [.open(ret, p)] }
            if base == "socket" { return [.socket(ret, socketKind(a))] }
            return [.unknown(ret)]   // accept, kqueue, fileport_makefd...
        }
    }

    /// Labels the fd arguments of `recs` (in the order they returned), asking `lookup` about the rest.
    /// `sockets`: asked after `lookup`, for the endpoints the helper read as the calls came by.
    mutating func label(_ recs: inout [SyscallRecord], sockets: () -> [SeenSocket] = { [] }, lookup: (Set<Int32>) -> [Int32: String]) {
        // Pass 1: which fds the trace can't name, and where each fd last changed in this batch.
        var state = known
        var need = Set<Int32>()
        var lastChange: [Int32: Int] = [:]
        var soft = refreshable
        for (n, r) in recs.enumerated() {
            for (_, fd) in Self.fdArgs(r) where state[fd] == nil || soft.contains(fd) { need.insert(fd) }
            for e in Self.effects(r) { apply(e, to: &state, soft: &soft, at: n, lastChange: &lastChange) }
        }
        let answers = need.isEmpty ? [:] : lookup(need)
        for s in sockets() { seen[s.fd, default: []].append(s) }
        // Pass 2: label, replaying the same changes.
        var scratch: [Int32: Int] = [:]
        for n in recs.indices {
            for (i, fd) in Self.fdArgs(recs[n]) {
                let answer = (lastChange[fd] ?? -1) <= n ? answers[fd] : nil
                // A reading made for a call on this descriptor since it last changed hands, up to this call: the
                // socket's endpoints, which the lookup just now can't give once it is closed.
                let at = recs[n].end ?? recs[n].time
                if answer?.contains("->") != true, known[fd]?.hasPrefix("/") != true,
                   let s = seen[fd]?.last(where: { $0.time >= changed[fd] ?? 0 && $0.time <= at }) {
                    known[fd] = s.label
                }
                // A socket's lookup wins, unless it has lost the endpoints a reading had.
                let reading = known[fd].flatMap { $0.contains("->") && answer?.contains("->") != true ? $0 : nil }
                let label = refreshable.contains(fd) ? (reading ?? answer ?? known[fd]) : (known[fd] ?? answer)
                if let label, !label.isEmpty {
                    recs[n].argValues[i] += " (" + label + ")"
                    if i == 0 { recs[n].firstFDLabel = label }
                }
            }
            for e in Self.effects(recs[n]) {
                apply(e, to: &known, soft: &refreshable, at: n, lastChange: &scratch)
                let t = recs[n].end ?? recs[n].time
                switch e {
                case .open(let fd, _), .socket(let fd, _), .unknown(let fd), .close(let fd), .copy(_, let fd):
                    changed[fd] = t
                    seen[fd]?.removeAll { $0.time < t }
                }
            }
        }
    }

    private func apply(_ e: Effect, to t: inout [Int32: String], soft: inout Set<Int32>, at n: Int, lastChange: inout [Int32: Int]) {
        switch e {
        case .open(let fd, let p): t[fd] = p; soft.remove(fd); lastChange[fd] = n
        case .socket(let fd, let kind): t[fd] = kind; soft.insert(fd); lastChange[fd] = n
        case .unknown(let fd): t[fd] = nil; soft.remove(fd); lastChange[fd] = n
        case .copy(let from, let to):
            t[to] = t[from]
            if soft.contains(from) { soft.insert(to) } else { soft.remove(to) }
            lastChange[to] = n
        case .close(let fd): t[fd] = nil; soft.remove(fd); lastChange[fd] = n
        }
    }
}

/// strace-style text for arguments and results.
enum SyscallFormat {
    enum Arg {
        case fd, dirfd, int, int32, uint, hex, ptr, size, oflags, mode, signal
        /// A path argument: the path the kernel looked up for it (VFS_LOOKUP), else the pointer.
        case path
        case prot, mapFlags, madvise, msync, vmFlags, vmProt
        case access, atFlags, whence, flock, ioctl
        case domain, sockType, proto, msgFlags, shutdownHow
        case sigHow, ulock, workqOp, csops, procInfoCall
        case portRight, machNotify
        case chflags, prioWhich, rusageWho, rlimit, waitOptions, snapshotOp, purgable, personaOp, iopolCmd
        case workloopCmd, coalitionOp, coalitionInfo, memorystatusCmd
        case machOptions
        case necpAction, channelSyncMode, channelSyncFlags
        /// mac_syscall's policy: a pointer to the policy's name ("Sandbox", "Quarantine"), read from the shared cache.
        case macPolicy
    }

    /// Arity and argument kinds (kdebug logs the first four arguments). Others show all four raw words.
    /// fcntl, setsockopt/getsockopt, proc_info, open's mode and mach_msg2_trap are formatted in `special`.
    static let signatures: [String: [Arg]] = {
        var s: [String: [Arg]] = [:]
        func set(_ names: [String], _ a: [Arg]) { for n in names { s[n] = a; s[n + "_nocancel"] = a } }
        set(["read", "write"], [.fd, .ptr, .size])
        set(["pread", "pwrite"], [.fd, .ptr, .size, .int])
        set(["readv", "writev", "preadv", "pwritev"], [.fd, .ptr, .int])
        set(["close", "fsync", "fchdir", "dup"], [.fd])
        set(["dup2"], [.fd, .fd])
        set(["guarded_open_np"], [.path, .ptr, .hex, .oflags])
        set(["guarded_close_np"], [.fd, .ptr])
        set(["ioctl"], [.fd, .ioctl, .ptr])
        set(["lseek"], [.fd, .int, .whence])
        set(["fstat", "fstat64"], [.fd, .ptr])
        set(["stat", "stat64", "lstat", "lstat64", "statfs", "statfs64", "utimes", "lutimes"], [.path, .ptr])
        set(["access"], [.path, .access])
        set(["faccessat"], [.dirfd, .path, .access, .atFlags])
        set(["chdir", "chroot", "unlink", "rmdir", "revoke", "undelete"], [.path])
        set(["readlink"], [.path, .ptr, .size])
        set(["readlinkat"], [.dirfd, .path, .ptr, .size])
        set(["fstatat", "fstatat64"], [.dirfd, .path, .ptr, .atFlags])
        set(["unlinkat"], [.dirfd, .path, .atFlags])
        set(["mkdir", "mkfifo", "chmod"], [.path, .mode])
        set(["mknod"], [.path, .mode, .int])
        set(["mkdirat", "mkfifoat"], [.dirfd, .path, .mode])
        set(["fchmodat"], [.dirfd, .path, .mode, .atFlags])
        set(["chown", "lchown"], [.path, .int32, .int32])
        set(["fchownat"], [.dirfd, .path, .int32, .int32])
        set(["truncate", "pathconf"], [.path, .int])
        set(["rename", "link", "exchangedata"], [.path, .path])
        set(["renameat", "renameatx_np", "linkat", "clonefileat"], [.dirfd, .path, .dirfd, .path])
        set(["symlink"], [.ptr, .path])               // the target is stored, not looked up
        set(["symlinkat"], [.ptr, .dirfd, .path])
        set(["fclonefileat"], [.fd, .dirfd, .path, .hex])
        set(["getattrlist", "setattrlist"], [.path, .ptr, .ptr, .size])
        set(["getattrlistat"], [.dirfd, .path, .ptr, .ptr])
        set(["fgetattrlist", "fsetattrlist"], [.fd, .ptr, .ptr, .size])
        set(["getattrlistbulk"], [.fd, .ptr, .ptr, .size])
        set(["getxattr", "setxattr"], [.path, .ptr, .ptr, .size])
        set(["removexattr"], [.path, .ptr, .hex])
        set(["listxattr"], [.path, .ptr, .size, .hex])
        // Path-taking calls also handled by pykdebugparser (github.com/matan1008/pykdebugparser), which reads
        // their paths from VFS_LOOKUP the same way.
        set(["acct", "ungraftdmg"], [.path])
        set(["chflags"], [.path, .chflags])
        set(["fchflags"], [.fd, .chflags])
        set(["fchflagsat"], [.dirfd, .path, .chflags, .atFlags])
        set(["fsctl"], [.path, .hex, .ptr, .hex])
        set(["fs_snapshot"], [.snapshotOp, .dirfd, .path, .path])
        set(["getfh"], [.path, .ptr])
        set(["mknodat"], [.dirfd, .path, .mode, .int])
        set(["open_dprotected_np"], [.path, .oflags, .int, .int])
        set(["openat_dprotected_np"], [.dirfd, .path, .oflags, .int])
        set(["guarded_open_dprotected_np"], [.path, .ptr, .hex, .oflags])
        set(["pivot_root"], [.path, .path])
        set(["quotactl"], [.path, .int, .int, .ptr])
        set(["searchfs"], [.path, .ptr, .ptr, .uint])
        set(["setattrlistat"], [.dirfd, .path, .ptr, .ptr])
        set(["unmount"], [.path, .hex])
        set(["mount"], [.ptr, .path, .hex, .ptr])                 // the type is a name, not a path
        set(["getpriority"], [.prioWhich, .int32])
        set(["setpriority"], [.prioWhich, .int32, .int32])
        set(["getrusage"], [.rusageWho, .ptr])
        set(["getrlimit", "setrlimit"], [.rlimit, .ptr])
        set(["wait4"], [.int32, .ptr, .waitOptions, .ptr])
        set(["sigaction"], [.signal, .ptr, .ptr])
        set(["setuid", "seteuid", "setgid", "setegid", "getpgid", "getsid"], [.int32])
        set(["setpgid"], [.int32, .int32])
        set(["execve"], [.path, .ptr, .ptr])
        set(["posix_spawn"], [.ptr, .path, .ptr, .ptr])
        set(["getdirentries64"], [.fd, .ptr, .size, .ptr])
        set(["fstatfs64", "fstatfs"], [.fd, .ptr])
        set(["ftruncate"], [.fd, .int])
        set(["flock"], [.fd, .flock])
        set(["fchmod"], [.fd, .mode])
        set(["fchown"], [.fd, .int32, .int32])
        set(["fgetxattr", "fsetxattr"], [.fd, .ptr, .ptr, .size])
        set(["mmap"], [.ptr, .size, .prot, .mapFlags])   // fd and offset are the 5th and 6th
        set(["munmap", "mlock", "munlock"], [.ptr, .size])
        set(["mprotect"], [.ptr, .size, .prot])
        set(["madvise"], [.ptr, .size, .madvise])
        set(["msync"], [.ptr, .size, .msync])
        set(["socket"], [.domain, .sockType, .proto])
        set(["socketpair"], [.domain, .sockType, .proto, .ptr])
        set(["connect", "bind"], [.fd, .ptr, .size])
        set(["listen"], [.fd, .int])
        set(["accept"], [.fd, .ptr, .ptr])
        set(["sendto", "recvfrom"], [.fd, .ptr, .size, .msgFlags])
        set(["sendmsg", "recvmsg"], [.fd, .ptr, .msgFlags])
        set(["sendmsg_x", "recvmsg_x"], [.fd, .ptr, .uint, .msgFlags])
        set(["shutdown"], [.fd, .shutdownHow])
        set(["select", "pselect"], [.int, .ptr, .ptr, .ptr])
        set(["poll"], [.ptr, .uint, .int])
        set(["kevent", "kevent64", "kevent_qos"], [.fd, .ptr, .int, .ptr])
        set(["kevent_id"], [.hex, .ptr, .int, .ptr])   // a workloop id, not a descriptor
        set(["kqueue", "getpid", "getppid", "getuid", "geteuid", "getgid", "getegid", "fork", "vfork", "sync", "issetugid"], [])
        set(["kill"], [.int, .signal])
        set(["__pthread_kill"], [.hex, .signal])
        set(["sigprocmask", "__pthread_sigmask", "pthread_sigmask"], [.sigHow, .ptr, .ptr])
        set(["guarded_write_np"], [.fd, .ptr, .ptr, .size])          // fd, guard, buf, nbyte
        set(["guarded_pwrite_np"], [.fd, .ptr, .ptr, .size])         // ... offset is the 5th
        set(["guarded_writev_np"], [.fd, .ptr, .ptr, .int])
        set(["psynch_mutexwait", "psynch_mutexdrop"], [.ptr, .hex, .hex, .hex])
        set(["psynch_cvwait", "psynch_cvsignal", "psynch_cvbroad"], [.ptr, .hex, .hex, .ptr])
        set(["ulock_wait"], [.ulock, .ptr, .hex, .uint])     // timeout in µs
        set(["ulock_wait2"], [.ulock, .ptr, .hex, .uint])    // timeout in ns
        set(["ulock_wake"], [.ulock, .ptr, .hex])
        set(["workq_kernreturn"], [.workqOp, .ptr, .int, .int])
        set(["bsdthread_ctl"], [.hex, .hex, .hex, .hex])
        set(["exit"], [.int])
        set(["getentropy"], [.ptr, .size])
        set(["csops", "csops_audittoken"], [.int, .csops, .ptr, .size])
        set(["sysctl"], [.ptr, .uint, .ptr, .ptr])
        set(["sysctlbyname"], [.ptr, .size, .ptr, .ptr])
        set(["fsgetpath"], [.ptr, .size, .ptr, .hex])
        set(["shared_region_check_np"], [.ptr])
        set(["thread_selfid", "thread_selfusage"], [])
        // Mach traps
        set(["mach_msg_trap", "mach_msg_overwrite_trap"], [.ptr, .machOptions, .size, .size])
        set(["mach_reply_port", "thread_self_trap", "task_self_trap", "host_self_trap", "thread_get_special_reply_port"], [])
        set(["semaphore_signal_trap", "semaphore_wait_trap"], [.hex])
        set(["semaphore_timedwait_trap"], [.hex, .uint, .uint])
        set(["mk_timer_arm"], [.hex, .uint])
        set(["mk_timer_cancel"], [.hex, .ptr])
        set(["mach_vm_allocate_trap"], [.hex, .ptr, .size, .vmFlags])
        set(["mach_vm_deallocate_trap"], [.hex, .ptr, .size])
        set(["mach_vm_protect_trap"], [.hex, .ptr, .size, .int])     // set_maximum; the protection is the 5th
        set(["mach_vm_map_trap"], [.hex, .ptr, .size, .hex])         // mask; flags and protection come after
        set(["mach_port_allocate_trap"], [.hex, .portRight, .ptr])
        set(["mach_port_deallocate_trap", "mach_port_destroy_trap"], [.hex, .hex])
        set(["mach_port_mod_refs_trap"], [.hex, .hex, .portRight, .int32])
        set(["mach_port_insert_right_trap"], [.hex, .hex, .hex, .hex])
        set(["mach_port_insert_member_trap", "mach_port_extract_member_trap"], [.hex, .hex, .hex])   // task, port, set
        set(["mach_port_construct_trap"], [.hex, .ptr, .hex, .ptr])                                    // task, options, context, name out
        set(["mach_port_destruct_trap"], [.hex, .hex, .int32, .hex])                                   // task, name, srdelta, guard
        set(["mach_port_get_attributes_trap"], [.hex, .hex, .int, .ptr])                               // task, name, flavor, info
        set(["mach_port_request_notification_trap"], [.hex, .hex, .machNotify, .uint])                 // task, name, msgid, sync
        set(["mk_timer_arm_leeway"], [.hex, .hex, .uint, .uint])                                       // timer, flags, deadline, leeway
        set(["iokit_user_client"], [.hex, .int, .hex, .hex])                                           // connection, trap index, p1, p2
        set(["work_interval_ctl"], [.int, .hex, .ptr, .size])                                          // operation, id, arg, len
        set(["pthread_fchdir"], [.fd])
        set(["mac_syscall"], [.macPolicy, .int, .ptr])                                                 // policy name, call, arg
        set(["necp_client_action"], [.fd, .necpAction, .ptr, .size])                                   // fd, action, client id, id length
        set(["channel_sync"], [.fd, .channelSyncMode, .channelSyncFlags])
        set(["disable_threadsignal"], [.int])
        set(["kern_mach_vm_purgable_control_trap", "mach_vm_purgable_control_trap"], [.hex, .ptr, .purgable, .ptr])
        set(["mach_port_guard_trap"], [.hex, .hex, .hex, .int])
        set(["mach_port_unguard_trap"], [.hex, .hex, .hex])
        set(["mach_port_type_trap"], [.hex, .hex, .ptr])
        set(["mach_generate_activity_id"], [.hex, .int, .ptr])
        set(["mk_timer_destroy"], [.hex])
        set(["mk_timer_create"], [])
        set(["thread_selfcounts"], [.int, .ptr, .size])
        set(["persona"], [.personaOp, .hex, .ptr, .ptr])
        set(["gettimeofday"], [.ptr, .ptr, .ptr])
        set(["iopolicysys"], [.iopolCmd, .ptr])
        set(["gettid"], [.ptr, .ptr])
        set(["kdebug_typefilter"], [.ptr, .ptr])
        set(["semwait_signal"], [.hex, .hex, .int, .int])
        set(["task_name_for_pid", "task_for_pid", "task_read_for_pid", "task_inspect_for_pid"], [.hex, .int32, .ptr])
        set(["pid_for_task"], [.hex, .ptr])
        set(["kqueue_workloop_ctl"], [.workloopCmd, .hex, .ptr, .size])
        set(["getaudit_addr", "setaudit_addr"], [.ptr, .size])
        set(["fileport_makefd"], [.hex])
        set(["fileport_makeport"], [.fd, .ptr])
        set(["coalition"], [.coalitionOp, .ptr, .hex])
        set(["coalition_info"], [.coalitionInfo, .ptr, .ptr, .ptr])
        set(["memorystatus_control"], [.memorystatusCmd, .int32, .hex, .ptr])
        set(["bsdthread_create"], [.ptr, .ptr, .ptr, .ptr])
        set(["bsdthread_terminate"], [.ptr, .size, .hex, .hex])
        set(["pipe"], [])
        set(["mach_vm_reclaim_update_kernel_accounting_trap"], [.ptr, .ptr])
        set(["swtch_pri", "swtch"], [.int])
        set(["thread_switch"], [.hex, .int, .uint])
        return s
    }()

    /// The signature for a name, ignoring a _nocancel suffix the table doesn't list.
    static func signature(_ name: String) -> [Arg]? {
        signatures[name] ?? (name.hasSuffix("_nocancel") ? signatures[String(name.dropLast(9))] : nil)
    }

    static func fill(_ r: inout SyscallRecord) {
        if let a = r.args {
            r.argValues = special(r.name, a, paths: r.paths) ?? {
                let sig = signature(r.name)
                // Path arguments take the looked-up paths in order. O_CREAT looks its path up twice: a repeat is one.
                var paths = r.paths.enumerated().filter { $0.offset == 0 || r.paths[$0.offset - 1] != $0.element }.map(\.element)[...]
                return (0..<min(sig?.count ?? a.count, a.count)).map { i -> String in
                    if sig?[i] == .path, let p = paths.popFirst() { return quote(p) }
                    return arg(a[i], sig?[i])
                }
            }()
        } else {
            r.argValues = ["…"]
        }
        r.expected = false
        switch r.state {
        case .inProgress:
            r.resultText = "(still in the kernel)"
            r.failed = false
        case .done, .entryMissed:
            if r.mach && portTraps.contains(r.name) {
                // These return a port name, not a kern_return (seen live: host_self_trap = 0x1d03).
                r.failed = false
                r.resultText = r.error == 0 ? "MACH_PORT_NULL" : "port 0x" + String(UInt32(truncatingIfNeeded: r.error), radix: 16)
            } else if r.mach {
                let kr = Int32(truncatingIfNeeded: r.error)
                // A timeout the caller asked for (a polling mach_msg, semaphore_timedwait) is how the call is
                // used, not a failure: counting it flooded "Errors only" in a live Finder trace.
                r.expected = machTimeouts.contains(kr)
                r.failed = kr != 0 && !r.expected
                r.resultText = kr == 0 ? "KERN_SUCCESS" : machError(kr)
            } else if r.error == 0 {
                r.failed = false
                r.resultText = result(r)
                if r.name == "ulock_wake", Int32(truncatingIfNeeded: r.ret) == -ENOENT {
                    // ULF_NO_ERRNO: -ENOENT in the return value, the lock had no waiter to wake.
                    r.expected = true
                    r.resultText += ": nobody was waiting"
                }
            } else if r.name == "psynch_cvwait", r.error > 0 {
                // The errno is the low byte; ECVCLEARED / ECVPREPOST ride above it (seen: 316 = ETIMEDOUT|ECVCLEARED
                // on CVDisplayLink's every frame). libpthread turns ETIMEDOUT into pthread_cond_timedwait's timeout
                // and EINTR into a spurious wakeup: neither is a failure the caller sees.
                let e = r.error & 0xff, extra = UInt64(r.error) & ~0xff
                r.failed = e != Int64(ETIMEDOUT) && e != Int64(EINTR)
                r.expected = !r.failed
                r.resultText = errnoText(e) + (extra == 0 ? "" : " | " + SyscallFlags.bits(extra, SyscallFlags.psynchErrorBits))
            } else if let answer = answer(r) {
                r.failed = false
                r.expected = true
                r.resultText = "-1 " + (errnoNames[Int(r.error)] ?? "errno \(r.error)") + ": " + answer
            } else {
                // EJUSTRETURN and ERESTART are the kernel's own bookkeeping, not failures the process sees.
                r.failed = r.error > 0
                r.resultText = errnoText(r.error)
            }
        }
    }

    /// An errno that answers the question the call is used to ask, in place of strerror's text where that
    /// misleads ("Invalid argument" for "not a symlink"). Seen in an idle PDF Expert, every few seconds:
    /// FileManager's createDirectory(withIntermediateDirectories:) is mkdir and ignore EEXIST at every level
    /// (libc's _mkpath); destinationOfSymbolicLink is readlink, EINVAL on anything that isn't a link; Foundation
    /// asks gettid for the thread's own uid and gid, ESRCH when it has none, then reads the process's.
    static func answer(_ r: SyscallRecord) -> String? {
        let base = r.name.hasSuffix("_nocancel") ? String(r.name.dropLast(9)) : r.name
        switch (base, Int32(truncatingIfNeeded: r.error)) {
        case ("mkdir", EEXIST), ("mkdirat", EEXIST): return "already exists"
        case ("readlink", EINVAL), ("readlinkat", EINVAL): return "not a symlink"
        case ("gettid", ESRCH): return "no identity of its own (the process's applies)"
        default: return nil
        }
    }

    /// What a successful return value is, from each call's man page.
    enum Returns { case fd, bytes, pid, uid, gid, threadID, offset, address, count(String), mask, priority, bool, length, waiters, negErrno, sequence }
    static let returns: [String: Returns] = {
        var t: [String: Returns] = [:]
        func set(_ names: [String], _ k: Returns) { for n in names { t[n] = k; t[n + "_nocancel"] = k } }
        set(["open", "openat", "dup", "dup2", "dup3", "socket", "accept", "kqueue", "guarded_kqueue_np", "guarded_open_np",
             "guarded_open_dprotected_np", "open_dprotected_np", "openat_dprotected_np", "openbyid_np", "fhopen", "shm_open",
             "fileport_makefd", "necp_open", "necp_session_open", "peeloff"], .fd)
        set(["read", "write", "pread", "pwrite", "readv", "writev", "preadv", "pwritev", "recvfrom", "sendto", "recvmsg", "sendmsg",
             "getxattr", "fgetxattr", "listxattr", "flistxattr", "readlink", "readlinkat", "freadlink", "getdirentries64",
             "proc_info", "proc_info_extended_id", "guarded_write_np", "guarded_pwrite_np", "guarded_writev_np"], .bytes)
        set(["getpid", "getppid", "fork", "vfork", "wait4", "getpgrp", "getpgid", "getsid", "setsid"], .pid)
        set(["getuid", "geteuid"], .uid)
        set(["getgid", "getegid"], .gid)
        set(["thread_selfid", "gettid"], .threadID)
        set(["lseek"], .offset)
        set(["mmap", "shmat", "bsdthread_create"], .address)
        set(["kevent", "kevent64", "kevent_qos", "kevent_id"], .count("event"))
        set(["poll", "select", "pselect"], .count("ready descriptor"))
        set(["getfsstat", "getfsstat64"], .count("filesystem"))
        set(["getattrlistbulk"], .count("entry"))
        set(["recvmsg_x", "sendmsg_x"], .count("message"))
        set(["getgroups"], .count("group"))
        set(["getdtablesize"], .count("descriptor"))
        set(["umask"], .mask)
        set(["getpriority"], .priority)
        set(["issetugid"], .bool)
        set(["fpathconf", "pathconf"], .length)
        set(["fsgetpath"], .bytes)
        // bsd/kern/sys_ulock.c: wait returns the waiters left; with ULF_NO_ERRNO both return -errno instead of failing.
        set(["ulock_wait", "ulock_wait2"], .waiters)
        set(["ulock_wake"], .negErrno)
        // libpthread's kern_synch.c: the kernel's updated sequence word for the lock or condition variable.
        set(["psynch_mutexwait", "psynch_mutexdrop", "psynch_cvwait", "psynch_cvsignal", "psynch_cvbroad", "psynch_rw_rdlock",
             "psynch_rw_wrlock", "psynch_rw_unlock"], .sequence)
        return t
    }()

    /// A successful result where the call says what it is.
    private static func result(_ r: SyscallRecord) -> String {
        let base = r.name.hasSuffix("_nocancel") ? String(r.name.dropLast(9)) : r.name
        if base == "fcntl", let a = r.args, a.count > 1 {
            switch Int32(truncatingIfNeeded: a[1]) {
            case F_GETFL: return openFlags(Int32(truncatingIfNeeded: r.ret))
            case F_GETFD: return SyscallFlags.bits(r.ret, [(UInt64(FD_CLOEXEC), "FD_CLOEXEC")])
            case F_DUPFD, F_DUPFD_CLOEXEC: return "fd \(Int32(truncatingIfNeeded: r.ret))"
            case F_GETOWN: return "pid \(Int32(truncatingIfNeeded: r.ret))"
            default: break
            }
        }
        if base == "pipe" { return "fds [\(Int32(truncatingIfNeeded: r.ret)), \(Int32(truncatingIfNeeded: r.ret1))]" }
        let v = wideReturns.contains(base) ? wide(r) : r.ret
        let i = Int64(Int32(truncatingIfNeeded: v))
        switch returns[base] {
        case .fd: return "fd \(i)"
        case .bytes: return v == 1 ? "1 byte" : "\(Int64(bitPattern: v)) bytes"
        case .pid: return i == 0 && (base == "fork" || base == "vfork") ? "0 (in the child)" : "pid \(i)"
        case .uid: return "uid \(UInt32(truncatingIfNeeded: v))"
        case .gid: return "gid \(UInt32(truncatingIfNeeded: v))"
        case .threadID: return "thread \(v)"
        case .offset: return "offset \(Int64(bitPattern: v))"
        case .address: return "0x" + String(v, radix: 16)
        case .count(let what): return "\(i) " + (i == 1 ? what : what.hasSuffix("y") ? what.dropLast() + "ies" : what + "s")
        case .mask: return "old mask 0" + String(v & 0o777, radix: 8)
        case .priority: return "priority \(i)"
        case .bool: return v == 0 ? "0 (false)" : "1 (true)"
        case .length: return "\(i)"
        case .waiters:
            if i < 0 { return "\(i) (\(errnoNames[Int(-i)] ?? "errno \(-i)"))" }
            return i == 1 ? "1 other waiter" : "\(i) other waiters"
        case .negErrno: return i < 0 ? "\(i) (\(errnoNames[Int(-i)] ?? "errno \(-i)"))" : "\(i)"
        case .sequence: return "seq 0x" + String(UInt32(truncatingIfNeeded: v), radix: 16)
        case nil: return value(v)
        }
    }

    /// Calls returning a 64-bit value (user_addr_t, off_t, user_ssize_t in syscalls.master).
    static let wideReturns: Set<String> = ["mmap", "bsdthread_create", "lseek", "read", "write", "pread", "pwrite", "readv", "writev", "preadv", "pwritev",
                                           "recvfrom", "sendto", "recvmsg", "sendmsg", "recvmsg_x", "sendmsg_x", "getxattr", "fgetxattr",
                                           "listxattr", "flistxattr", "getdirentries64", "sendfile"]
    static func wide(_ r: SyscallRecord) -> UInt64 { (r.ret & 0xffff_ffff) | r.ret1 << 32 }

    /// The path as the kernel looked it up. After a symlink that is the link's target (with the rest of the
    /// path), not the string the caller passed: /etc/hosts shows as "private/etc/hosts", since /etc is a
    /// relative symlink to private/etc.
    static func quote(_ p: String) -> String { "\"" + p + "\"" }

    /// Names for the arguments `fill` shows: per command where a call's decoding depends on its first argument,
    /// else as xnu declares them (SyscallArgNames). Kernel and kdebug names differ a little: kdebug drops the sys_
    /// prefix (sys_fcntl) and Mach trap names may or may not end in _trap (mk_timer_arm, struct
    /// mk_timer_arm_trap_args; mach_port_allocate_trap, struct _kernelrpc_mach_port_allocate_args).
    static func argNames(_ r: SyscallRecord) -> [String] {
        let base = r.name.hasSuffix("_nocancel") ? String(r.name.dropLast(9)) : r.name
        let a = r.args ?? []
        switch base {
        case "bsdthread_ctl": if let first = a.first, let n = SyscallFlags.bsdthreadCtlNames(first) { return n }
        case "workq_kernreturn": if let first = a.first, let n = SyscallFlags.workqKernreturnNames(first) { return n }
        case "mach_msg2_trap": return ["msg", "options", "header"]
        default: break
        }
        if r.mach {
            let t = SyscallArgNames.mach
            // trace.codes calls a few traps kern_... (kern_mach_vm_purgable_control_trap).
            let b = base.hasPrefix("kern_") ? String(base.dropFirst(5)) : base
            return t[b] ?? t[b + "_trap"] ?? (b.hasSuffix("_trap") ? t[String(b.dropLast(5))] : nil) ?? []
        }
        let t = SyscallArgNames.bsd
        return t[r.name] ?? t[base] ?? t["sys_" + base] ?? t["__" + base] ?? []
    }

    /// Calls `special` formats itself (so they need no signature).
    static let specialNames: Set<String> = ["open", "openat", "fcntl", "setsockopt", "getsockopt", "proc_info", "proc_info_extended_id",
                                            "mach_msg2_trap", "bsdthread_ctl", "workq_kernreturn"]

    /// Calls whose arguments depend on each other.
    private static func special(_ name: String, _ a: [UInt64], paths: [String]) -> [String]? {
        let base = name.hasSuffix("_nocancel") ? String(name.dropLast(9)) : name
        switch base {
        case "open" where a.count >= 3:
            // The mode only matters with O_CREAT.
            let f = Int32(truncatingIfNeeded: a[1])
            return [paths.first.map(quote) ?? arg(a[0], .ptr), openFlags(f)] + (f & O_CREAT != 0 ? [arg(a[2], .mode)] : [])
        case "openat" where a.count >= 4:
            let f = Int32(truncatingIfNeeded: a[2])
            return [arg(a[0], .dirfd), paths.first.map(quote) ?? arg(a[1], .ptr), openFlags(f)] + (f & O_CREAT != 0 ? [arg(a[3], .mode)] : [])
        case "fcntl" where a.count >= 3:
            return [arg(a[0], .fd), SyscallFlags.one(a[1], SyscallFlags.fcntlCmds)] + (SyscallFlags.fcntlArg(cmd: a[1], a[2]).map { [$0] } ?? [])
        case "setsockopt", "getsockopt":
            guard a.count >= 4 else { return nil }
            let (level, opt) = SyscallFlags.sockopt(level: a[1], a[2])
            return [arg(a[0], .fd), level, opt, arg(a[3], .ptr)]
        case "proc_info", "proc_info_extended_id":
            guard a.count >= 4 else { return nil }
            // (call, pid, flavor, arg): flavors are named for PROC_INFO_CALL_PIDINFO.
            let flavor = a[0] == 2 ? SyscallFlags.one(a[2], SyscallFlags.pidInfoFlavors) : "\(a[2])"
            return [SyscallFlags.one(a[0], SyscallFlags.procInfoCalls), "\(Int32(truncatingIfNeeded: a[1]))", flavor, value(a[3])]
        case "mach_msg2_trap":
            return SyscallFlags.machMsg2(a)
        case "bsdthread_ctl":
            return SyscallFlags.bsdthreadCtl(a)
        case "workq_kernreturn":
            return SyscallFlags.workqKernreturn(a)
        default:
            return nil
        }
    }


    static func arg(_ v: UInt64, _ kind: Arg?) -> String {
        typealias F = SyscallFlags
        switch kind {
        case .fd: return "\(Int32(truncatingIfNeeded: v))"
        case .dirfd: return Int32(truncatingIfNeeded: v) == -2 ? "AT_FDCWD" : "\(Int32(truncatingIfNeeded: v))"
        case .int: return "\(Int64(bitPattern: v))"
        case .int32: return "\(Int32(truncatingIfNeeded: v))"
        case .uint, .size: return "\(v)"
        case .hex, .ptr, .path: return v == 0 ? (kind == .hex ? "0" : "NULL") : "0x" + String(v, radix: 16)
        case .oflags: return openFlags(Int32(truncatingIfNeeded: v))
        case .mode: return "0" + String(v & 0o7777, radix: 8)
        case .signal: return signalName(Int32(truncatingIfNeeded: v))
        case .prot: return F.bits(v, F.prot, zero: "PROT_NONE")
        case .vmProt: return F.bits(v, F.prot, zero: "VM_PROT_NONE")
        case .mapFlags: return F.bits(v, F.mapFlags, zero: "0")
        case .madvise: return F.one(v, F.madvise)
        case .msync: return F.bits(v, F.msync)
        case .vmFlags: return F.vmFlagsText(v)
        case .access: return F.bits(v, F.access, zero: "F_OK")
        case .atFlags: return F.bits(v, F.atFlags)
        case .whence: return F.one(v, F.whence)
        case .flock: return F.bits(v, F.flock)
        case .ioctl: return F.ioctl(v)
        case .domain: return F.one(v, F.domains)
        case .sockType: return F.one(v, F.sockTypes)
        case .proto: return F.one(v, F.protocols)
        case .msgFlags: return F.bits(v, F.msgFlags)
        case .shutdownHow: return F.one(v, F.shutdownHow)
        case .sigHow: return F.one(v, F.sigHow)
        case .ulock: return F.ulock(v)
        case .workqOp: return F.one(v, F.workqOps)
        case .csops: return F.one(v, F.csops)
        case .procInfoCall: return F.one(v, F.procInfoCalls)
        case .portRight: return F.one(v, F.portRights)
        case .machNotify: return F.one(v, F.machNotifications)
        case .chflags: return F.bits(v, F.chflags)
        case .prioWhich: return F.one(v, F.prioWhich)
        case .rusageWho: return F.one(UInt64(bitPattern: Int64(Int32(truncatingIfNeeded: v))), F.rusageWho)
        case .rlimit: return F.one(v, F.rlimits)
        case .waitOptions: return F.bits(v, F.waitOptions)
        case .snapshotOp: return F.one(v, F.snapshotOps)
        case .purgable: return F.one(v, F.purgableControls)
        case .personaOp: return F.one(v, F.personaOps)
        case .iopolCmd: return F.one(v, F.iopolCmds)
        case .workloopCmd: return F.one(v, F.workloopCmds)
        case .coalitionOp: return F.one(v, F.coalitionOps)
        case .coalitionInfo: return F.one(v, F.coalitionInfos)
        case .memorystatusCmd: return F.one(v, F.memorystatusCmds)
        case .machOptions: return F.bits(v, F.machOptions)
        case .necpAction: return F.one(v, F.necpClientActions)
        case .channelSyncMode: return F.one(v, F.channelSyncModes)
        case .channelSyncFlags: return F.bits(v, F.channelSyncFlags)
        case .macPolicy: return SharedCacheString.read(v).map(quote) ?? arg(v, .ptr)
        case nil: return value(v)
        }
    }

    /// Unknown argument or return value: small numbers in decimal, negatives signed, the rest in hex.
    static func value(_ v: UInt64) -> String {
        let s = Int64(bitPattern: v)
        if s < 0 && s > -4096 { return "\(s)" }
        return v < 1 << 20 ? "\(v)" : "0x" + String(v, radix: 16)
    }

    static func errnoText(_ e: Int64) -> String {
        switch e {
        case -1: return "ERESTART"
        case -2: return "EJUSTRETURN"
        default:
            let name = errnoNames[Int(e)] ?? "errno \(e)"
            return "-1 \(name) (\(String(cString: strerror(Int32(truncatingIfNeeded: e)))))"
        }
    }

    /// The symbolic name where known (from the SDK's <mach/message.h> and <mach/kern_return.h>), else the
    /// hex code with mach_error_string's text.
    static func machError(_ kr: Int32) -> String {
        if let n = machNames[kr] { return n }
        return "0x" + String(UInt32(bitPattern: kr), radix: 16) + " " + String(cString: mach_error_string(kr))
    }

    static let portTraps: Set<String> = ["mach_reply_port", "thread_self_trap", "task_self_trap", "host_self_trap",
                                         "thread_get_special_reply_port", "mk_timer_create"]
    static let machTimeouts: Set<Int32> = [0x10004003, 0x10000004, 49]   // MACH_RCV/SEND_TIMED_OUT, KERN_OPERATION_TIMED_OUT

    static let machNames: [Int32: String] = {
        var m: [Int32: String] = [
            0x10000001: "MACH_SEND_IN_PROGRESS", 0x10000002: "MACH_SEND_INVALID_DATA", 0x10000003: "MACH_SEND_INVALID_DEST",
            0x10000004: "MACH_SEND_TIMED_OUT", 0x10000005: "MACH_SEND_INVALID_VOUCHER", 0x10000007: "MACH_SEND_INTERRUPTED",
            0x10000008: "MACH_SEND_MSG_TOO_SMALL", 0x10000009: "MACH_SEND_INVALID_REPLY", 0x1000000a: "MACH_SEND_INVALID_RIGHT",
            0x1000000b: "MACH_SEND_INVALID_NOTIFY", 0x1000000c: "MACH_SEND_INVALID_MEMORY", 0x1000000d: "MACH_SEND_NO_BUFFER",
            0x1000000e: "MACH_SEND_TOO_LARGE", 0x1000000f: "MACH_SEND_INVALID_TYPE", 0x10000010: "MACH_SEND_INVALID_HEADER",
            0x10000011: "MACH_SEND_INVALID_TRAILER", 0x10000012: "MACH_SEND_INVALID_CONTEXT", 0x10000013: "MACH_SEND_INVALID_OPTIONS",
            0x10000015: "MACH_SEND_INVALID_RT_OOL_SIZE", 0x10000016: "MACH_SEND_NO_GRANT_DEST", 0x10000017: "MACH_SEND_MSG_FILTERED",
            0x10000018: "MACH_SEND_AUX_TOO_SMALL", 0x10000019: "MACH_SEND_AUX_TOO_LARGE",
            0x10004001: "MACH_RCV_IN_PROGRESS", 0x10004002: "MACH_RCV_INVALID_NAME", 0x10004003: "MACH_RCV_TIMED_OUT",
            0x10004004: "MACH_RCV_TOO_LARGE", 0x10004005: "MACH_RCV_INTERRUPTED", 0x10004006: "MACH_RCV_PORT_CHANGED",
            0x10004007: "MACH_RCV_INVALID_NOTIFY", 0x10004008: "MACH_RCV_INVALID_DATA", 0x10004009: "MACH_RCV_PORT_DIED",
            0x1000400a: "MACH_RCV_IN_SET", 0x1000400b: "MACH_RCV_HEADER_ERROR", 0x1000400c: "MACH_RCV_BODY_ERROR",
            0x1000400d: "MACH_RCV_INVALID_TYPE", 0x1000400e: "MACH_RCV_SCATTER_SMALL", 0x1000400f: "MACH_RCV_INVALID_TRAILER",
            0x10004011: "MACH_RCV_IN_PROGRESS_TIMED", 0x10004012: "MACH_RCV_INVALID_REPLY", 0x10004013: "MACH_RCV_INVALID_ARGUMENTS",
        ]
        let kern = ["KERN_SUCCESS", "KERN_INVALID_ADDRESS", "KERN_PROTECTION_FAILURE", "KERN_NO_SPACE", "KERN_INVALID_ARGUMENT",
                    "KERN_FAILURE", "KERN_RESOURCE_SHORTAGE", "KERN_NOT_RECEIVER", "KERN_NO_ACCESS", "KERN_MEMORY_FAILURE",
                    "KERN_MEMORY_ERROR", "KERN_ALREADY_IN_SET", "KERN_NOT_IN_SET", "KERN_NAME_EXISTS", "KERN_ABORTED",
                    "KERN_INVALID_NAME", "KERN_INVALID_TASK", "KERN_INVALID_RIGHT", "KERN_INVALID_VALUE", "KERN_UREFS_OVERFLOW",
                    "KERN_INVALID_CAPABILITY", "KERN_RIGHT_EXISTS", "KERN_INVALID_HOST", "KERN_MEMORY_PRESENT",
                    "KERN_MEMORY_DATA_MOVED", "KERN_MEMORY_RESTART_COPY", "KERN_INVALID_PROCESSOR_SET", "KERN_POLICY_LIMIT",
                    "KERN_INVALID_POLICY", "KERN_INVALID_OBJECT", "KERN_ALREADY_WAITING", "KERN_DEFAULT_SET",
                    "KERN_EXCEPTION_PROTECTED", "KERN_INVALID_LEDGER", "KERN_INVALID_MEMORY_CONTROL", "KERN_INVALID_SECURITY",
                    "KERN_NOT_DEPRESSED", "KERN_TERMINATED", "KERN_LOCK_SET_DESTROYED", "KERN_LOCK_UNSTABLE", "KERN_LOCK_OWNED",
                    "KERN_LOCK_OWNED_SELF", "KERN_SEMAPHORE_DESTROYED", "KERN_RPC_SERVER_TERMINATED", "KERN_RPC_TERMINATE_ORPHAN",
                    "KERN_RPC_CONTINUE_ORPHAN", "KERN_NOT_SUPPORTED", "KERN_NODE_DOWN", "KERN_NOT_WAITING",
                    "KERN_OPERATION_TIMED_OUT", "KERN_CODESIGN_ERROR", "KERN_POLICY_STATIC", "KERN_INSUFFICIENT_BUFFER_SIZE",
                    "KERN_DENIED", "KERN_MISSING_KC", "KERN_INVALID_KC", "KERN_NOT_FOUND", "KERN_INVALID_GUARD_OBJECT_SLOT"]
        for (i, n) in kern.enumerated() { m[Int32(i)] = n }
        return m
    }()

    static func openFlags(_ f: Int32) -> String {
        var parts: [String] = []
        switch f & O_ACCMODE {
        case O_RDONLY: parts.append("O_RDONLY")
        case O_WRONLY: parts.append("O_WRONLY")
        case O_RDWR: parts.append("O_RDWR")
        default: parts.append("O_ACCMODE")
        }
        let named: [(Int32, String)] = [
            (O_NONBLOCK, "O_NONBLOCK"), (O_APPEND, "O_APPEND"), (O_SHLOCK, "O_SHLOCK"), (O_EXLOCK, "O_EXLOCK"),
            (O_NOFOLLOW, "O_NOFOLLOW"), (O_CREAT, "O_CREAT"), (O_TRUNC, "O_TRUNC"), (O_EXCL, "O_EXCL"),
            (O_EVTONLY, "O_EVTONLY"), (O_NOCTTY, "O_NOCTTY"), (O_DIRECTORY, "O_DIRECTORY"), (O_SYMLINK, "O_SYMLINK"),
            (O_CLOEXEC, "O_CLOEXEC"), (O_NOFOLLOW_ANY, "O_NOFOLLOW_ANY"),
        ]
        var rest = f & ~O_ACCMODE
        for (bit, n) in named where rest & bit != 0 { parts.append(n); rest &= ~bit }
        if rest != 0 { parts.append("0x" + String(UInt32(bitPattern: rest), radix: 16)) }
        return parts.joined(separator: "|")
    }

    static func signalName(_ s: Int32) -> String {
        guard s > 0, s < NSIG else { return "\(s)" }
        // sys_signame is imported as a 32-element tuple.
        let p = withUnsafePointer(to: sys_signame) {
            $0.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: Int(NSIG)) { $0[Int(s)] }
        }
        guard let p else { return "\(s)" }
        return "SIG" + String(cString: p).uppercased()
    }

    /// From the SDK's <sys/errno.h>.
    static let errnoNames: [Int: String] = [1: "EPERM", 2: "ENOENT", 3: "ESRCH", 4: "EINTR", 5: "EIO", 6: "ENXIO", 7: "E2BIG", 8: "ENOEXEC", 9: "EBADF", 10: "ECHILD", 11: "EDEADLK", 12: "ENOMEM", 13: "EACCES", 14: "EFAULT", 15: "ENOTBLK", 16: "EBUSY", 17: "EEXIST", 18: "EXDEV", 19: "ENODEV", 20: "ENOTDIR", 21: "EISDIR", 22: "EINVAL", 23: "ENFILE", 24: "EMFILE", 25: "ENOTTY", 26: "ETXTBSY", 27: "EFBIG", 28: "ENOSPC", 29: "ESPIPE", 30: "EROFS", 31: "EMLINK", 32: "EPIPE", 33: "EDOM", 34: "ERANGE", 35: "EAGAIN", 36: "EINPROGRESS", 37: "EALREADY", 38: "ENOTSOCK", 39: "EDESTADDRREQ", 40: "EMSGSIZE", 41: "EPROTOTYPE", 42: "ENOPROTOOPT", 43: "EPROTONOSUPPORT", 44: "ESOCKTNOSUPPORT", 45: "ENOTSUP", 46: "EPFNOSUPPORT", 47: "EAFNOSUPPORT", 48: "EADDRINUSE", 49: "EADDRNOTAVAIL", 50: "ENETDOWN", 51: "ENETUNREACH", 52: "ENETRESET", 53: "ECONNABORTED", 54: "ECONNRESET", 55: "ENOBUFS", 56: "EISCONN", 57: "ENOTCONN", 58: "ESHUTDOWN", 59: "ETOOMANYREFS", 60: "ETIMEDOUT", 61: "ECONNREFUSED", 62: "ELOOP", 63: "ENAMETOOLONG", 64: "EHOSTDOWN", 65: "EHOSTUNREACH", 66: "ENOTEMPTY", 67: "EPROCLIM", 68: "EUSERS", 69: "EDQUOT", 70: "ESTALE", 71: "EREMOTE", 72: "EBADRPC", 73: "ERPCMISMATCH", 74: "EPROGUNAVAIL", 75: "EPROGMISMATCH", 76: "EPROCUNAVAIL", 77: "ENOLCK", 78: "ENOSYS", 79: "EFTYPE", 80: "EAUTH", 81: "ENEEDAUTH", 82: "EPWROFF", 83: "EDEVERR", 84: "EOVERFLOW", 85: "EBADEXEC", 86: "EBADARCH", 87: "ESHLIBVERS", 88: "EBADMACHO", 89: "ECANCELED", 90: "EIDRM", 91: "ENOMSG", 92: "EILSEQ", 93: "ENOATTR", 94: "EBADMSG", 95: "EMULTIHOP", 96: "ENODATA", 97: "ENOLINK", 98: "ENOSR", 99: "ENOSTR", 100: "EPROTO", 101: "ETIME", 102: "EOPNOTSUPP", 103: "ENOPOLICY", 104: "ENOTRECOVERABLE", 105: "EOWNERDEAD", 106: "EQFULL"]
}

/// Per-syscall totals, as `strace -c` and Instruments' summary.
struct SyscallSummaryRow: Identifiable, Sendable {
    var id: String { name }
    let name: String
    var calls = 0
    var errors = 0
    var totalNanos: UInt64 = 0
    var maxNanos: UInt64 = 0
    /// Of the calls whose time on a CPU was measured (SyscallRecord.cpu): that time, and the rest of their duration.
    var cpuNanos: UInt64 = 0
    var offNanos: UInt64 = 0
    var timed = 0
    var avgNanos: UInt64 { calls > 0 ? totalNanos / UInt64(calls) : 0 }

    static func build(_ records: [SyscallRecord]) -> [SyscallSummaryRow] {
        var rows: [String: SyscallSummaryRow] = [:]
        for r in records where !r.isLaunchMarker {
            var s = rows[r.name] ?? SyscallSummaryRow(name: r.name)
            s.calls += 1
            if r.failed { s.errors += 1 }
            if let d = r.duration { s.totalNanos += d; s.maxNanos = max(s.maxNanos, d) }
            if let d = r.duration, let c = r.cpu { s.cpuNanos += min(c, d); s.offNanos += d - min(c, d); s.timed += 1 }
            rows[r.name] = s
        }
        return rows.values.sorted { $0.totalNanos > $1.totalNanos }
    }
}

/// One thread's process and name (ThreadOwners).
struct ThreadInfo: Codable, Hashable, Sendable {
    var pid: Int32
    /// pthread_setname_np's name; empty when it has none.
    var name: String
    /// The process's first thread (lowest id): its main thread.
    var main: Bool
}

/// Which process each thread belongs to, and its name, from every process's thread ids (proc_pidinfo
/// PROC_PIDLISTTHREADIDS, not in the SDK's headers) and PROC_PIDTHREADID64INFO. Root reads every process's
/// (~13 ms for 580 processes); another user only its own.
enum ThreadOwners {
    /// One process's thread ids, as the kernel lists them now.
    static func threads(of pid: Int32) -> [UInt64] {
        var buf = [UInt64](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBytes { proc_pidinfo(pid, 28, 0, $0.baseAddress, Int32($0.count)) }   // PROC_PIDLISTTHREADIDS
        return n > 0 ? Array(buf.prefix(Int(n) / 8)) : []
    }

    static func lookup(_ tids: Set<UInt64>) -> [UInt64: ThreadInfo] {
        guard !tids.isEmpty else { return [:] }
        let PROC_PIDLISTTHREADIDS: Int32 = 28
        var out: [UInt64: ThreadInfo] = [:]
        var buf = [UInt64](repeating: 0, count: 4096)
        for pid in NativeMach.allPids() where pid > 0 {
            let n = buf.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTTHREADIDS, 0, $0.baseAddress, Int32($0.count)) }
            guard n > 0 else { continue }
            let ids = buf.prefix(Int(n) / 8)
            let first = ids.min()
            for t in ids where tids.contains(t) {
                var info = proc_threadinfo()
                let size = Int32(MemoryLayout<proc_threadinfo>.size)
                let name = proc_pidinfo(pid, PROC_PIDTHREADID64INFO, t, &info, size) == size
                    ? withUnsafeBytes(of: info.pth_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } : ""
                out[t] = ThreadInfo(pid: pid, name: name, main: t == first)
            }
            if out.count == tids.count { break }
        }
        return out
    }
}

/// Names the traced process's threads and the process each call woke (SyscallRecord.woke → receiver). A thread's
/// id is never reused, so an answer holds for the trace; threads gone before the lookup (a worker thread that woke,
/// answered and exited within the read interval) stay unnamed.
struct ThreadLabeler {
    private var owners: [UInt64: Int32] = [:]
    private var asked: Set<UInt64> = []
    /// Process names, for the processes found.
    private(set) var names: [Int32: String] = [:]
    /// The traced process's threads: "main thread", "com.apple.NSEventThread"; unnamed ones are left out.
    private(set) var threadNames: [UInt64: String] = [:]

    /// Fills `receiver` in `recs`; returns the names of processes not named before.
    mutating func label(_ recs: inout [SyscallRecord], lookup: (Set<UInt64>) -> [UInt64: ThreadInfo]) -> [Int32: String] {
        let asked = self.asked
        let woken = Set(recs.map(\.woke).filter { $0 != 0 && !asked.contains($0) })
        let own = Set(recs.map(\.thread).filter { !asked.contains($0) })
        let want = woken.union(own)
        var new: [Int32: String] = [:]
        if !want.isEmpty {
            self.asked.formUnion(want)
            for (t, info) in lookup(want) {
                if own.contains(t) {
                    let label = info.main ? (info.name.isEmpty ? "main thread" : "main thread, " + info.name) : info.name
                    if !label.isEmpty { threadNames[t] = label }
                }
                guard woken.contains(t), info.pid > 0 else { continue }   // pid 0: a kernel thread, not a receiver
                owners[t] = info.pid
                if names[info.pid] == nil, let path = Native.path(info.pid) {
                    names[info.pid] = (path as NSString).lastPathComponent
                    new[info.pid] = names[info.pid]
                }
            }
        }
        for i in recs.indices where recs[i].woke != 0 { recs[i].receiver = owners[recs[i].woke] }
        return new
    }
}

/// The kernel's MIG routines in kobject filter index order, the numbering of the MIG trace events: libsandbox's
/// table of routine names, which it compiles sandbox profiles' kernel-mig-routine filters against. Checked on 27.2
/// against calls whose routine is known: host_info 0, mach_port_names 150, task_threads 192, task_info 195,
/// thread_info 254, mach_vm_region 320. Found by its first three names, so a table that moved still turns up; empty
/// when it isn't there (a later OS that changed it), and then routines show as numbers.
enum MIGRoutines {
    static let names: [String] = load()

    static func name(_ index: Int) -> String {
        index >= 0 && index < names.count ? names[index] : "kernel routine #\(index)"
    }

    private static func load() -> [String] {
        let path = "/usr/lib/libsandbox.1.dylib"
        guard dlopen(path, RTLD_LAZY | RTLD_LOCAL) != nil else { return [] }
        for i in 0..<_dyld_image_count() where String(cString: _dyld_get_image_name(i)) == path {
            guard let header = _dyld_get_image_header(i) else { continue }
            var size: UInt = 0
            let mh = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
            guard let base = getsectiondata(mh, "__TEXT", "__cstring", &size) else { continue }
            let text = UnsafeBufferPointer(start: base, count: Int(size))
            let anchor = Array("host_info\0host_kernel_version\0host_page_size\0".utf8)
            guard let start = find(anchor, in: text) else { continue }
            var out: [String] = []
            var p = start
            while p < text.count {
                var q = p
                while q < text.count, text[q] != 0 { q += 1 }
                let s = String(decoding: UnsafeBufferPointer(rebasing: text[p..<q]), as: UTF8.self)
                // Routine names are identifiers with lowercase in them (_mach_make_memory_entry,
                // UNDAlertCompletedWithResult_rpc); the table after it is constants in capitals, KAS_INFO_….
                func lower(_ c: UInt8) -> Bool { c >= 0x61 && c <= 0x7a }
                guard s.utf8.contains(where: lower),
                      s.utf8.allSatisfy({ lower($0) || ($0 >= 0x41 && $0 <= 0x5a) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5f })
                else { break }
                out.append(s.hasSuffix("_from_user") ? String(s.dropLast(10)) : s)
                p = q + 1
            }
            return out.count >= 300 ? out : []
        }
        return []
    }

    private static func find(_ needle: [UInt8], in hay: UnsafeBufferPointer<UInt8>) -> Int? {
        guard needle.count <= hay.count, let first = needle.first else { return nil }
        var i = 0
        while i <= hay.count - needle.count {
            if hay[i] == first, needle.indices.allSatisfy({ hay[i + $0] == needle[$0] }) { return i }
            i += 1
        }
        return nil
    }
}

/// When the traced process's threads were on a CPU, from the trace's context switches (SyscallDecoder.Run).
struct TraceCPU: Sendable {
    /// Finished runs, in the order they ended, then the ones still going at the last event.
    var runs: [SyscallDecoder.Run] = []
    var open: [SyscallDecoder.Run] = []
    /// Runs that ended before this were let go to bound memory: nothing is known about earlier stretches.
    var from: UInt64 = 0
    /// Each thread's time on a CPU over the whole trace.
    var totals: [UInt64: UInt64] = [:]
    /// False while the trace can't say (SyscallDecoder.cpuMeasured): then nothing here is shown.
    var measured = false

    static let cap = 400_000

    mutating func add(_ new: [SyscallDecoder.Run], open: [SyscallDecoder.Run], measured: Bool) {
        for r in new { totals[r.thread, default: 0] += r.end - r.start }
        runs += new
        self.open = open
        self.measured = measured
        if runs.count > Self.cap {
            let cut = runs.count - Self.cap + Self.cap / 10
            from = max(from, runs[cut - 1].end)
            runs.removeFirst(cut)
        }
    }

    /// A thread's time on a CPU so far, the run it is in included.
    func total(_ thread: UInt64) -> UInt64? {
        guard measured else { return nil }
        return (totals[thread] ?? 0) + open.lazy.filter { $0.thread == thread }.map { $0.end - $0.start }.reduce(0, +)
    }

    /// Calls `body` with each run's part inside `range`, for `threads` (none: all).
    func each(in range: ClosedRange<UInt64>, threads: Set<UInt64>, _ body: (UInt64, UInt64) -> Void) {
        for list in [runs, open] {
            for r in list where r.end > range.lowerBound && r.start < range.upperBound && (threads.isEmpty || threads.contains(r.thread)) {
                body(max(r.start, range.lowerBound), min(r.end, range.upperBound))
            }
        }
    }

    /// Time on a CPU inside `range`; nil when it isn't known for all of it.
    func time(in range: ClosedRange<UInt64>, threads: Set<UInt64>) -> UInt64? {
        guard measured, range.lowerBound >= from else { return nil }
        var sum: UInt64 = 0
        each(in: range, threads: threads) { sum += $1 - $0 }
        return sum
    }
}
