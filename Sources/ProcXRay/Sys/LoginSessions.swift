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

    private static func asid(task t: mach_port_t) -> Int32? {
        var tok = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &tok) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(t, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count) }
        }
        // val[6] is the asid (audit_token_to_asid; libbsm isn't linked).
        return r == KERN_SUCCESS ? Int32(bitPattern: tok.val.6) : nil
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
        guard let auditon else { return nil }
        var ai = auditinfo_addr()
        ai.ai_asid = asid
        guard auditon(A_GETSINFO_ADDR, &ai, Int32(MemoryLayout<auditinfo_addr>.size)) == 0 else { return nil }
        return (ai.ai_flags, ai.ai_auid)
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
