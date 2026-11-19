import Darwin
import Foundation
import SystemConfiguration

/// The audit session a process belongs to (its asid), and what that session is: a GUI login, a remote or terminal
/// login, launchd's boot session, or a session of its own that launchd made for a job or XPC service.
///
/// Every process inherits its parent's audit session; loginwindow, sshd and login start new ones, and launchd
/// starts many processes in sessions of their own (measured in a VM: ~80 sessions for ~550 processes, most with a
/// single member and no flags). The GUI logins are the ones WindowServer lists (State:/Users/ConsoleUser).
struct LoginSession: Hashable, Sendable {
    enum Kind: Int, Sendable {
        /// A GUI login: one of WindowServer's sessions.
        case login
        /// An SSH (or other remote) login.
        case remote
        /// A login with a terminal or console access that WindowServer doesn't list (a console `login`).
        case terminal
        /// launchd's boot session: daemons and everything started before any login.
        case system
        /// A session launchd made for one job or XPC service; not a login.
        case separate
    }

    var asid: Int32
    var kind: Kind
    /// AU_SESSION_FLAG_* bits.
    var flags: UInt64
    /// Who logged in: the GUI login's user, or the audit user of a remote or terminal login.
    var user: String?
    /// The GUI login is the one on the display now (not switched away from, not a background login).
    var onScreen = false
    /// The session Proc X-Ray itself runs in.
    var isOwn = false

    /// A login a person started (GUI, SSH or terminal), rather than the boot session or a job's own.
    var isInteractive: Bool { kind == .login || kind == .remote || kind == .terminal }

    /// "yossi's login (on screen)", "SSH login: admin", "System (boot session)".
    var label: String {
        let who = user ?? "unknown user"
        switch kind {
        case .login: return "\(who)'s login" + (onScreen ? " (on screen)" : "")
        case .remote: return "SSH login: \(who)"
        case .terminal: return "Terminal login: \(who)"
        case .system: return "System (boot session)"
        case .separate: return "Own session (launchd job)"
        }
    }

    /// Sorts the logins first, the boot session and the jobs' own sessions after them.
    var order: Double { Double(kind.rawValue) * 1e10 + Double(asid) }
}

enum LoginSessions {
    // Deprecated in the SDK (the audit subsystem), still what the kernel has: resolved at run time, as in Native.
    private typealias AuditonFn = @convention(c) (Int32, UnsafeMutableRawPointer?, Int32) -> Int32
    private static let auditon: AuditonFn? = dlsym(dlopen(nil, RTLD_NOW), "auditon").map { unsafeBitCast($0, to: AuditonFn.self) }

    /// A process's audit session id, from its audit token (TASK_AUDIT_TOKEN through a task name port: the user's
    /// own processes, or any as root). ~2 µs.
    static func asid(_ pid: pid_t) -> Int32? {
        guard pid > 0 else { return nil }
        var t: mach_port_t = 0
        guard task_name_for_pid(mach_task_self_, pid, &t) == KERN_SUCCESS else { return nil }
        defer { mach_port_deallocate(mach_task_self_, t) }
        return asid(task: t)
    }

    private static func asid(task t: mach_port_t) -> Int32? { token(task: t).map { Int32(bitPattern: $0.val.6) } }

    static func token(task t: mach_port_t) -> audit_token_t? {
        var tok = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &tok) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(t, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count) }
        }
        return r == KERN_SUCCESS ? tok : nil
    }

    /// The session this app runs in.
    static let own: Int32? = asid(task: mach_task_self_)

    /// The GUI logins WindowServer lists, by asid: (user, on screen). Readable by anyone.
    static func guiLogins() -> [Int32: (user: String, onScreen: Bool)] {
        guard let v = SCDynamicStoreCopyValue(nil, "State:/Users/ConsoleUser" as CFString) as? [String: Any],
              let list = v["SessionInfo"] as? [[String: Any]] else { return [:] }
        var out: [Int32: (String, Bool)] = [:]
        for s in list {
            guard let id = (s["kCGSSessionAuditIDKey"] as? NSNumber)?.int32Value else { continue }
            out[id] = (s["kCGSSessionUserNameKey"] as? String ?? "?", (s["kCGSSessionOnConsoleKey"] as? NSNumber)?.boolValue ?? false)
        }
        return out
    }

    /// The session's flags and audit user (auditon A_GETSINFO_ADDR, which needs no privileges).
    static func info(_ asid: Int32) -> (flags: UInt64, auid: uid_t)? {
        sessionRecord(asid).map { ($0.ai_flags, $0.ai_auid) }
    }

    static func sessionRecord(_ asid: Int32) -> auditinfo_addr? {
        guard let auditon else { return nil }
        var ai = auditinfo_addr()
        ai.ai_asid = asid
        guard auditon(A_GETSINFO_ADDR, &ai, Int32(MemoryLayout<auditinfo_addr>.size)) == 0 else { return nil }
        return ai
    }

    /// What each of these sessions is. One SystemConfiguration read plus one syscall per session.
    static func describe(_ asids: Set<Int32>) -> [Int32: LoginSession] {
        let gui = guiLogins()
        var out: [Int32: LoginSession] = [:]
        for a in asids {
            let i = info(a)
            let f = i?.flags ?? 0
            func has(_ flag: audit_session_flags) -> Bool { f & UInt64(flag.rawValue) != 0 }
            var s = LoginSession(asid: a, kind: .separate, flags: f, isOwn: a == own)
            let auid = i.flatMap { $0.auid == uid_t.max ? nil : $0.auid }   // AU_DEFAUDITID: not set
            if let g = gui[a] {
                s.kind = .login; s.user = g.user; s.onScreen = g.onScreen
            } else if has(AU_SESSION_FLAG_IS_INITIAL) {
                s.kind = .system
            } else if has(AU_SESSION_FLAG_IS_REMOTE) {
                s.kind = .remote
            } else if has(AU_SESSION_FLAG_HAS_TTY) || has(AU_SESSION_FLAG_HAS_CONSOLE_ACCESS) || has(AU_SESSION_FLAG_HAS_GRAPHIC_ACCESS) {
                s.kind = .terminal
            }
            if s.user == nil, s.isInteractive, let auid { s.user = Native.userName(auid) }
            out[a] = s
        }
        return out
    }
}

