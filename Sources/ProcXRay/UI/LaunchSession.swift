import AppKit
import Foundation

/// What a launched program writes to stdout and stderr, for the Launch window's Output pane: read from pipes (a
/// spawn, direct or the helper's) or followed in files (launchd, open).
@MainActor @Observable
final class OutputLog {
    struct Chunk: Identifiable {
        let id: Int
        /// 1: stdout, 2: stderr.
        let stream: Int
        let text: String
    }
    private(set) var chunks: [Chunk] = []
    private(set) var revision = 0
    private(set) var dropped = 0
    private var nextID = 0
    private var bytes = 0
    private var generation = 0
    static let cap = 4 << 20

    func reset() -> Int {
        generation += 1
        chunks = []; bytes = 0; dropped = 0; revision += 1
        return generation
    }

    func append(_ text: String, stream: Int, generation g: Int) {
        guard g == generation, !text.isEmpty else { return }
        chunks.append(Chunk(id: nextID, stream: stream, text: text))
        nextID += 1
        bytes += text.utf8.count
        while bytes > Self.cap, chunks.count > 1 {
            let c = chunks.removeFirst()
            bytes -= c.text.utf8.count
            dropped += c.text.utf8.count
        }
        revision += 1
    }

    /// Text in whole lines where it can: a read that ends mid-line keeps the rest for the next one.
    private struct LineBuffer {
        var pending = Data()
        mutating func take(_ data: Data, flush: Bool) -> String {
            pending.append(data)
            if flush || pending.count > 64 << 10 {
                defer { pending = Data() }
                return String(decoding: pending, as: UTF8.self)
            }
            guard let nl = pending.lastIndex(of: 0x0a) else { return "" }
            let line = pending[...nl]
            pending = Data(pending[pending.index(after: nl)...])
            return String(decoding: line, as: UTF8.self)
        }
    }

