import Darwin
import Foundation

/// One burst of related calls. IDs remain stable while new calls join the burst.
struct SyscallActivity: Identifiable, Sendable {
    enum Operation: String {
        case read = "Read", write = "Write", lookup = "Look up", open = "Open"
        case rename = "Rename", remove = "Remove", mkdir = "Create directory"
        case connect = "Connect", waits = "Waits and event polls"
    }

    let operation: Operation
    let target: String
    var calls: [SyscallRecord]
    var bytes: UInt64 = 0
    var threads: Set<UInt64> = []
    var longest: UInt64?
    var id: Int { calls[0].id }

    var detail: String {
        let count = calls.count
        var parts = [String]()
        if operation == .waits {
            parts.append("\(threads.count) thread\(threads.count == 1 ? "" : "s")")
            if let longest { parts.append("longest " + SyscallTraceView.duration(longest)) }
        } else {
            let first = calls[0]
            if first.state == .inProgress || first.error != 0 { parts.append(first.resultText) }
            else if operation == .read || operation == .write {
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file))
            } else { parts.append("Succeeded") }
        }
        if count > 1 { parts.append("\(count.formatted()) calls") }
        return parts.joined(separator: " · ")
    }

    static func build(_ records: [SyscallRecord], filter: String, errorsOnly: Bool) -> [Self] {
        var groups: [Self] = []
        var waits: Self?
        var previous: Int?
        // Start order also puts calls still pending at trace stop in their proper position.
        for r in records.sorted(by: { ($0.time, $0.id) < ($1.time, $1.id) }) {
            let name = r.name.hasSuffix("_nocancel") ? String(r.name.dropLast(9)) : r.name
            if isWait(name, r) {
                if errorsOnly && !r.failed { continue }
                if waits == nil { waits = Self(operation: .waits, target: "", calls: []) }
                waits?.append(r)
                continue
            }
            guard let op = operation(name) else {
                // A close or descriptor replacement ends the preceding I/O burst.
                if ["close", "guarded_close_np", "dup2", "dup3", "fcntl"].contains(name) { previous = nil }
                continue
            }
            let usesFD = op == .read || op == .write || op == .connect || name == "fstat" || name == "fstat64"
            let fd = usesFD ? r.args?.first.map { Int32(truncatingIfNeeded: $0) } : nil
            let target = usesFD ? (r.firstFDLabel ?? fd.map { "fd \($0)" } ?? "Unknown descriptor")
                                : (r.paths.isEmpty ? "Path unavailable" : r.pathText)
            if errorsOnly && !r.failed { previous = nil; continue }
            if let i = previous, [.read, .write, .lookup].contains(op),
               groups[i].operation == op, groups[i].target == target,
               r.firstFDLabel != nil || !r.paths.isEmpty,
               let last = groups[i].calls.last, last.error == r.error,
               last.state == .done, r.state == .done,
               (!usesFD || last.args?.first == r.args?.first),
               r.time - last.time <= 500_000_000 {
                groups[i].append(r)
            } else {
                previous = groups.count
                groups.append(Self(operation: op, target: target, calls: []))
                groups[groups.count - 1].append(r)
            }
        }
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

    private mutating func append(_ r: SyscallRecord) {
        calls.append(r)
        if operation == .waits {
            threads.insert(r.thread)
            if let duration = r.duration { longest = max(longest ?? 0, duration) }
        } else if (operation == .read || operation == .write) && r.state != .inProgress && r.error == 0 {
            bytes += SyscallFormat.wide(r)
        }
    }

    private static func operation(_ name: String) -> Operation? {
        switch name {
        case "read", "pread", "readv", "preadv": return .read
        case "write", "pwrite", "writev", "pwritev": return .write
        case "stat", "lstat", "stat64", "lstat64", "fstat", "fstat64", "fstatat", "fstatat64", "access", "faccessat", "getattrlist": return .lookup
        case "open", "openat", "open_dprotected_np", "guarded_open_np", "openat_dprotected_np": return .open
        case "rename", "renameat", "renameatx_np": return .rename
        case "unlink", "unlinkat", "rmdir": return .remove
        case "mkdir", "mkdirat": return .mkdir
        case "connect", "connectx": return .connect
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
