import Darwin
import Foundation
import XPC

/// Who asked for an app launch. An app started through LaunchServices (`open`, NSWorkspace, AppleScript…) is
/// spawned by launchd: its parent is launchd, it's its own responsible process and gets its own coalition, and
/// `launchctl procinfo` says "submitted by runningboardd". The request goes `open` → CoreServicesUIAgent →
/// RunningBoard → launchd, and only CoreServicesUIAgent names the requester, in its log (subsystem
/// com.apple.launchservices, category open, info level, kept in memory only, so it has to be read live):
///
///     LAUNCH: Setting launcherAuditToken to 87160/5011926 501 100015      (requester pid / pid version)
///     LAUNCH: Successful launched 0x0-0x4eb1ead pid=87161 local.procxray.dev  '<private>'
///
/// both on the thread that handled the request. The requester (`open`) lives ~70 ms; the first line arrives
/// ~24 ms after it starts (measured on macOS 27.2, 6 of 6 launches caught with `open` still alive), so its
/// ancestry is read the moment the line comes in: `open` ← zsh ← claude ← Ghostty.
///
/// `log stream` holds its output back when writing to a pipe, so it writes to a pseudo-terminal. It runs
/// from launch to quit; the predicate is evaluated by logd, so it wakes only on app launches.
final class LaunchWatcher: @unchecked Sendable {
    static let shared = LaunchWatcher()

    /// One process in the requester's ancestry, as it was when the request came in.
    struct Hop: Sendable, Hashable {
        var pid: pid_t
        var start: Date
        var name: String
        var path: String?
    }

    struct Record: Sendable {
        var appPid: pid_t
        var appStart: Date?
        var bundleID: String
        /// The requester first, then its parent, up to (not including) launchd.
        var launcher: [Hop]
        /// The requester's pid version from its audit token (tells a reused pid apart).
        var launcherVersion: Int?
        var at: Date
    }

