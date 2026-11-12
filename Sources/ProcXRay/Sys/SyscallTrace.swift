import Darwin
import Foundation

// Syscall trace: kdebug events from `ktrace trace --ndjson` (run by the helper, see SyscallTraceConfig),
// paired into strace-style records.
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
    var ret: UInt64 = 0
    var paths: [String] = []
    var state: State = .done

    // Display text, built once (off the main thread) so the table only reads strings.
    var argsText = ""
    var resultText = ""
    var failed = false

    var duration: UInt64? {
        guard let s = start, let e = end, e >= s else { return nil }
        return e - s
    }
    /// Sort keys for the table.
    var time: UInt64 { start ?? end ?? 0 }
    var durationKey: UInt64 { duration ?? 0 }
    var pathText: String { paths.joined(separator: "  ") }
}

/// The `ktrace --ndjson` event fields this needs. In the JSON, numbers that can exceed 2^53 are strings.
struct KdebugEvent: Sendable {
    var ts: UInt64 = 0
    var eventname: String?
    var debugid: UInt32 = 0
    var arg: [UInt64] = []
    var thread: UInt64 = 0

    var cls: UInt32 { debugid >> 24 }
    var subclass: UInt32 { (debugid >> 16) & 0xff }
    var code: Int { Int((debugid >> 2) & 0x3fff) }
    var fn: UInt32 { debugid & 3 }

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

/// Pairs entries with returns, per thread, and hangs path lookups on the call making them.
struct SyscallDecoder: Sendable {
    private struct Open: Sendable {
        var rec: SyscallRecord
        let debugBase: UInt32
    }
    private var open: [UInt64: [Open]] = [:]
    private var lookups: [UInt64: Data] = [:]
    private var nextID = 0

