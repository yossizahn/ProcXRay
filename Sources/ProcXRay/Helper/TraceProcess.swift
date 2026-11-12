import Foundation

/// A long-running tool whose output is read while it runs (Shell.exec only returns once the tool exits).
/// Used by the helper for `ktrace trace`: stdout is buffered until the app reads it, stderr is kept apart
/// so ktrace's own messages (busy, lost events) reach the app as notes, not as broken JSON lines.
final class TraceProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var exited = false
    private var exitStatus: Int32 = 0
    private var stopRequested = false
    private var pending = Data()
    private var notes = ""
    private var droppedBytes = 0
    private let maxPending: Int

    init(maxPending: Int) { self.maxPending = maxPending }

    /// nil when started, else why not.
    func start(_ path: String, _ args: [String]) -> String? {
        var out: [Int32] = [-1, -1], err: [Int32] = [-1, -1]
        guard pipe(&out) == 0 else { return "no pipe" }
        guard pipe(&err) == 0 else { close(out[0]); close(out[1]); return "no pipe" }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out[1], 1)
        posix_spawn_file_actions_adddup2(&actions, err[1], 2)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
        var child: pid_t = 0
        let rc = posix_spawn(&child, path, &actions, &attr, argv, environ)
        argv.forEach { free($0) }
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attr)
        close(out[1]); close(err[1])
        guard rc == 0 else {
            close(out[0]); close(err[0])
            return "failed to run \(path): \(String(cString: strerror(rc)))"
        }
        lock.lock(); pid = child; lock.unlock()
        let (o, e) = (out[0], err[0])
        Thread.detachNewThread { [self] in pump(out: o, err: e) }
        return nil
    }

    /// Complete lines written since the last call (at most `max` bytes), whether the tool still runs, and
    /// notes (stderr, dropped output, how it ended) since the last call.
    func read(max: Int) -> (Data, Bool, String) {
        lock.lock(); defer { lock.unlock() }
        var chunk = Data()
        let limit = pending.startIndex + min(pending.count, max)
        if let nl = pending[pending.startIndex..<limit].lastIndex(of: 0x0A) {
            chunk = Data(pending[pending.startIndex...nl])
            pending.removeSubrange(pending.startIndex...nl)
        } else if exited {
            chunk = pending; pending = Data()   // a last line without a newline
        }
        var n = notes
        notes = ""
        if droppedBytes > 0 {
            n += "Dropped \(droppedBytes) bytes of trace output: the app fell behind.\n"
            droppedBytes = 0
        }
        return (chunk, !exited || !pending.isEmpty, n)
    }

    /// SIGINT (ktrace's own Ctrl-C path, which hands kdebug back cleanly), then SIGKILL if it hangs on.
    func stop() {
        lock.lock()
        let run = !exited && pid > 0 && !stopRequested
        stopRequested = true
        let p = pid
        lock.unlock()
        guard run else { return }
        signal(p, SIGINT)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [self] in signal(p, SIGKILL) }
    }

    /// Never signals a pid that was reaped (and so may belong to another process by now).
    private func signal(_ p: pid_t, _ sig: Int32) {
        lock.lock(); defer { lock.unlock() }
        if !exited { kill(p, sig) }
    }

    private func pump(out: Int32, err: Int32) {
        var fds = [pollfd(fd: out, events: Int16(POLLIN), revents: 0), pollfd(fd: err, events: Int16(POLLIN), revents: 0)]
        var open = [true, true]
        var buf = [UInt8](repeating: 0, count: 256 << 10)
        while open[0] || open[1] {
            for i in 0..<2 { fds[i].fd = open[i] ? (i == 0 ? out : err) : -1; fds[i].revents = 0 }
            let r = poll(&fds, 2, 500)
            if r < 0 && errno != EINTR { break }
            for i in 0..<2 where open[i] && fds[i].revents != 0 {
                let n = Darwin.read(fds[i].fd, &buf, buf.count)
                if n == 0 || (n < 0 && errno != EINTR && errno != EAGAIN) { open[i] = false; continue }
                guard n > 0 else { continue }
                lock.lock()
                if i == 0 {
                    if pending.count + n > maxPending { droppedBytes += n } else { pending.append(contentsOf: buf[0..<n]) }
                } else if notes.utf8.count < 64 << 10 {
                    notes += String(decoding: buf[0..<n], as: UTF8.self)
                }
                lock.unlock()
            }
        }
        close(out); close(err)
        var st: Int32 = 0
        lock.lock()
        let p = pid
        lock.unlock()
        var r: pid_t
        repeat { r = waitpid(p, &st, 0) } while r < 0 && errno == EINTR
        lock.lock()
        exited = true
        let low = st & 0x7f
        exitStatus = low == 0 ? (st >> 8) & 0xff : low
        if !stopRequested && exitStatus != 0 { notes += "ktrace exited with status \(exitStatus).\n" }
        lock.unlock()
    }
}