    fileprivate let lock = NSLock()
    private var pending: [Int: (hops: [Hop], version: Int?, at: Date)] = [:]   // CoreServicesUIAgent thread → requester
    fileprivate var records: [pid_t: Record] = [:]
    private var process: Process?
    /// A pipe never written to: the stream's owner script reads the read end and gets end of file when the
    /// write end closes, which only happens when this process exits (it's close-on-exec, so no child holds it).
    private let lifeline: (read: Int32, write: Int32) = {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return (-1, -1) }
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        return (fds[0], fds[1])
    }()
    private var started = false
    private(set) var since: Date?
    /// Why the stream isn't running, when it can't: `log stream` refuses a user who isn't an admin (exit 77).
    private(set) var unavailable: String?
    /// Restarts after the stream ended quickly, for the backoff.
    private var quickExits = 0

    /// Starts watching (once). Launches made before this are not seen.
    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        started = true
        spawn()
    }

    /// The launch record for a running process, if this watcher saw it launched.
    func record(pid: pid_t, start: Date) -> Record? {
        lock.lock(); defer { lock.unlock() }
        guard let r = records[pid], r.appStart == nil || abs(r.appStart!.timeIntervalSince(start)) < 1 else { return nil }
        return r
    }

    var isWatching: Bool { lock.lock(); defer { lock.unlock() }; return process?.isRunning == true }

    // MARK: Reading

    private func spawn() {
        var master: Int32 = -1, slave: Int32 = -1
        var t = termios()
        cfmakeraw(&t)   // no echo, no CR before LF
        guard openpty(&master, &slave, nil, &t, nil) == 0 else { return }
        let p = Process()
        // `log stream` doesn't exit when the terminal it writes to goes away (checked: it kept running after its
        // reader quit, through later writes), so a small sh script owns it and kills it when its stdin, a pipe
        // whose other end only this process holds, reaches end of file: when this process exits in any way,
        // a crash or SIGKILL included. When `log stream` itself ends, the script stops that watcher too (it holds
        // the terminal open, which would keep the reader thread below blocked in read forever: one leaked
        // thread, pty and sh per restart) and exits with the stream's status.
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // stdin goes to fd 3 first: sh gives a background command /dev/null as its stdin when job control is off.
        p.arguments = ["-c", #"exec 3<&0; /usr/bin/log stream --level info --style ndjson --predicate "$1" </dev/null & L=$!; (read _ <&3; kill $L 2>/dev/null) & W=$!; wait $L; S=$?; kill $W 2>/dev/null; exit $S"#,
                       "sh", #"process == "CoreServicesUIAgent" AND category == "open" AND (eventMessage BEGINSWITH "LAUNCH: Setting launcherAuditToken" OR eventMessage BEGINSWITH "LAUNCH: Successful launched")"#]
        p.standardOutput = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        p.standardError = FileHandle.nullDevice
        // A duplicate per start: Process may close the handle it's given once the child is running.
        let lifelineRead = dup(lifeline.read)
        guard lifeline.read >= 0, lifelineRead >= 0 else { close(master); close(slave); return }
        p.standardInput = FileHandle(fileDescriptor: lifelineRead, closeOnDealloc: false)
        let startedAt = Date()
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.lock.lock()
            // 77 (EX_NOPERM): "Must be admin to run 'stream' command". Retrying can't help.
            if proc.terminationStatus == 77 {
                self.unavailable = "Launch tracing needs an admin user (log stream refuses others)."
                self.process = nil
                self.lock.unlock()
                return
            }
            // logd restarted or the stream ended: start again after a pause, longer each time it ends quickly.
            self.quickExits = -startedAt.timeIntervalSinceNow < 30 ? self.quickExits + 1 : 0
            let delay = min(600, 5 * pow(2, Double(max(0, self.quickExits - 1))))
            self.lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                self.lock.lock(); defer { self.lock.unlock() }
                self.spawn()
            }
        }
        do { try p.run() } catch { close(master); close(slave); close(lifelineRead); return }
        close(slave)
        close(lifelineRead)   // the child has its own copy now
        process = p
        since = since ?? Date()
        let fd = master
        Thread.detachNewThread { [weak self] in
            var buf = [UInt8](repeating: 0, count: 65536)
            var line: [UInt8] = []
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                for b in buf[0..<n] {
                    if b == 10 { self?.handle(line); line.removeAll(keepingCapacity: true) } else if b != 13 { line.append(b) }
                }
            }
            close(fd)
        }
    }

    private func handle(_ bytes: [UInt8]) {
        guard bytes.first == UInt8(ascii: "{"),
              let o = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
              let msg = o["eventMessage"] as? String else { return }
        let thread = (o["threadID"] as? NSNumber)?.intValue ?? 0
        if let r = msg.range(of: "launcherAuditToken to ") {
            // "87160/5011926 501 100015"
            let parts = msg[r.upperBound...].split(separator: " ").first?.split(separator: "/") ?? []
            guard let pid = parts.first.flatMap({ pid_t($0) }) else { return }
            let hops = Self.ancestry(pid)   // now, while the requester is still alive
            lock.lock()
            pending[thread] = (hops, parts.count > 1 ? Int(parts[1]) : nil, Date())
            pending = pending.filter { Date().timeIntervalSince($0.value.at) < 30 }
            lock.unlock()
        } else if let r = msg.range(of: " pid=") {
            // "LAUNCH: Successful launched 0x0-0x4eb1ead pid=87161 local.procxray.dev  '<private>'"
            let rest = msg[r.upperBound...].split(separator: " ")
            guard let pid = rest.first.flatMap({ pid_t($0) }) else { return }
            let bundle = rest.count > 1 ? String(rest[1]) : ""
            let start = Native.process(pid)?.start
            lock.lock()
            if let req = pending.removeValue(forKey: thread), !req.hops.isEmpty {
                records[pid] = Record(appPid: pid, appStart: start, bundleID: bundle, launcher: req.hops,
                                      launcherVersion: req.version, at: Date())
                if records.count > 500 {
                    let alive = records.filter { Native.isAlive($0.key) }
                    records = alive.count > 400 ? Dictionary(uniqueKeysWithValues: alive.sorted { $0.value.at > $1.value.at }.prefix(400).map { ($0.key, $0.value) }) : alive
                }
            }
            lock.unlock()
        }
    }

    /// `pid` and its parents up to launchd, read now.
    static func ancestry(_ pid: pid_t) -> [Hop] {
        var out: [Hop] = []
        var cur = pid
        var seen: Set<pid_t> = []
        while cur > 1, !seen.contains(cur), out.count < 16, let k = Native.process(cur) {
            seen.insert(cur)
            let path = Native.path(cur)
            out.append(Hop(pid: cur, start: k.start, name: ProcInfo.displayName(path: path, comm: k.comm), path: path))
            cur = k.ppid
        }
        return out
    }
}

