import Darwin
import Foundation

/// One activity: a descriptor's life (its open, what was done with it, its close), a burst of the same call on
/// the same target, or one call. IDs remain stable while new calls join.
struct SyscallActivity: Identifiable, Sendable {
    enum Operation: String, Sendable {
        case read = "Read", write = "Write", readWrite = "Read and write", open = "Open", list = "List directory"
        case lookup = "Look up", xattr = "Read extended attributes", metadata = "Change metadata"
        case sync = "Flush to disk", lock = "Lock"
        case rename = "Rename", remove = "Remove", mkdir = "Create directory", link = "Create link", copy = "Copy"
        case connect = "Connect", connection = "Connection", listen = "Listen", accept = "Accept connection"
        case send = "Send", receive = "Receive"
        case message = "Message", launch = "Launch", signal = "Signal", inspect = "Inspect process"
        case loadImage = "Load libraries", initializers = "Run initializers", openLibrary = "Open library (dlopen)"
        case closeLibrary = "Close library (dlclose)", symbol = "Look up symbols (dlsym)", address = "Find an address's library (dladdr)"
        case kernelCall = "Kernel call"
        case dyldSetup = "Launch setup (dyld)", mainStarts = "main() starts"
        case waits = "Waits and event polls"
    }

    /// What the build knows besides the records.
    struct Context: Sendable {
        /// The traced process.
        var pid: Int32 = 0
        /// Port names in the traced process's port space → the process holding the receive right (MachPortNames).
        var ports: [UInt32: Int32] = [:]
        var processNames: [Int32: String] = [:]
        /// Port names that lead to no other process: "task port", "IOKit connection (…)", "own port".
        var portKinds: [UInt32: String] = [:]
        /// The traced process's thread names: "main thread", "com.apple.NSEventThread".
        var threadNames: [UInt64: String] = [:]

        func process(_ pid: Int32) -> String {
            if pid == self.pid { return "itself" }
            return processNames[pid].map { "\($0) (\(pid))" } ?? "pid \(pid)"
        }

        /// Where a mach_msg2_trap send goes: "cfprefsd (412)", "Kernel: task port", "Own port", "Reply to
        /// cfprefsd (412)" for an answer to a request (its send-once right is used up by the send, so no listing
        /// finds it), or one label for all sends nothing names.
        ///
        /// The port listings first, then the call itself: the process of the thread the send woke, else a kernel
        /// object when a send-and-receive got its reply without blocking (SyscallDecoder.sched). Seen in Finder:
        /// runs of new port names (thread ports from task_threads), each asked a question or two and released
        /// within a millisecond, before any listing.
        func destination(_ port: UInt32, sendOnce: Bool = false, call r: SyscallRecord? = nil) -> String {
            if !sendOnce, let p = ports[port] { return process(p) }
            if !sendOnce, let k = portKinds[port] { return k == "own port" ? "Own port" : "Kernel: " + k }
            if let p = r?.receiver { return (sendOnce ? "Reply to " : "") + process(p) }
            if sendOnce { return "Reply (send-once)" }
            if let r, Self.answeredInKernel(r) { return "Kernel object (port gone before any listing)" }
            // One label for all of them: each is usually a new name used once, so naming the port made a one-call
            // row per send (~80 in a trace of a Shortcuts run). The call's own arguments still show the port.
            return Self.unknownDestination
        }

        static let unknownDestination = "Unknown destination (port not in any listing)"

        /// Where a mach_msg2_trap send went, for a call on its own (the Calls table): the kernel routine that handled
        /// it ("task_info (kernel)"), else as `destination` names it. nil for other calls and receives.
        func messageTarget(_ r: SyscallRecord) -> String? {
            guard r.name == "mach_msg2_trap", let a = r.args, let m = Self.messagePort(a) else { return nil }
            if let k = r.kernelRoutine { return MIGRoutines.name(k) + " (kernel)" }
            return destination(m.port, sendOnce: m.sendOnce, call: r)
        }