    /// Reads a pipe until its end, on a thread of its own. `handle` owns `fd` when given (one from the helper);
    /// otherwise the fd is closed at the end.
    nonisolated func read(fd: Int32, handle: FileHandle?, stream: Int, generation g: Int) {
        Thread.detachNewThread { [weak self] in
            var buf = [UInt8](repeating: 0, count: 65536)
            var lines = LineBuffer()
            while true {
                let n = Darwin.read(fd, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                let end = n <= 0
                let text = lines.take(end ? Data() : Data(buf[0..<n]), flush: end)
                if !text.isEmpty { Task { @MainActor in self?.append(text, stream: stream, generation: g) } }
                if end { break }
            }
            if let handle { try? handle.close() } else { close(fd) }
        }
    }

    /// Follows a file as it grows, until `finished` says so (checked after each read that found nothing new).
    nonisolated func follow(path: String, stream: Int, generation g: Int, finished: @escaping @Sendable () async -> Bool) {
        Task.detached { [weak self] in
            var lines = LineBuffer()
            var handle: FileHandle?
            for _ in 0..<40 where handle == nil {
                handle = FileHandle(forReadingAtPath: path)
                if handle == nil { try? await Task.sleep(for: .milliseconds(250)) }
            }
            guard let handle else { return }
            defer { try? handle.close() }
            var quiet = 0
            while true {
                let data = (try? handle.readToEnd()) ?? nil
                if let data, !data.isEmpty {
                    quiet = 0
                    let text = lines.take(data, flush: false)
                    if !text.isEmpty { await self?.append(text, stream: stream, generation: g) }
                    continue
                }
                if await finished() {
                    // Once more after it ended: what it wrote last.
                    quiet += 1
                    if quiet > 2 {
                        let text = lines.take(Data(), flush: true)
                        if !text.isEmpty { await self?.append(text, stream: stream, generation: g) }
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

/// One launch from the Launch window: the method's way of starting it, then its output, its trace and how it
/// ended. A new launch replaces the last.
@MainActor @Observable
final class LaunchSession {
    private(set) var child: Launcher.Child?
    private(set) var method: LaunchSpec.Method = .spawn
    private(set) var launching = false
    /// Why it couldn't be launched.
    var error: String?
    /// How it ended, once it has.
    private(set) var ended: String?
    /// What to know about this launch (it was already running, the trace missed its start…).
    private(set) var notes: [String] = []
    /// The launchd job it runs in, while loaded.
    private(set) var jobLabel: String?
    /// Stopped (started suspended and not resumed yet).
    private(set) var suspended = false
    let output = OutputLog()
    private(set) var tracer = SyscallTracer()
    private(set) var traceTarget: TraceTarget?
    private(set) var generation = 0

    var isRunning: Bool { child != nil && ended == nil }

    func launch(_ spec: LaunchSpec) async {
        guard !launching else { return }
        error = nil
        let url = URL(fileURLWithPath: (spec.path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath)
        guard let exe = Launcher.executable(for: url) else {
            error = spec.path.isEmpty ? "Choose an app or a program first." : "\(url.path) isn't an app or an executable file."
            return
        }
        if spec.method.needsApp && !Launcher.isApp(url) {
            error = "\(spec.method.label) starts apps only; choose an app bundle, or launch this program directly."
            return
        }
        let name = Launcher.displayName(for: url)
        tracer.stop()
        generation += 1
        let gen = generation
        child = nil; ended = nil; notes = []; suspended = false; traceTarget = nil
        let og = output.reset()
        launching = true
        defer { launching = false }
        let holdStopped = spec.method.startsSuspended && (spec.trace || (spec.method != .launchd && spec.spawn.leaveSuspended))
        var started: Launcher.Child?
        var suspendedControl: SyscallTracer.Suspended?

        switch spec.method {
        case .spawn, .root:
            var r = request(spec, executable: exe, name: name, suspended: holdStopped)
            if spec.method == .root {
                let who = spec.root.user.trimmingCharacters(in: .whitespaces)
                let account = who.isEmpty ? Launcher.Account.lookup("0") : Launcher.Account.lookup(who)
                guard let account else { error = "No user “\(who)”."; return }
                var gid = account.gid
                if !spec.root.group.isEmpty {
                    guard let g = Launcher.group(spec.root.group) else { error = "No group “\(spec.root.group)”."; return }
                    gid = g
                }
                r.uid = account.uid
                r.gid = gid
                r.groups = spec.root.supplementaryGroups ? [gid] + account.groups.filter { $0 != gid } : [gid]
                r.environment = spec.resolvedEnvironment(user: account)
                if r.workingDirectory == nil { r.workingDirectory = "/" }
                let prompt = "Proc X-Ray wants to launch “\(name)” as \(account.name)."
                let req = r
                let result = await Task.detached { () -> Result<(Launcher.Child, FileHandle?, FileHandle?), LaunchError> in
                    switch AdminAuthorization.request(prompt: prompt) {
                    case .failure(let e): return .failure(e)
                    case .success(let grant):
                        defer { grant.release() }
                        return HelperClient.shared.launch(req, authorization: grant.externalForm)
                    }
                }.value
                switch result {
                case .failure(let e): error = e.message; return
                case .success(let (c, out, err)):
                    started = c
                    if let out { output.read(fd: out.fileDescriptor, handle: out, stream: 1, generation: og) }
                    if let err { output.read(fd: err.fileDescriptor, handle: err, stream: 2, generation: og) }
                    let pid = c.pid
                    suspendedControl = SyscallTracer.Suspended(
                        resume: { HelperClient.shared.launched(pid: pid, signal: SIGCONT) },
                        kill: { HelperClient.shared.launched(pid: pid, signal: SIGKILL) })
                }
            } else {
                let req = r
                switch await Task.detached(operation: { Launcher.spawn(req) }).value {
                case .failure(let e): error = e.message; return
                case .success(let s):
                    started = s.child
                    if let fd = s.stdout { output.read(fd: fd, handle: nil, stream: 1, generation: og) }
                    if let fd = s.stderr { output.read(fd: fd, handle: nil, stream: 2, generation: og) }
                    suspendedControl = .local(s.child.pid)
                }
            }

        case .launchd:
            let files = LaunchMethods.outputFiles(spec)
            let stopped = spec.trace || spec.launchd.waitForDebugger
            switch await Task.detached(operation: { LaunchMethods.Launchd.start(spec, executable: exe, name: name, output: files, stopped: stopped) }).value {
            case .failure(let e): error = e.message; return
            case .success(let (c, label)):
                started = c
                jobLabel = label
                follow(files, generation: og)
                suspendedControl = .local(c.pid)
                if stopped && !spec.trace { suspended = true }
                if stopped && !spec.trace { notes.append("Started stopped (WaitForDebugger): resume it to let it run.") }
            }

        case .launchServices:
            switch await LaunchMethods.launchServices(spec, app: url, name: name) {
            case .failure(let e): error = e.message; return
            case .success(let (c, existing)):
                started = c
                if existing { notes.append("\(name) was already running: Launch Services brought it forward (pid \(c.pid)) instead of starting it, so none of this launch's settings apply to it.") }
            }

        case .open:
            let files = LaunchMethods.outputFiles(spec)
            let args = LaunchMethods.openArguments(spec, app: url.path, output: files)
            let since = Date()
            let openDone = OpenWatch()
            Task.detached {
                // -W keeps open running until the app quits.
                let r = Shell.exec("/usr/bin/open", args, timeout: spec.open.wait ? 7 * 86400 : 30)
                await openDone.finish(r.status == 0 ? nil : r.output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            var found: Launcher.Child?
            for _ in 0..<60 {
                if let c = await Task.detached(operation: { LaunchMethods.newest(running: exe, since: since) }).value { found = c; break }
                if let failure = await openDone.failure { error = "open failed: \(failure)"; return }
                if await openDone.done && !spec.open.wait { break }
                try? await Task.sleep(for: .milliseconds(150))
            }
            if found == nil, let c = await Task.detached(operation: { LaunchMethods.running(exe) }).value {
                found = c
                notes.append("\(name) was already running: open brought it forward (pid \(c.pid)) instead of starting it.")
            }
            guard let found else { error = "open ran, but no new \(name) process turned up."; return }
            started = Launcher.Child(pid: found.pid, start: found.start, name: name, executable: exe)
            follow(files, generation: og)
        }

        guard let c = started, gen == generation else { return }
        child = c
        if spec.trace {
            let t = SyscallTracer()
            tracer = t
            traceTarget = TraceTarget(pid: c.pid, start: c.start, name: c.name)
            var control = holdStopped ? suspendedControl : nil
            if let s = control, spec.spawn.leaveSuspended, spec.method != .launchd {
                control = SyscallTracer.Suspended(resume: {}, kill: s.kill)
                suspended = true
                notes.append("Left stopped once the trace started: resume it to let it run.")
            }
            if !spec.method.startsSuspended {
                notes.append("The trace started once \(spec.method == .open ? "open" : "Launch Services") had started it: its first moments aren't in it. Only a direct spawn, the helper or a launchd job can hold it before its first instruction.")
            }
            t.start(pid: c.pid, start: c.start, stacks: spec.stacks, resume: control)
        } else if holdStopped {
            suspended = true
            if spec.method != .launchd { notes.append("Started suspended: resume it to let it run.") }
        }
        watchExit(c, method: spec.method, generation: gen)
        self.method = spec.method
    }

    /// The posix_spawn request for a direct spawn (and the base of the helper's).
    private func request(_ spec: LaunchSpec, executable: String, name: String, suspended: Bool) -> Launcher.Request {
        func path(_ p: String) -> String { (p as NSString).expandingTildeInPath }
        func out(_ o: LaunchSpec.Output, _ p: String) -> Launcher.Stdio {
            switch o {
            case .show: .pipe
            case .null: .null
            case .file: p.isEmpty ? .null : .file(path(p), append: spec.appendOutput)
            case .stdout: .sameAsStdout
            }
        }
        var r = Launcher.Request(path: executable,
                                 argv: [spec.argv0.isEmpty ? executable : spec.argv0] + spec.argumentList,
                                 environment: spec.resolvedEnvironment(user: .current),
                                 name: name)
        if !spec.workingDirectory.isEmpty { r.workingDirectory = path(spec.workingDirectory) }
        r.stdin = spec.stdin == .file && !spec.stdinPath.isEmpty ? .file(path(spec.stdinPath), append: false) : .null
        r.stdout = out(spec.stdout, spec.stdoutPath)
        r.stderr = spec.stderr == .stdout && spec.stdout == .null ? .null : out(spec.stderr, spec.stderrPath)
        r.spawn = spec.spawn
        r.process = spec.process
        r.suspended = suspended
        return r
    }

    private func follow(_ files: LaunchMethods.OutputFiles, generation og: Int) {
        let gen = generation
        for (path, stream) in files.shown {
            output.follow(path: path, stream: stream, generation: og) { [weak self] in
                await self?.isOver(gen) ?? true
            }
        }
    }

    private func isOver(_ gen: Int) -> Bool { generation != gen || ended != nil }

    private func watchExit(_ c: Launcher.Child, method: LaunchSpec.Method, generation gen: Int) {
        let label = jobLabel
        Task { [weak self] in
            while let self, self.generation == gen, self.ended == nil {
                let pid = c.pid
                switch method {
                case .spawn:
                    if let e = Launcher.exit(of: pid) { self.end(e.codeSigning ? e.summary + " Launch it with Launch Services or open instead." : e.summary); return }
                case .root:
                    let r = await Task.detached(operation: { HelperClient.shared.launched(pid: pid) }).value
                    if let e = r?.exit { self.end(e.summary); return }
                    if r == nil, !Native.isSame(pid, start: c.start) { self.end("It exited."); return }
                case .launchd:
                    if !Native.isSame(pid, start: c.start) {
                        let info = await Task.detached(operation: {
                            Shell.exec("/bin/launchctl", ["print", "\(LaunchMethods.Launchd.domain)/\(label ?? "")"], timeout: 5).output
                        }).value
                        let code = LaunchMethods.Launchd.field(info, "last exit code") ?? LaunchMethods.Launchd.field(info, "last exit reason")
                        self.end(code.map { "It exited (launchd: last exit \($0))." } ?? "It exited.")
                        return
                    }
                case .launchServices, .open:
                    if !Native.isSame(pid, start: c.start) { self.end("It exited."); return }
                }
                try? await Task.sleep(for: .milliseconds(method == .root ? 500 : 250))
            }
        }
    }

    private func end(_ why: String) {
        ended = why
        suspended = false
    }

    /// Sends a signal to the launched program (through the helper for one it started).
    func signal(_ sig: Int32) {
        guard let c = child, ended == nil else { return }
        if method == .root {
            let pid = c.pid
            Task.detached { HelperClient.shared.launched(pid: pid, signal: sig) }
        } else if Native.isSame(c.pid, start: c.start) {
            kill(c.pid, sig)
        }
        if sig == SIGCONT { suspended = false }
        if sig == SIGSTOP { suspended = true }
    }

    func stopTrace() { tracer.stop() }

    /// Unloads the launchd job (killing the program if it still runs).
    func removeJob() {
        guard let label = jobLabel else { return }
        jobLabel = nil
        Task.detached { LaunchMethods.Launchd.remove(label) }
    }
}

/// Whether the open command has finished, and how.
actor OpenWatch {
    private(set) var done = false
    private(set) var failure: String?
    func finish(_ failure: String?) { done = true; self.failure = failure }
}