/// How a process was started, and how that's known.
struct LaunchMechanism: Sendable, Hashable {
    enum Confidence: String, Sendable { case exact, inferred }
    var how: String
    var detail: String?
    var source: String
    var confidence: Confidence

    /// The best description from what's known, most specific first.
    static func describe(ppid: pid_t, parentName: String?, record: LaunchWatcher.Record?, parentASN: String?,
                         env: EnvAttribution?, launchdLabel: String?, job: [String: String] = [:]) -> [LaunchMechanism] {
        var out: [LaunchMechanism] = []
        if ppid > 1 {
            out.append(LaunchMechanism(how: "Started directly by its parent" + (parentName.map { " (\($0))" } ?? ""),
                                       detail: "fork/exec or posix_spawn", source: "kernel parent pid", confidence: .exact))
            return out
        }
        if let r = record, let req = r.launcher.first {
            out.append(LaunchMechanism(how: "Launched through LaunchServices by \(Self.tool(req.name, path: req.path))",
                                       detail: req.path, source: "CoreServicesUIAgent launch log, read live", confidence: .exact))
        }
        if let a = parentASN, !a.isEmpty {
            let how: String = switch a {
            case "Dock": "Launched from the Dock"
            case "Finder": "Launched from the Finder"
            case "loginwindow": "Opened at login (login item, or reopened from the last session)"
            default: "Launched by the app \(a)"
            }
            out.append(LaunchMechanism(how: how, detail: nil, source: "LaunchServices parentASN", confidence: .exact))
        }
        if let e = env, let cmd = e.command, e.fromShell {
            let name = (cmd as NSString).lastPathComponent
            out.append(LaunchMechanism(how: "Launched from a shell with \(Self.tool(name, path: cmd))", detail: cmd,
                                       source: "inherited environment: _=\(cmd)", confidence: .inferred))
        } else if let e = env, e.fromShell {
            out.append(LaunchMechanism(how: "Launched by a process running in a shell session", detail: e.pwd,
                                       source: "inherited environment: shell variables (SHLVL, PWD, TERM)", confidence: .inferred))
        }
        let label = launchdLabel ?? env?.xpcServiceName
        if let l = label {
            if l.hasPrefix("application.") {
                if out.isEmpty {
                    out.append(LaunchMechanism(how: "Launched through LaunchServices", detail: "by an app or tool that left no trace (NSWorkspace, open, AppleScript…)",
                                               source: "launchd job \(l)", confidence: .exact))
                }
            } else {
                let kind = job["type"].map { " (\($0))" } ?? ""
                let reason = job["immediate reason"].map { "Started because of " + Self.reason($0) }
                out.append(LaunchMechanism(how: "Started by launchd as the job \(l)\(kind)",
                                           detail: reason ?? "a launch agent or daemon, an XPC service, or a job something submitted",
                                           source: Self.jobSource(l, job, ["type", "immediate reason"]), confidence: .exact))
                if let r = Self.registeredBy(job) {
                    out.append(LaunchMechanism(how: r.how, detail: r.detail, source: "launchctl print \(l): " + r.field, confidence: .exact))
                }
            }
        }
        return out
    }

    /// "launchctl print <label>: <the fields that were there>", or just the label when none were.
    static func jobSource(_ label: String, _ job: [String: String], _ fields: [String]) -> String {
        let have = fields.filter { !(job[$0] ?? "").isEmpty }
        return have.isEmpty ? "launchd job label" : "launchctl print \(label): " + have.joined(separator: ", ")
    }

    /// launchd's `immediate reason`, spelled out: what made it start, never who.
    static func reason(_ r: String) -> String {
        let known: [String: String] = [
            "ipc (mach)": "a message to one of its Mach services",
            "ipc (socket)": "a connection to one of its sockets",
            "xpc event": "an XPC event it subscribes to",
            "launch job demand": "a request to launch it (an app launch, or a job another process submitted)",
            "speculative": "its own RunAtLoad / KeepAlive setting",
            "semaphore": "a KeepAlive condition",
            "interval": "its start interval",
            "non-ipc demand": "an explicit start (launchctl kickstart or similar)",
        ]
        // Checked: neither the job record, launchd's log nor the responsible pid names who sent the message or
        // ran the kickstart.
        let unrecorded = ["ipc (mach)", "ipc (socket)", "non-ipc demand"].contains(r) ? "; launchd doesn't record who asked" : ""
        return (known[r].map { "\($0) (\(r))" } ?? r) + unrecorded
    }

