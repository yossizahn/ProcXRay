import Darwin
import Foundation

/// Starts programs with posix_spawn, for the Launch window (a direct spawn, in the app) and for the helper (as root
/// or another user). Started suspended (POSIX_SPAWN_START_SUSPENDED: as if it got SIGSTOP before its first
/// instruction), a trace can attach before it runs and catch everything from dyld's first image load on; SIGCONT
/// lets it run.
///
/// An app bundle's executable is started directly, not through Launch Services, so it gets no open-document or
/// reopen events at launch. With SIP on, Apple's own apps can't be started this way at all (launch constraints:
/// Exit.codeSigning). What posix_spawn has no attribute for (resource limits, umask, nice, I/O policy, a sandbox
/// profile) pxr-exec sets in the process before it execs the program, keeping the pid.
enum Launcher {
    struct Child: Sendable, Equatable, Codable {
        let pid: Int32
        let start: Date
        /// The app's name, or the program's file name.
        let name: String
        let executable: String
    }

    /// One standard descriptor of the program.
    enum Stdio: Codable, Equatable, Sendable {
        case null
        case file(String, append: Bool)
        /// A pipe whose read end comes back with the child (Spawned), for showing what it writes.
        case pipe
        /// stderr only: the same as stdout.
        case sameAsStdout
    }

    /// Everything one posix_spawn takes, resolved: the app builds it from a LaunchSpec, and sends it to the helper
    /// as is for a launch as root.
    struct Request: Codable, Equatable, Sendable {
        var path: String
        /// argv[0] first.
        var argv: [String]
        var environment: [String: String]
        var workingDirectory: String?
        var stdin: Stdio = .null
        var stdout: Stdio = .null
        var stderr: Stdio = .null
        var spawn = SpawnSettings()
        var process = ProcessSettings()
        /// Run as (the helper only: setting them needs root).
        var uid: uid_t?
        var gid: gid_t?
        var groups: [gid_t]?
        /// Started stopped, for a trace or for leaving it suspended.
        var suspended = false
        var name: String
    }

    /// A started child and the read ends of its stdout and stderr pipes (Stdio.pipe), which the caller closes.
    struct Spawned {
        let child: Child
        let stdout: Int32?
        let stderr: Int32?
    }

    /// A user to run as, and what a login environment needs of them.
    struct Account: Sendable, Equatable {
        let name: String
        let uid: uid_t
        let gid: gid_t
        let home: String
        let shell: String

        static var current: Account { lookup(String(getuid())) ?? Account(name: NSUserName(), uid: getuid(), gid: getgid(), home: NSHomeDirectory(), shell: "/bin/zsh") }

        /// By name or uid.
        static func lookup(_ nameOrID: String) -> Account? {
            let t = nameOrID.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            let pw = UInt32(t).flatMap { getpwuid($0) } ?? getpwnam(t)
            guard let p = pw?.pointee else { return nil }
            return Account(name: String(cString: p.pw_name), uid: p.pw_uid, gid: p.pw_gid,
                           home: String(cString: p.pw_dir), shell: String(cString: p.pw_shell))
        }

        /// The user's groups, their primary one first (getgrouplist: what initgroups would give).
        var groups: [gid_t] {
            var n: Int32 = 64
            while true {
                var list = [Int32](repeating: 0, count: Int(n))
                var count = n
                if getgrouplist(name, Int32(bitPattern: gid), &list, &count) == 0 {
                    var out = [gid] + list.prefix(Int(count)).map { gid_t(bitPattern: $0) }.filter { $0 != gid }
                    if out.count > 16 { out = Array(out.prefix(16)) }   // NGROUPS
                    return out
                }
                if n >= 1024 { return [gid] }
                n *= 2
            }
        }
    }

    static func group(_ nameOrID: String) -> gid_t? {
        let t = nameOrID.trimmingCharacters(in: .whitespaces)
        if let g = UInt32(t) { return g }
        return getgrnam(t)?.pointee.gr_gid
    }

    /// The program an app bundle runs, or `url` itself when it's an executable file.
    static func executable(for url: URL) -> String? {
        if (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true || url.pathExtension == "app" {
            return Bundle(url: url)?.executableURL?.path
        }
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &dir), !dir.boolValue,
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url.path
    }