    /// Completed records, in the order they returned.
    mutating func feed(_ events: [KdebugEvent]) -> [SyscallRecord] {
        var out: [SyscallRecord] = []
        for e in events {
            if e.cls == 3 && e.subclass == 1 && e.code == 0x24 { lookup(e); continue }
            guard e.subclass == 0x0c, e.cls == 4 || e.cls == 1 else { continue }
            let base = e.debugid & ~3
            let mach = e.cls == 1
            switch e.fn {
            case 1:
                var r = SyscallRecord(id: nextID, start: e.ts, end: nil, thread: e.thread, mach: mach,
                                      number: e.code, name: Self.name(e.eventname, mach: mach, code: e.code))
                nextID += 1
                r.args = e.arg
                open[e.thread, default: []].append(Open(rec: r, debugBase: base))
            case 2:
                var r: SyscallRecord
                if var stack = open[e.thread], let i = stack.lastIndex(where: { $0.debugBase == base }) {
                    r = stack[i].rec
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
                let a = e.arg
                if mach {
                    r.error = Int64(Int32(truncatingIfNeeded: a.first ?? 0))
                } else {
                    r.error = Int64(bitPattern: a.first ?? 0)
                    r.ret = a.count > 1 ? a[1] : 0
                }
                SyscallFormat.fill(&r)
                out.append(r)
            default:
                continue
            }
        }
        return out
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

    private mutating func lookup(_ e: KdebugEvent) {
        let a = e.arg
        var bytes = lookups[e.thread] ?? Data()
        let words = e.fn & 1 != 0 ? a.dropFirst() : a[...]   // the first event's args[0] is the vnode id
        if e.fn & 1 != 0 { bytes = Data() }
        for w in words { withUnsafeBytes(of: w.littleEndian) { bytes.append(contentsOf: $0) } }
        guard e.fn & 2 != 0 else { lookups[e.thread] = bytes; return }
        lookups[e.thread] = nil
        let path = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        guard !path.isEmpty, var stack = open[e.thread], !stack.isEmpty else { return }
        stack[stack.count - 1].rec.paths.append(path)
        open[e.thread] = stack
    }

    static func name(_ eventName: String?, mach: Bool, code: Int) -> String {
        if let n = eventName, n.count > 4, n.hasPrefix("BSC_") || n.hasPrefix("MSC_") { return String(n.dropFirst(4)) }
        if let n = eventName, !n.isEmpty, !n.hasPrefix("0x") { return n }
        return mach ? "mach_trap_\(code)" : "syscall_\(code)"
    }
}

/// strace-style text for arguments and results.
enum SyscallFormat {
    enum Arg { case fd, dirfd, int, uint, hex, ptr, size, oflags, mode, signal }

    /// Arity and argument kinds for common calls. Others show all four raw words.
    static let signatures: [String: [Arg]] = {
        var s: [String: [Arg]] = [:]
        func set(_ names: [String], _ a: [Arg]) { for n in names { s[n] = a; s[n + "_nocancel"] = a } }
        set(["read", "write"], [.fd, .ptr, .size])
        set(["pread", "pwrite"], [.fd, .ptr, .size, .int])
        set(["readv", "writev", "preadv", "pwritev"], [.fd, .ptr, .int])
        set(["close", "fsync", "fchdir", "dup"], [.fd])
        set(["dup2"], [.fd, .fd])
        set(["open"], [.ptr, .oflags, .mode])
        set(["openat"], [.dirfd, .ptr, .oflags, .mode])
        set(["guarded_open_np"], [.ptr, .ptr, .hex, .oflags])
        set(["guarded_close_np"], [.fd, .ptr])
        set(["fcntl"], [.fd, .int, .hex])
        set(["ioctl"], [.fd, .hex, .ptr])
        set(["lseek"], [.fd, .int, .int])
        set(["fstat", "fstat64"], [.fd, .ptr])
        set(["stat", "stat64", "lstat", "lstat64", "access", "chdir", "unlink", "rmdir", "readlink"], [.ptr, .ptr, .size])
        set(["fstatat", "fstatat64"], [.dirfd, .ptr, .ptr, .hex])
        set(["unlinkat"], [.dirfd, .ptr, .hex])
        set(["mkdir"], [.ptr, .mode])
        set(["mkdirat"], [.dirfd, .ptr, .mode])
        set(["getattrlist", "setattrlist"], [.ptr, .ptr, .ptr, .size])
        set(["fgetattrlist", "fsetattrlist"], [.fd, .ptr, .ptr, .size])
        set(["getattrlistbulk"], [.fd, .ptr, .ptr, .size])
        set(["getdirentries64"], [.fd, .ptr, .size, .ptr])
        set(["fstatfs64", "fstatfs"], [.fd, .ptr])
        set(["ftruncate"], [.fd, .int])
        set(["flock"], [.fd, .int])
        set(["fchmod"], [.fd, .mode])
        set(["fchown"], [.fd, .int, .int])
        set(["fgetxattr", "fsetxattr"], [.fd, .ptr, .ptr, .size])
        set(["getxattr", "setxattr"], [.ptr, .ptr, .ptr, .size])
        set(["mmap"], [.ptr, .size, .hex, .hex])
        set(["munmap", "mprotect", "madvise", "msync"], [.ptr, .size, .hex])
        set(["socket"], [.int, .int, .int])
        set(["connect", "bind"], [.fd, .ptr, .size])
        set(["listen"], [.fd, .int])
        set(["accept"], [.fd, .ptr, .ptr])
        set(["sendto", "recvfrom"], [.fd, .ptr, .size, .hex])
        set(["sendmsg", "recvmsg"], [.fd, .ptr, .hex])
        set(["sendmsg_x", "recvmsg_x"], [.fd, .ptr, .uint, .hex])
        set(["shutdown"], [.fd, .int])
        set(["setsockopt", "getsockopt"], [.fd, .int, .int, .ptr])
        set(["select", "pselect"], [.int, .ptr, .ptr, .ptr])
        set(["poll"], [.ptr, .uint, .int])
        set(["kevent", "kevent64", "kevent_qos"], [.fd, .ptr, .int, .ptr])
        set(["kevent_id"], [.hex, .ptr, .int, .ptr])   // a workloop id, not a descriptor
        set(["kqueue", "getpid", "getppid", "getuid", "geteuid", "getgid", "getegid", "fork", "vfork", "sync", "issetugid"], [])
        set(["kill"], [.int, .signal])
        set(["__pthread_kill"], [.hex, .signal])
        set(["sigprocmask", "__pthread_sigmask"], [.int, .ptr, .ptr])
        set(["psynch_mutexwait", "psynch_mutexdrop"], [.ptr, .hex, .hex, .hex])
        set(["psynch_cvwait", "psynch_cvsignal", "psynch_cvbroad"], [.ptr, .hex, .hex, .ptr])
        set(["ulock_wait", "ulock_wait2"], [.hex, .ptr, .hex, .uint])
        set(["ulock_wake"], [.hex, .ptr, .hex])
        set(["workq_kernreturn"], [.hex, .ptr, .int, .int])
        set(["bsdthread_ctl"], [.hex, .hex, .hex, .hex])
        set(["exit"], [.int])
        set(["getentropy"], [.ptr, .size])
        set(["csops", "csops_audittoken"], [.int, .uint, .ptr, .size])
        set(["proc_info", "proc_info_extended_id"], [.int, .int, .uint, .uint])
        set(["sysctl"], [.ptr, .uint, .ptr, .ptr])
        set(["sysctlbyname"], [.ptr, .size, .ptr, .ptr])
        set(["fsgetpath"], [.ptr, .size, .ptr, .hex])
        set(["shared_region_check_np"], [.ptr])
        set(["thread_selfid", "thread_selfusage"], [])
        // Mach traps
        set(["mach_msg_trap", "mach_msg_overwrite_trap"], [.ptr, .hex, .size, .size])
        set(["mach_msg2_trap"], [.ptr, .hex, .hex, .hex])
        set(["mach_reply_port", "thread_self_trap", "task_self_trap", "host_self_trap", "thread_get_special_reply_port"], [])
        set(["semaphore_signal_trap", "semaphore_wait_trap"], [.hex])
        set(["semaphore_timedwait_trap"], [.hex, .uint, .uint])
        set(["mk_timer_arm"], [.hex, .uint])
        set(["mk_timer_cancel"], [.hex, .ptr])
        set(["mach_vm_allocate_trap", "mach_vm_deallocate_trap"], [.hex, .ptr, .size, .hex])
        set(["mach_port_deallocate_trap", "mach_port_mod_refs_trap"], [.hex, .hex, .int, .int])
        set(["swtch_pri", "swtch"], [.int])
        set(["thread_switch"], [.hex, .int, .uint])
        return s
    }()

    static func fill(_ r: inout SyscallRecord) {
        if let a = r.args {
            let sig = signatures[r.name]
            let n = sig?.count ?? a.count
            r.argsText = (0..<min(n, a.count)).map { arg(a[$0], sig?[$0]) }.joined(separator: ", ")
        } else {
            r.argsText = "…"
        }
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
                r.failed = kr != 0 && !machTimeouts.contains(kr)
                r.resultText = kr == 0 ? "KERN_SUCCESS" : machError(kr)
            } else if r.error == 0 {
                r.failed = false
                r.resultText = value(r.ret)
            } else {
                // EJUSTRETURN and ERESTART are the kernel's own bookkeeping, not failures the process sees.
                r.failed = r.error > 0
                r.resultText = errnoText(r.error)
            }
        }
    }