    /// Who put the job into launchd: `path = (submitted by smd.17895)` for a submitted job, the plist for one
    /// launchd loaded itself, plus `parent bundle identifier` for an SMAppService registration.
    static func registeredBy(_ job: [String: String]) -> (how: String, detail: String?, field: String)? {
        let parentApp = job["parent bundle identifier"].flatMap { $0.isEmpty ? nil : $0 }
        guard let path = job["path"], !path.isEmpty else {
            return parentApp.map { ("Registered by the app \($0)", nil, "parent bundle identifier") }
        }
        if let r = path.range(of: #"submitted by ([^ )]+)\.(\d+)"#, options: .regularExpression) {
            let s = path[r].dropFirst("submitted by ".count)
            let dot = s.lastIndex(of: ".")!
            let name = String(s[..<dot]), pid = String(s[s.index(after: dot)...])
            let what: String = switch name {
            case "smd": parentApp.map { "Registered by the app \($0) through SMAppService" } ?? "Registered through SMAppService (smd)"
            case "runningboardd": "Submitted by RunningBoard (an app or extension launch)"
            case "launchctl": "Submitted with launchctl submit"
            default: "Submitted by \(name)"
            }
            return (what, "submitter: \(name), pid \(pid) at the time", parentApp != nil && name == "smd" ? "path (submitted by), parent bundle identifier" : "path (submitted by)")
        }
        // A plist launchd loaded itself (at boot or login), or with launchctl bootstrap/load.
        let how: String
        if path.hasSuffix(".xpc") {
            // An XPC service bundle: loaded into the domain of whatever uses it (a framework's or an app's).
            let owner = path.components(separatedBy: "/").first { $0.hasSuffix(".framework") || $0.hasSuffix(".app") }
            how = "XPC service" + (owner.map { " bundled in \($0)" } ?? "") + ", loaded into launchd when first used"
        }
        else if path.hasPrefix("/System/") { how = "Loaded by launchd from Apple's plist" }
        else if path.contains("/Library/LaunchDaemons/") { how = "Loaded by launchd from a system daemon plist" }
        else if path.hasPrefix(NSHomeDirectory() + "/Library/LaunchAgents/") { how = "Loaded by launchd from your LaunchAgents" }
        else if path.contains("/Library/LaunchAgents/") { how = "Loaded by launchd from a LaunchAgent for every user" }
        else { how = "Loaded into launchd from a plist (launchctl bootstrap or load)" }
        return (how, path, "path")
    }

    /// A command's role: `open`, AppleScript, or the tool itself.
    static func tool(_ name: String, path: String?) -> String {
        switch name {
        case "open": "the open command"
        case "osascript": "AppleScript (osascript)"
        case "Script Editor", "Shortcuts", "shortcuts": name
        default: name
        }
    }
}

/// What a launchd-started process's environment says about where it came from. LaunchServices passes the
/// requester's environment on to the app it launches (checked: an app opened from a Claude Code shell has its
/// CLAUDE_PID, CLAUDE_CODE_SESSION_ID, GHOSTTY_SURFACE_ID and PWD), and launchd's own environment has none of
/// these, so for a process whose parent is launchd they name the session that asked for it. Inferred, not
/// exact: an app passes the same variables on to whatever it launches in turn. Readable for your own processes.
struct EnvAttribution: Sendable, Hashable {
    var claudePid: pid_t?
    var claudeSession: String?
    var terminal: String?          // TERM_PROGRAM
    var terminalSession: String?   // GHOSTTY_SURFACE_ID, ITERM_SESSION_ID, TERM_SESSION_ID
    var tty: String?               // SSH_TTY
    var pwd: String?
    var user: String?
    /// `_`: the shell sets it to the command it runs, so an app opened from a shell with `open` carries
    /// `_=/usr/bin/open` (checked), with `osascript` `_=/usr/bin/osascript`.
    var command: String?
    /// SHLVL: present when the requester ran in a shell (Dock and Finder launches have none of these).
    var shellLevel: String?
    /// XPC_SERVICE_NAME as launchd set it: "application.<bundle id>.…" for a LaunchServices launch, else the job label.
    var xpcServiceName: String?

    var isEmpty: Bool { claudePid == nil && claudeSession == nil && terminal == nil && terminalSession == nil && tty == nil && pwd == nil && command == nil && shellLevel == nil }

    /// Whether the variables come from a shell session (the requester's), not launchd's own environment.
    var fromShell: Bool { command != nil || shellLevel != nil || terminal != nil || pwd != nil }