        /// A send-and-receive that succeeded without its thread giving up the CPU: a process's answer needs the
        /// receiver to run, so the kernel answered it.
        static func answeredInKernel(_ r: SyscallRecord) -> Bool {
            guard r.blocked == false, r.error == 0, let a = r.args, a.count > 1 else { return false }
            let both = UInt64(MACH_SEND_MSG | MACH_RCV_MSG)
            return a[1] & both == both
        }

        /// The listings and the call itself say nothing about where this send went.
        func unnamed(_ port: UInt32, sendOnce: Bool, call r: SyscallRecord) -> Bool {
            !sendOnce && ports[port] == nil && portKinds[port] == nil && r.receiver == nil && r.kernelRoutine == nil
                && !Self.answeredInKernel(r)
        }

        /// A send's destination port and whether it is a send-once right (MACH_MSG_TYPE_MOVE_SEND_ONCE: a reply).
        static func messagePort(_ a: [UInt64]) -> (port: UInt32, sendOnce: Bool)? {
            guard a.count > 3, a[1] & UInt64(MACH_SEND_MSG) != 0 else { return nil }
            return (UInt32(truncatingIfNeeded: a[3]), a[2] & 0x1f == UInt64(MACH_MSG_TYPE_MOVE_SEND_ONCE))
        }
    }

    var operation: Operation
    var target: String
    var calls: [SyscallRecord]
    /// Read or received, and written or sent, by the calls that succeeded. Messages: bytes sent.
    var bytesIn: UInt64 = 0
    var bytesOut: UInt64 = 0
    /// Calls that failed, leaving out "try again" (EAGAIN) and a non-blocking connect under way (EINPROGRESS).
    var failures = 0
    var threads: Set<UInt64> = []
    var longest: UInt64?
    /// Set for a descriptor's life: everything done with this descriptor from its open (or first use) to its close.
    var fd: Int32?
    /// A descriptor from socket() or accept(), or one used for socket calls.
    var socket = false
    /// Each call's own operation, for naming a descriptor's life after what was done with it.
    var kinds: Set<Operation> = []
    /// Messages: time spent in calls that also waited for the reply.
    var replyTime: UInt64 = 0
    /// The target is a stand-in ("Socket", "fd 4") that the first label of the descriptor replaces.
    private var provisional = false
    var id: Int { calls[0].id }

    var bytes: UInt64 { bytesIn + bytesOut }
    var allFailed: Bool { failures > 0 && failures == calls.count }