/// A process's audit token (task_info TASK_AUDIT_TOKEN): the identity the kernel attaches to every Mach message the
/// process sends, which XPC services check their callers by.
struct AuditToken: Codable, Equatable, Sendable {
    /// Audit user: who logged in, kept across su and sudo. uid_t.max (AU_DEFAUDITID) when never set.
    var auid: UInt32
    var euid: UInt32
    var egid: UInt32
    var ruid: UInt32
    var rgid: UInt32
    var pid: Int32
    var asid: Int32
    /// Bumped on every exec, so a token names one program run by a pid, not the pid alone.
    var pidVersion: Int32

    init(_ t: audit_token_t) {
        let v = t.val
        auid = v.0; euid = v.1; egid = v.2; ruid = v.3; rgid = v.4
        pid = Int32(bitPattern: v.5); asid = Int32(bitPattern: v.6); pidVersion = Int32(bitPattern: v.7)
    }

    /// The user's own processes, or any as root. nil when the token belongs to another process (the pid was reused).
    static func read(_ pid: pid_t) -> AuditToken? {
        guard pid > 0 else { return nil }
        var t: mach_port_t = 0
        guard task_name_for_pid(mach_task_self_, pid, &t) == KERN_SUCCESS else { return nil }
        defer { mach_port_deallocate(mach_task_self_, t) }
        return LoginSessions.token(task: t).map(AuditToken.init).flatMap { $0.pid == pid ? $0 : nil }
    }
}

/// The kernel's record of an audit session (auditon A_GETSINFO_ADDR, readable by anyone).
struct AuditSessionRecord: Equatable, Sendable {
    var auid: UInt32
    var flags: UInt64
    /// Audit preselection masks: the event classes recorded on success and on failure.
    var maskSuccess: UInt32
    var maskFailure: UInt32
    /// Terminal: the device or remote port, the address type (AU_IPv4 or AU_IPv6) and the address.
    var termPort: Int32
    var termType: UInt32
    var termAddr: [UInt32]

    static func read(_ asid: Int32) -> AuditSessionRecord? {
        guard let ai = LoginSessions.sessionRecord(asid) else { return nil }
        let a = ai.ai_termid.at_addr
        return AuditSessionRecord(auid: ai.ai_auid, flags: ai.ai_flags, maskSuccess: ai.ai_mask.am_success,
                                  maskFailure: ai.ai_mask.am_failure, termPort: ai.ai_termid.at_port,
                                  termType: ai.ai_termid.at_type, termAddr: [a.0, a.1, a.2, a.3])
    }

    static let flagNames: [(UInt64, String, String)] = [
        (0x0001, "IS_INITIAL", "launchd's boot session"),
        (0x0010, "HAS_GRAPHIC_ACCESS", "can reach the window server"),
        (0x0020, "HAS_TTY", "has a terminal"),
        (0x1000, "IS_REMOTE", "logged in from another machine"),
        (0x2000, "HAS_CONSOLE_ACCESS", "a login at the Mac itself"),
        (0x4000, "HAS_AUTHENTICATED", "the user authenticated"),
    ]

    /// "HAS_TTY, IS_REMOTE, HAS_AUTHENTICATED", with any unnamed bits in hex.
    var flagText: String {
        var names = Self.flagNames.filter { flags & $0.0 != 0 }.map(\.1)
        let rest = flags & ~Self.flagNames.reduce(0) { $0 | $1.0 }
        if rest != 0 { names.append(String(format: "0x%llx", rest)) }
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }

    /// "port 52114 from 192.168.64.1" for a remote login; for a local one the port is a device, named where it can be
    /// ("/dev/null" for a GUI login, measured: loginwindow sets no real terminal).
    var terminalText: String {
        if flags & 0x1000 != 0 || address != nil {   // AU_SESSION_FLAG_IS_REMOTE
            return "port \(termPort)" + (address.map { " from \($0)" } ?? "")
        }
        if termPort == 0 { return "none" }
        let dev = dev_t(termPort)
        let numbers = "device \((dev >> 24) & 0xff),\(dev & 0xff_ffff)"
        guard let n = devname(dev, S_IFCHR) else { return numbers }
        return "/dev/\(String(cString: n)) (\(numbers))"
    }

    /// The terminal's address: an IP address for a remote login, else nil (a local session has none).
    var address: String? {
        guard termAddr.contains(where: { $0 != 0 }) else { return nil }
        // at_addr holds the address in network byte order, as in_addr / in6_addr.
        var bytes: [UInt8] = []
        for w in termAddr { withUnsafeBytes(of: w) { bytes += $0 } }
        let family = termType == 16 /* AU_IPv6 */ ? AF_INET6 : AF_INET
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(family, bytes, &buf, socklen_t(buf.count)) != nil else { return nil }
        return String(cString: buf)
    }
}