    static func read(_ pid: pid_t) -> EnvAttribution? {
        guard let env = Native.argsEnv(pid)?.env, !env.isEmpty else { return nil }
        var d: [String: String] = [:]
        for e in env { if let eq = e.firstIndex(of: "=") { d[String(e[..<eq])] = String(e[e.index(after: eq)...]) } }
        var a = EnvAttribution()
        a.claudePid = d["CLAUDE_PID"].flatMap { pid_t($0) }
        a.claudeSession = d["CLAUDE_CODE_SESSION_ID"]
        a.terminal = d["TERM_PROGRAM"]
        a.terminalSession = d["GHOSTTY_SURFACE_ID"] ?? d["ITERM_SESSION_ID"] ?? d["TERM_SESSION_ID"]
        a.tty = d["SSH_TTY"]
        a.pwd = d["PWD"]
        a.user = d["USER"]
        a.command = d["_"]
        a.shellLevel = d["SHLVL"]
        a.xpcServiceName = d["XPC_SERVICE_NAME"]
        return a.isEmpty && a.xpcServiceName == nil ? nil : a
    }

    /// TERM_PROGRAM as the app's name.
    var terminalName: String? {
        guard let t = terminal else { return nil }
        let known = ["ghostty": "Ghostty", "iTerm.app": "iTerm2", "Apple_Terminal": "Terminal", "vscode": "VS Code",
                     "WarpTerminal": "Warp", "WezTerm": "WezTerm", "tmux": "tmux", "zed": "Zed"]
        return known[t] ?? t
    }
}

extension LaunchWatcher {
    /// `--launch-watch <seconds>`: the watcher without the UI. Prints every launch it attributes, with what the
    /// Origin tab's Attribution card would say about it.
    static func bench(seconds: Double) {
        let w = LaunchWatcher.shared
        w.start()
        print("watching CoreServicesUIAgent for \(Int(seconds)) s (stream running: \(w.isWatching))")
        var shown: Set<pid_t> = []
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            Thread.sleep(forTimeInterval: 0.25)
            w.lock.lock(); let recs = w.records; w.lock.unlock()
            for (pid, r) in recs where !shown.contains(pid) {
                shown.insert(pid)
                let chain = r.launcher.map { "\($0.name)(\($0.pid))" }.joined(separator: " ← ")
                print("launch: \(r.bundleID) pid \(pid), requested by \(chain), launcher pid version \(r.launcherVersion.map(String.init) ?? "—")")
                let env = EnvAttribution.read(pid)
                let k = Native.process(pid)
                for m in LaunchMechanism.describe(ppid: k?.ppid ?? 1, parentName: nil, record: r, parentASN: nil, env: env, launchdLabel: nil) {
                    print("  [\(m.confidence.rawValue)] \(m.how) — source: \(m.source)")
                }
                if let e = env {
                    print("  env: claude pid \(e.claudePid.map(String.init) ?? "—"), session \(e.claudeSession.map { String($0.prefix(8)) } ?? "—"), terminal \(e.terminalName ?? "—"), pwd \(e.pwd ?? "—"), _ \(e.command ?? "—")")
                }
            }
        }
    }
}