    var detail: String {
        let count = calls.count
        var parts = [String]()
        func size(_ n: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file) }
        let first = calls[0]
        if operation == .waits {
            parts.append("\(threads.count) thread\(threads.count == 1 ? "" : "s")")
            if let longest { parts.append("longest " + SyscallTraceView.duration(longest)) }
        } else if allFailed || (count == 1 && first.state == .inProgress) {
            parts.append(first.resultText)
        } else {
            switch operation {
            case .readWrite: parts += ["read " + size(bytesIn), "wrote " + size(bytesOut)]
            case .read: parts.append(size(bytesIn))
            case .write: parts.append(size(bytesOut))
            case .connection:
                if bytesOut > 0 { parts.append("sent " + size(bytesOut)) }
                if bytesIn > 0 { parts.append("received " + size(bytesIn)) }
            case .message:
                if bytesOut > 0 { parts.append(size(bytesOut) + " sent") }
                if replyTime > 0 { parts.append("replies took " + SyscallTraceView.duration(replyTime)) }
            case .kernelCall:
                if replyTime > 0 { parts.append("took " + SyscallTraceView.duration(replyTime)) }
            case .mainStarts:
                parts.append(first.resultText)
            default: break
            }
            if fd != nil {
                if kinds.contains(.sync) && operation != .sync { parts.append("flushed to disk") }
                if kinds.contains(.lock) && operation != .lock { parts.append("locked") }
            }
            if failures > 0 {
                // Why, from the first failure: "1 failed: ECONNREFUSED (Connection refused)".
                let why = calls.first { $0.failed && $0.error != Int64(EAGAIN) && $0.error != Int64(EINPROGRESS) }
                    .map { $0.resultText.hasPrefix("-1 ") ? String($0.resultText.dropFirst(3)) : $0.resultText }
                parts.append("\(failures.formatted()) failed" + (why.map { ": " + $0 } ?? ""))
            }
            if calls.last?.state == .inProgress { parts.append("in progress") }
            if Self.libraryOperations.contains(operation) {
                let total = calls.compactMap(\.duration).reduce(0, +)
                if total > 0 { parts.append("took " + SyscallTraceView.duration(total)) }
            }
            if parts.isEmpty { parts.append("Succeeded") }
        }
        if count > 1 {
            let unit = switch operation {
            case .loadImage: "images"
            case .initializers: "initializers"
            case .symbol: "symbols"
            default: "calls"
            }
            parts.append("\(count.formatted()) " + unit)
        }
        return parts.joined(separator: " · ")
    }

    /// dyld's work, from its trace events rather than syscalls (SyscallRecord.isLibraryCall).
    static let libraryOperations: Set<Operation> = [.loadImage, .initializers, .openLibrary, .closeLibrary, .symbol, .address,
                                                     .dyldSetup]

    /// A descriptor's calls more than this far apart are separate activities: a log file kept open for the whole
    /// trace shows as its bursts of writes, not one activity at its open.
    static let descriptorGap: UInt64 = 1_000_000_000
    /// Repeats of a one-off call (the same lookup, the same message destination) this close join one activity.
    static let repeatGap: UInt64 = 500_000_000

    /// `threads`: only those threads' calls make activities (none: every thread's). A close on any thread still
    /// ends its descriptor's life (as with `errorsOnly`), so a descriptor number another thread closed and reused
    /// starts a new activity.
    static func build(_ records: [SyscallRecord], filter: String, errorsOnly: Bool, threads: Set<UInt64> = [],
                      context: Context = Context()) -> [Self] {
        var groups: [Self] = []
        var waits: Self?
        /// Descriptor → its activity, until its close.
        var sessions: [Int32: Int] = [:]
        /// Thread, operation, target and error of a one-off call → its activity, for repeats.
        var recent: [String: Int] = [:]
        // Start order also puts calls still pending at trace stop in their proper position.
        for r in records.sorted(by: { ($0.time, $0.id) < ($1.time, $1.id) }) {
            let name = r.name.hasSuffix("_nocancel") ? String(r.name.dropLast(9)) : r.name
            let skip = (errorsOnly && !r.failed) || (!threads.isEmpty && !threads.contains(r.thread))
            if isWait(name, r) {
                if skip { continue }
                if waits == nil { waits = Self(operation: .waits, target: "", calls: []) }
                waits?.append(r, kind: nil)
                continue
            }
            let a = r.args ?? []
            let arg0 = a.first.map { Int32(truncatingIfNeeded: $0) }
            // A close, or a descriptor replaced by dup2, ends that descriptor's life.
            if name == "close" || name == "guarded_close_np" || name == "dup2" || name == "dup3" {
                let fd = name.hasPrefix("dup") ? (a.count > 1 ? Int32(truncatingIfNeeded: a[1]) : nil) : arg0
                if let fd, let i = sessions.removeValue(forKey: fd), !skip, name.hasSuffix("close") { groups[i].append(r, kind: nil) }
                continue
            }
            if skip { continue }
            let found = operation(name, r)
            let op = found?.0, onFD = found?.1 ?? false

            // A call that makes a descriptor starts its life.
            if r.state == .done, r.error == 0, let made = createdDescriptor(name, r) {
                var g = Self(operation: op ?? .open, target: "", calls: [])
                g.fd = made
                if op == .open {
                    g.target = r.paths.first ?? "Path unavailable"
                } else {
                    g.socket = true
                    g.provisional = true
                    g.target = name == "accept" ? "Accepted connection" : "Socket"
                }
                g.append(r, kind: op)
                sessions[made] = groups.count
                groups.append(g)
                continue
            }

            // A call on a descriptor joins its life.
            let usesFD = onFD || (op == nil && FdLabeler.fdArgs(r).contains { $0.0 == 0 })
            if usesFD, let fd = arg0, fd >= 0 {
                if let i = sessions[fd], let last = groups[i].calls.last, r.time <= (last.end ?? last.time) + descriptorGap {
                    groups[i].append(r, kind: op)
                    groups[i].relabel(r)
                } else if let op {
                    var g = Self(operation: op, target: r.firstFDLabel ?? "fd \(fd)", calls: [])
                    g.fd = fd
                    g.provisional = r.firstFDLabel == nil
                    g.append(r, kind: op)
                    sessions[fd] = groups.count
                    groups.append(g)
                }
                continue
            }
            guard let op else { continue }

            let target = target(op, name, r, context)
            var g = Self(operation: op, target: target, calls: [])
            // One-off calls a thread repeats on the same target, with the same result, join one activity. Another
            // thread's are its own: two threads asking the same service are separate work that shares a destination.
            let key = String(r.thread) + "\u{0}" + op.rawValue + "\u{0}" + target + "\u{0}" + String(r.error)
            if repeats.contains(op), let i = recent[key], let last = groups[i].calls.last,
               last.state == .done, r.state == .done, r.time - last.time <= repeatGap {
                groups[i].append(r, kind: op)
                continue
            }
            g.append(r, kind: op)
            if repeats.contains(op) { recent[key] = groups.count }
            groups.append(g)
        }
        for i in groups.indices where groups[i].fd != nil { groups[i].settle() }
        groups.reverse()
        if let waits { groups.append(waits) }
        guard !filter.isEmpty else { return groups }
        return groups.filter { g in
            [g.operation.rawValue, g.target, g.detail].contains { $0.localizedCaseInsensitiveContains(filter) } ||
            g.calls.contains { r in
                [r.name, r.argsText, r.resultText, r.caller].contains { $0.localizedCaseInsensitiveContains(filter) }
            }
        }
    }

    private static let repeats: Set<Operation> = [.lookup, .xattr, .metadata, .message, .inspect, .signal, .open,
                                                  .loadImage, .initializers, .openLibrary, .closeLibrary, .symbol, .address,
                                                  .kernelCall]

    private mutating func append(_ r: SyscallRecord, kind: Operation?) {
        calls.append(r)
        if operation == .waits {
            threads.insert(r.thread)
            if let duration = r.duration { longest = max(longest ?? 0, duration) }
            return
        }
        if let kind {
            kinds.insert(kind)
            if [.connect, .send, .receive, .listen, .accept].contains(kind) { socket = true }
        }
        if r.failed && r.error != Int64(EAGAIN) && r.error != Int64(EINPROGRESS) { failures += 1 }
        guard r.state != .inProgress, r.error == 0 else { return }
        switch kind {
        case .read, .receive: bytesIn += SyscallFormat.wide(r)
        case .write, .send: bytesOut += SyscallFormat.wide(r)
        case .message, .kernelCall:
            guard let a = r.args, a.count > 2 else { break }
            // A vector send (MACH64_MSG_VECTOR: XPC) has its vector count there, not its size.
            if a[1] & 0x1_0000_0000 == 0 { bytesOut += a[2] >> 32 }
            if a[1] & UInt64(MACH_RCV_MSG) != 0, let d = r.duration { replyTime += d }
        default: break
        }
    }

    /// A socket's label gains its endpoints on connect: the latest wins. A file keeps the path it was opened with.
    private mutating func relabel(_ r: SyscallRecord) {
        guard let label = r.firstFDLabel, !label.isEmpty, provisional || socket else { return }
        target = label
        provisional = false
    }

    /// Names a descriptor's life after what was done with it.
    private mutating func settle() {
        let k = kinds
        if socket {
            if k.contains(.listen) { operation = .listen }
            else if !k.isDisjoint(with: [.send, .receive, .read, .write]) { operation = .connection }
            else if k.contains(.connect) { operation = .connect }
            else if k.contains(.accept) { operation = .accept }
            else { operation = .connection }
            return
        }
        let reads = k.contains(.read), writes = k.contains(.write)
        if reads && writes { operation = .readWrite }
        else if writes { operation = .write }
        else if reads { operation = .read }
        else { operation = [Operation.list, .sync, .lock, .metadata, .xattr, .copy, .lookup, .open].first(where: k.contains) ?? .open }
    }

    /// The descriptor a successful call made: open's, socket's, accept's.
    private static func createdDescriptor(_ name: String, _ r: SyscallRecord) -> Int32? {
        switch name {
        case "open", "openat", "open_dprotected_np", "openat_dprotected_np", "guarded_open_np", "guarded_open_dprotected_np",
             "open_extended", "socket", "accept":
            let fd = Int32(truncatingIfNeeded: r.ret)
            return fd >= 0 ? fd : nil
        default: return nil
        }
    }

    private static func target(_ op: Operation, _ name: String, _ r: SyscallRecord, _ context: Context) -> String {
        let a = r.args ?? []
        switch op {
        case .message:
            return Context.messagePort(a).map { context.destination($0.port, sendOnce: $0.sendOnce, call: r) } ?? "Destination unavailable"
        case .signal:
            guard a.count > 1 else { return "Target unavailable" }
            return SyscallFormat.signalName(Int32(truncatingIfNeeded: a[1])) + " to " + context.process(Int32(truncatingIfNeeded: a[0]))
        case .inspect:
            return a.count > 1 ? context.process(Int32(truncatingIfNeeded: a[1])) : "Target unavailable"
        case .launch where name == "fork" || name == "vfork":
            return r.state == .done && r.error == 0 ? "child pid \(Int32(truncatingIfNeeded: r.ret))" : "child process"
        case .connection:
            return "Socket"
        case .openLibrary, .closeLibrary:
            // dlopen(NULL) opens the main program.
            return r.paths.first ?? (r.argValues.first == "NULL" ? "Main program" : "Library unavailable")
        case .symbol:
            if let p = r.paths.first { return p }
            switch r.argValues.first {
            case "RTLD_DEFAULT": return "Any loaded library (RTLD_DEFAULT)"
            case "RTLD_NEXT": return "Libraries after the caller's (RTLD_NEXT)"
            case "RTLD_SELF": return "The caller's library onward (RTLD_SELF)"
            case "RTLD_MAIN_ONLY": return "Main program (RTLD_MAIN_ONLY)"
            default: return "A library opened before the trace"
            }
        case .loadImage, .initializers, .address:
            return ""
        case .dyldSetup, .mainStarts:
            return r.paths.first ?? ""
        case .kernelCall:
            return r.kernelRoutine.map(MIGRoutines.name) ?? "Kernel routine unavailable"
        case .read, .write, .send, .receive, .connect, .listen, .accept:
            return r.firstFDLabel ?? "Unknown descriptor"
        default:
            return r.paths.isEmpty ? "Path unavailable" : r.pathText
        }
    }

    /// What one call does, and whether its first argument is the descriptor it acts on.
    private static func operation(_ name: String, _ r: SyscallRecord) -> (Operation, Bool)? {
        switch name {
        case "read", "pread", "readv", "preadv": return (.read, true)
        case "write", "pwrite", "writev", "pwritev": return (.write, true)
        case "recvfrom", "recvmsg", "recvmsg_x": return (.receive, true)
        case "sendto", "sendmsg", "sendmsg_x": return (.send, true)
        case "connect", "connectx": return (.connect, true)
        case "bind", "listen": return (.listen, true)
        case "accept": return (.accept, true)
        case "socket": return (.connection, false)
        case "fstat", "fstat64", "fgetattrlist", "fstatfs", "fstatfs64": return (.lookup, true)
        case "stat", "lstat", "stat64", "lstat64", "fstatat", "fstatat64", "access", "faccessat", "getattrlist",
             "readlink", "readlinkat", "statfs", "statfs64", "pathconf":
            return (.lookup, false)
        case "getdirentries", "getdirentries64", "getdirentriesattr", "getattrlistbulk": return (.list, true)
        case "fgetxattr", "flistxattr": return (.xattr, true)
        case "getxattr", "listxattr": return (.xattr, false)
        case "fsetxattr", "fremovexattr", "fchmod", "fchown", "futimes", "futimens", "fsetattrlist", "fchflags", "ftruncate":
            return (.metadata, true)
        case "setxattr", "removexattr", "chmod", "chown", "lchown", "utimes", "lutimes", "setattrlist", "setattrlistat",
             "chflags", "lchflags", "fchmodat", "fchownat", "utimensat", "truncate":
            return (.metadata, false)
        case "fsync", "fdatasync": return (.sync, true)
        case "flock": return (.lock, true)
        case "fcntl":
            guard let a = r.args, a.count > 1 else { return nil }
            switch Int32(truncatingIfNeeded: a[1]) {
            case F_FULLFSYNC, 85: return (.sync, true)                             // 85: F_BARRIERFSYNC
            case F_SETLK, F_SETLKW, 10, 90, 91, 93: return (.lock, true)            // F_SETLKWTIMEOUT, F_OFD_SETLK(W)(TIMEOUT)
            default: return nil
            }
        case "open", "openat", "open_dprotected_np", "openat_dprotected_np", "guarded_open_np", "guarded_open_dprotected_np",
             "open_extended":
            return (.open, false)
        case "rename", "renameat", "renameatx_np", "exchangedata": return (.rename, false)
        case "unlink", "unlinkat", "rmdir": return (.remove, false)
        case "mkdir", "mkdirat", "mkdir_extended": return (.mkdir, false)
        case "link", "linkat", "symlink", "symlinkat": return (.link, false)
        case "clonefile", "clonefileat", "fclonefileat", "copyfile": return (.copy, false)
        case "posix_spawn", "execve", "__mac_execve", "fork", "vfork": return (.launch, false)
        case "kill": return (.signal, false)
        case "proc_info", "proc_info_extended_id":
            // PIDINFO, PIDFDINFO, PIDFILEPORTINFO, PIDRUSAGE about another process; the rest list or control.
            guard let a = r.args, a.count > 1, [2, 3, 6, 9].contains(a[0]) else { return nil }
            let pid = Int32(truncatingIfNeeded: a[1])
            return pid > 0 ? (.inspect, false) : nil
        case "mach_msg2_trap":
            guard let a = r.args, a.count > 3, a[1] & UInt64(MACH_SEND_MSG) != 0 else { return nil }
            return (r.kernelRoutine != nil ? .kernelCall : .message, false)
        case "load image" where r.isLibraryCall: return (.loadImage, false)
        case "initializer" where r.isLibraryCall: return (.initializers, false)
        case "dlopen" where r.isLibraryCall: return (.openLibrary, false)
        case "dlclose" where r.isLibraryCall: return (.closeLibrary, false)
        case "dlsym" where r.isLibraryCall: return (.symbol, false)
        case "dladdr" where r.isLibraryCall: return (.address, false)
        case "dyld setup" where r.isLibraryCall: return (.dyldSetup, false)
        case "main()" where r.isLibraryCall: return (.mainStarts, false)
        default: return nil
        }
    }

    private static func isWait(_ name: String, _ r: SyscallRecord) -> Bool {
        switch name {
        case "kevent", "kevent64", "kevent_qos", "kevent_id", "select", "pselect", "poll",
             "ulock_wait", "ulock_wait2", "psynch_cvwait", "psynch_mutexwait", "mach_wait_until",
             "semaphore_wait_trap", "semaphore_timedwait_trap": return true
        case "workq_kernreturn": return r.args?.first == 4 // WQOPS_THREAD_RETURN
        case "mach_msg2_trap", "mach_msg_trap", "mach_msg_overwrite_trap":
            guard let args = r.args, args.count > 1 else { return false }
            return args[1] & UInt64(MACH_RCV_MSG) != 0 && args[1] & UInt64(MACH_SEND_MSG) == 0
        default: return false
        }
    }
}