    static func isApp(_ url: URL) -> Bool {
        url.pathExtension == "app" || (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }

    static func displayName(for url: URL) -> String {
        if url.pathExtension == "app" {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return url.lastPathComponent
    }

    /// pxr-exec, next to this binary (Contents/MacOS in the bundle, the build directory for `swift build`), or
    /// where PXR_EXEC says (the tests).
    static var trampoline: String? {
        if let p = ProcessInfo.processInfo.environment["PXR_EXEC"], FileManager.default.isExecutableFile(atPath: p) { return p }
        guard let dir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() else { return nil }
        let p = dir.appendingPathComponent("pxr-exec").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    /// Starts `path` suspended, its stdio on /dev/null; resume it with `resume`, or `kill` it if it's not wanted
    /// after all.
    static func spawnSuspended(_ path: String, arguments: [String], name: String) -> Result<Child, LaunchError> {
        let r = Request(path: path, argv: [path] + arguments, environment: ProcessInfo.processInfo.environment,
                        suspended: true, name: name)
        return spawn(r).map(\.child)
    }

    // Private spawn attributes, from libsystem_kernel and libquarantine (spawn_private.h): looked up at run time.
    private typealias Attr = UnsafeMutablePointer<posix_spawnattr_t?>
    private static func sym<T>(_ name: String, as: T.Type) -> T? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: T.self) }
    }