    static func arg(_ v: UInt64, _ kind: Arg?) -> String {
        switch kind {
        case .fd: return "\(Int32(truncatingIfNeeded: v))"
        case .dirfd: return Int32(truncatingIfNeeded: v) == -2 ? "AT_FDCWD" : "\(Int32(truncatingIfNeeded: v))"
        case .int: return "\(Int64(bitPattern: v))"
        case .uint, .size: return "\(v)"
        case .hex, .ptr: return v == 0 ? (kind == .ptr ? "NULL" : "0") : "0x" + String(v, radix: 16)
        case .oflags: return openFlags(Int32(truncatingIfNeeded: v))
        case .mode: return "0" + String(v & 0o7777, radix: 8)
        case .signal: return signalName(Int32(truncatingIfNeeded: v))
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
    var avgNanos: UInt64 { calls > 0 ? totalNanos / UInt64(calls) : 0 }

    static func build(_ records: [SyscallRecord]) -> [SyscallSummaryRow] {
        var rows: [String: SyscallSummaryRow] = [:]
        for r in records {
            var s = rows[r.name] ?? SyscallSummaryRow(name: r.name)
            s.calls += 1
            if r.failed { s.errors += 1 }
            if let d = r.duration { s.totalNanos += d; s.maxNanos = max(s.maxNanos, d) }
            rows[r.name] = s
        }
        return rows.values.sorted { $0.totalNanos > $1.totalNanos }
    }
}