extension LaunchMechanism {
    /// `--attribution <pid> [launchd label]`: the Attribution card's mechanism lines for one process, without the UI
    /// (no live launch record: that needs the app running when the launch happened).
    static func bench(pid: pid_t, label: String?) {
        guard let k = Native.process(pid) else { print("pid \(pid) not running"); return }
        let env = k.ppid == 1 ? EnvAttribution.read(pid) : nil
        let job: [String: String] = label.map { l in
            Dictionary(LaunchctlParser.parse(Launchd.printJob(l)).map { ($0.key, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        } ?? [:]
        for m in describe(ppid: k.ppid, parentName: Native.process(k.ppid)?.comm, record: nil, parentASN: nil, env: env,
                          launchdLabel: label ?? env?.xpcServiceName, job: job) {
            print("[\(m.confidence.rawValue)] \(m.how)" + (m.detail.map { "\n    \($0)" } ?? "") + "\n    source: \(m.source)")
        }
        if let l = label, !l.hasPrefix("application.") {
            let t0 = Date()
            if let r = LaunchdAttribution.lookup(label: l) {
                print("[exact] Loaded on behalf of \(r.bundleID ?? r.name ?? "?") (coalition \(r.coalition), leader pid \(r.leaderPid.map(String.init) ?? "—"))"
                      + String(format: " — looked up in %.1f s", Date().timeIntervalSince(t0)))
            } else {
                print(String(format: "launchd attribution: none found (%.1f s)", Date().timeIntervalSince(t0)))
            }
        }
    }
}

/// Which app a launchd job was loaded on behalf of. launchd keeps an attribution record per job (the jobs a
/// coalition loaded: `+[OSLaunchdJob copyJobsLoadedByCoalition:error:]`), but reading it needs a private
/// entitlement, even as root (checked: error 144, "Requestor lacks required entitlement", on the host and in a
/// SIP-on VM). launchservicesd has it, and asks once per app coalition whenever `lsappinfo list` runs; launchd
/// logs each answer at the default level, which any admin can read:
///
///     Queried 5 attributed services: caller=launchservicesd[644], coalition=5126
///       [0] => pid/46804/com.apple.SourceKitService.6.4.2.1.9_default [46839]
///       [3] => system/com.apple.CoreSimulator.simdiskimaged [9078]
///
/// (the list lines come from the same launchd thread as their header). So: run `lsappinfo list`, read those lines
/// back, find the job's label, and name the coalition with `xpc_coalition_copy_info` (no privileges needed).
/// Checked with a LaunchAgent bootstrapped from a Ghostty shell: it was listed under Ghostty's coalition. It
/// costs ~2 s and ~0.6 s of CPU (mostly `log show`), so it runs only when asked. Undocumented log lines: if
/// they change, this finds nothing rather than something wrong.
enum LaunchdAttribution {
    struct Result: Sendable, Hashable {
        var coalition: UInt64
        var leaderPid: pid_t?
        var name: String?
        var bundleID: String?
        var at: Date
    }

    static func lookup(label: String) -> Result? {
        let start = Date().addingTimeInterval(-1)
        _ = Shell.run("/usr/bin/lsappinfo", ["list"], timeout: 10)
        Thread.sleep(forTimeInterval: 0.8)   // launchd flushes its log in batches
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let out = Shell.run("/usr/bin/log", ["show", "--start", f.string(from: start), "--style", "ndjson", "--predicate",
                                             #"process == "launchd" AND (eventMessage BEGINSWITH "Queried" OR eventMessage ENDSWITH "/\#(label)" OR eventMessage CONTAINS "/\#(label) [")"#],
                            timeout: 20)
        var header: [Int: UInt64] = [:]   // launchd thread → coalition of the answer being listed
        var found: (UInt64, Date)?
        for line in out.split(separator: "\n") where line.first == "{" {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let msg = o["eventMessage"] as? String else { continue }
            let thread = (o["threadID"] as? NSNumber)?.intValue ?? 0
            if msg.hasPrefix("Queried"), let r = msg.range(of: "coalition=") {
                header[thread] = UInt64(msg[r.upperBound...].prefix { $0.isNumber })
            } else if msg.contains("=> "), let c = header[thread] {
                // "[3] => system/com.apple.CoreSimulator.simdiskimaged [9078]": the label is the last path component.
                let target = msg.components(separatedBy: "=> ").last ?? ""
                let name = target.split(separator: " ").first.map { $0.split(separator: "/").last.map(String.init) ?? "" } ?? ""
                if name == label { found = (c, Date()) }
            }
        }
        guard let (cid, at) = found else { return nil }
        var r = Result(coalition: cid, at: at)
        if let info = coalitionInfo(cid) {
            r.leaderPid = info.leader; r.name = info.name; r.bundleID = info.bundleID
        }
        return r
    }

    /// `xpc_coalition_copy_info`: the coalition's leader, launchd name and bundle id.
    static func coalitionInfo(_ cid: UInt64) -> (leader: pid_t?, name: String?, bundleID: String?)? {
        typealias Fn = @convention(c) (UInt64) -> Unmanaged<AnyObject>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "xpc_coalition_copy_info"),
              let obj = unsafeBitCast(sym, to: Fn.self)(cid)?.takeRetainedValue() else { return nil }
        let d = obj as! xpc_object_t
        guard xpc_get_type(d) == XPC_TYPE_DICTIONARY else { return nil }
        let leader = xpc_dictionary_get_value(d, "leader-pid").map { pid_t(xpc_int64_get_value($0)) }
        let name = xpc_dictionary_get_string(d, "name").map { String(cString: $0) }
        let bid = xpc_dictionary_get_string(d, "bundle_identifier").map { String(cString: $0) }
        return (leader, name, bid)
    }
}