    static func spawn(_ r: Request) -> Result<Spawned, LaunchError> {
        let fail = { (why: String) in Result<Spawned, LaunchError>.failure(LaunchError(message: "Couldn't start \(r.name): \(why)")) }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        let s = r.spawn
        var flags: Int32 = 0
        if r.suspended { flags |= POSIX_SPAWN_START_SUSPENDED }
        if !s.inheritDescriptors { flags |= POSIX_SPAWN_CLOEXEC_DEFAULT }
        if s.newSession { flags |= POSIX_SPAWN_SETSID }
        if s.newProcessGroup && !s.newSession { flags |= POSIX_SPAWN_SETPGROUP; posix_spawnattr_setpgroup(&attr, 0) }
        if s.resetIDs { flags |= POSIX_SPAWN_RESETIDS }
        if s.disableASLR { flags |= 0x0100 }   // _POSIX_SPAWN_DISABLE_ASLR
        if s.defaultSignals {
            // Default handling, nothing blocked: the app's own mask and ignored signals would otherwise carry over.
            flags |= POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
            var none = sigset_t(), all = sigset_t()
            sigemptyset(&none); sigfillset(&all)
            posix_spawnattr_setsigmask(&attr, &none)
            posix_spawnattr_setsigdefault(&attr, &all)
        }
        posix_spawnattr_setflags(&attr, Int16(truncatingIfNeeded: flags))

        if s.architecture != .any {
            var type: cpu_type_t, sub: cpu_subtype_t
            switch s.architecture {
            case .arm64e: type = CPU_TYPE_ARM64; sub = CPU_SUBTYPE_ARM64E
            case .arm64: type = CPU_TYPE_ARM64; sub = CPU_SUBTYPE_ARM64_ALL
            default: type = CPU_TYPE_X86_64; sub = CPU_SUBTYPE_X86_64_ALL
            }
            var done = 0
            posix_spawnattr_setarchpref_np(&attr, 1, &type, &sub, &done)
        }
        if s.qosClamp != .none, let f = sym("posix_spawnattr_set_qos_clamp_np", as: (@convention(c) (Attr, UInt64) -> Int32).self) {
            _ = f(&attr, s.qosClamp.value)
        }
        if s.role != .unset, let f = sym("posix_spawnattr_set_darwin_role_np", as: (@convention(c) (Attr, UInt64) -> Int32).self) {
            _ = f(&attr, s.role.value)
        }
        if s.processType != .unset, let f = sym("posix_spawnattr_setprocesstype_np", as: (@convention(c) (Attr, Int32) -> Int32).self) {
            _ = f(&attr, s.processType.value)
        }
        if s.disclaimResponsibility, let f = sym("responsibility_spawnattrs_setdisclaim", as: (@convention(c) (Attr, Int32) -> Int32).self) {
            _ = f(&attr, 1)
        }
        if s.noSMT { posix_spawnattr_setnosmt_np(&attr) }
        if s.cpuMitigations { posix_spawnattr_set_csm_np(&attr, UInt32(POSIX_SPAWN_NP_CSM_ALL)) }
        if s.memoryLimitMB > 0 || s.jetsamPriority >= 0,
           let f = sym("posix_spawnattr_setjetsam_ext", as: (@convention(c) (Attr, Int16, Int32, Int32, Int32) -> Int32).self) {
            // POSIX_SPAWN_JETSAM_MEMLIMIT_ACTIVE_FATAL | _INACTIVE_FATAL; without them the limit only reports.
            let fatal: Int16 = s.memoryLimitFatal ? 0x04 | 0x08 : 0
            let limit = s.memoryLimitMB > 0 ? Int32(s.memoryLimitMB) : -1
            _ = f(&attr, fatal, Int32(s.jetsamPriority), limit, limit)
        }
        if let uid = r.uid {
            guard let setUID = sym("posix_spawnattr_set_uid_np", as: (@convention(c) (Attr, uid_t) -> Int32).self),
                  let setGID = sym("posix_spawnattr_set_gid_np", as: (@convention(c) (Attr, gid_t) -> Int32).self),
                  let setGroups = sym("posix_spawnattr_set_groups_np", as: (@convention(c) (Attr, Int32, UnsafeMutablePointer<gid_t>?, uid_t) -> Int32).self)
            else { return fail("this macOS has no posix_spawn attribute for the user.") }
            let gid = r.gid ?? getgid()
            _ = setUID(&attr, uid)
            _ = setGID(&attr, gid)
            var groups = r.groups ?? [gid]
            // KAUTH_UID_NONE: no group membership resolution beyond the list.
            _ = groups.withUnsafeMutableBufferPointer { setGroups(&attr, Int32($0.count), $0.baseAddress, UInt32.max) }
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        var readEnds: [Int32: Int32] = [:]   // fd → read end
        var writeEnds: [Int32] = []
        func closeAll() { readEnds.values.forEach { close($0) }; writeEnds.forEach { close($0) } }
        for (fd, io) in [(Int32(0), r.stdin), (1, r.stdout), (2, r.stderr)] {
            switch io {
            case .null:
                posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
            case .file(let path, let append):
                let mode = fd == 0 ? O_RDONLY : O_WRONLY | O_CREAT | (append ? O_APPEND : O_TRUNC)
                posix_spawn_file_actions_addopen(&actions, fd, path, mode, 0o644)
            case .sameAsStdout:
                posix_spawn_file_actions_adddup2(&actions, 1, fd)
            case .pipe:
                guard fd != 0 else { posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0); continue }
                var p: [Int32] = [-1, -1]
                guard pipe(&p) == 0 else { closeAll(); return fail("no pipe (\(String(cString: strerror(errno))))") }
                // Neither end leaks into the child but as `fd` (when it inherits descriptors).
                _ = fcntl(p[0], F_SETFD, FD_CLOEXEC); _ = fcntl(p[1], F_SETFD, FD_CLOEXEC)
                readEnds[fd] = p[0]; writeEnds.append(p[1])
                posix_spawn_file_actions_adddup2(&actions, p[1], fd)
            }
        }
        if let dir = r.workingDirectory, !dir.isEmpty { posix_spawn_file_actions_addchdir_np(&actions, dir) }

        // pxr-exec in front when something must be set from inside the process.
        var program = r.path
        var argv = r.argv.isEmpty ? [r.path] : r.argv
        if !r.process.isEmpty {
            guard let t = trampoline else { closeAll(); return fail("pxr-exec is missing from the app (it sets the limits, umask, nice, I/O policy and sandbox).") }
            argv = [t] + r.process.execArguments + ["--", r.path] + argv
            program = t
        }
        let env = r.environment.map { "\($0.key)=\($0.value)" }
        let cArgv = argv.map { strdup($0) }, cEnv = env.map { strdup($0) }
        defer { cArgv.forEach { free($0) }; cEnv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = (cArgv + [nil]).withUnsafeBufferPointer { a in
            (cEnv + [nil]).withUnsafeBufferPointer { e in
                posix_spawn(&pid, program, &actions, &attr, a.baseAddress, e.baseAddress)
            }
        }
        writeEnds.forEach { close($0) }
        guard rc == 0 else {
            readEnds.values.forEach { close($0) }
            let why = rc == EPERM && r.uid != nil ? "running as another user needs root." : String(cString: strerror(rc)) + "."
            return fail(why)
        }
        reap(pid)
        guard let start = Native.process(pid)?.start else {
            kill(pid, SIGKILL)
            readEnds.values.forEach { close($0) }
            return .failure(LaunchError(message: "\(r.name) started but its process couldn't be read."))
        }
        return .success(Spawned(child: Child(pid: pid, start: start, name: r.name, executable: r.path),
                                stdout: readEnds[1], stderr: readEnds[2]))
    }

    static func resume(_ pid: Int32) { kill(pid, SIGCONT) }

    /// How a launched child ended.
    struct Exit: Sendable, Equatable, Codable {
        /// waitpid's status.
        let status: Int32
        /// The kernel killed it for code signing (NOTE_EXIT_CSERROR). For an app of Apple's this is a launch
        /// constraint: with SIP on, Apple's apps (Calculator, TextEdit, Chess, Activity Monitor…) may only be started
        /// by Launch Services, and a posix_spawn by any other process, launchd user jobs included, is killed
        /// before its first instruction ("Launch Constraint Violation … launch type 0" in the kernel log).
        let codeSigning: Bool

        /// How it ended, in a sentence.
        var summary: String {
            if let problem { return problem }
            return "It exited with status \((status >> 8) & 0xff)."
        }

        /// Why it ended, for a child that didn't simply exit.
        var problem: String? {
            if codeSigning {
                return "macOS killed it before it ran (code signing). Apple's own apps carry launch constraints that only let Launch Services start them, so they can't be launched suspended and traced from their first instruction while SIP is on."
            }
            let sig = status & 0x7f
            if sig != 0 && sig != 0x7f { return "It was killed by signal \(sig) (\(String(cString: strsignal(sig))))." }
            return nil
        }
    }

    private static let exitLock = NSLock()
    nonisolated(unsafe) private static var exits: [pid_t: Exit] = [:]

    /// How a child started here ended, once it has: nil while it runs, or for a pid not started here (or started
    /// again since, by another child with the same pid).
    static func exit(of pid: pid_t) -> Exit? {
        exitLock.lock(); defer { exitLock.unlock() }
        return exits[pid]
    }

    /// A child that exits stays a zombie until its parent waits for it: wait on a thread of its own. A kqueue
    /// watch registered now, while it's still suspended, gets the kernel's exit detail too (waitpid only says
    /// SIGKILL, for a code-signing kill as for any other).
    private static func reap(_ pid: pid_t) {
        exitLock.lock(); exits[pid] = nil; exitLock.unlock()
        let kq = kqueue()
        var ev = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                        fflags: UInt32(NOTE_EXIT) | UInt32(NOTE_EXITSTATUS) | UInt32(NOTE_EXIT_DETAIL), data: 0, udata: nil)
        let watching = kq >= 0 && kevent(kq, &ev, 1, nil, 0, nil) == 0
        Thread.detachNewThread {
            var codeSigning = false
            if watching {
                var out = kevent()
                while kevent(kq, nil, 0, &out, 1, nil) == -1 && errno == EINTR {}
                codeSigning = Int32(truncatingIfNeeded: out.data) & NOTE_EXIT_DETAIL_MASK == NOTE_EXIT_CSERROR
            }
            if kq >= 0 { close(kq) }
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            exitLock.lock(); exits[pid] = Exit(status: status, codeSigning: codeSigning); exitLock.unlock()
        }
    }

    /// Splits an argument line as a shell would for words: spaces separate, quotes ('…', "…") group, a backslash
    /// escapes the next character. No variables, globs or other expansion.
    static func splitArguments(_ line: String) -> [String] {
        var out: [String] = [], word = "", inWord = false
        var quote: Character?
        var escaped = false
        for c in line {
            if escaped { word.append(c); escaped = false; inWord = true; continue }
            if c == "\\" && quote != "'" { escaped = true; inWord = true; continue }
            if let q = quote {
                if c == q { quote = nil } else { word.append(c) }
                continue
            }
            if c == "'" || c == "\"" { quote = c; inWord = true; continue }
            if c.isWhitespace {
                if inWord { out.append(word); word = ""; inWord = false }
                continue
            }
            word.append(c); inWord = true
        }
        if inWord { out.append(word) }
        return out
    }
}

struct LaunchError: Error, Sendable { let message: String }
