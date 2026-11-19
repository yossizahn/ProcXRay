import Darwin
import Foundation

/// Starts a program suspended (POSIX_SPAWN_START_SUSPENDED: as if it got SIGSTOP before its first instruction), so a
/// trace can attach before it runs and catch everything from dyld's first image load on. SIGCONT lets it run.
///
/// It runs as this app's user, a child of this app: an app bundle's executable is started directly, not through
/// LaunchServices, so it gets no open-document or reopen events at launch and no LaunchServices launch options.
/// Its standard input and output go to /dev/null, and it inherits no other descriptors.
enum Launcher {
    struct Child: Sendable, Equatable {
        let pid: Int32
        let start: Date
        /// The app's name, or the program's file name.
        let name: String
        let executable: String
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

    static func displayName(for url: URL) -> String {
        if url.pathExtension == "app" {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return url.lastPathComponent
    }

    /// Starts `path` suspended; resume it with `resume`, or `kill` it if it's not wanted after all.
    static func spawnSuspended(_ path: String, arguments: [String], name: String) -> Result<Child, LaunchError> {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Suspended; only the descriptors set up below are inherited; default signal handling, nothing blocked
        // (the app's own mask and ignored signals would otherwise carry over).
        let START_SUSPENDED: Int32 = 0x0080, CLOEXEC_DEFAULT: Int32 = 0x4000
        posix_spawnattr_setflags(&attr, Int16(START_SUSPENDED | CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var none = sigset_t(), all = sigset_t()
        sigemptyset(&none); sigfillset(&all)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_setsigdefault(&attr, &all)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        let argv = ([path] + arguments).map { strdup($0) }
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = (argv + [nil]).withUnsafeBufferPointer { a in
            posix_spawn(&pid, path, &actions, &attr, a.baseAddress, environ)
        }
        guard rc == 0 else { return .failure(LaunchError(message: "Couldn't start \(name): \(String(cString: strerror(rc))).")) }
        reap(pid)
        guard let start = Native.process(pid)?.start else {
            kill(pid, SIGKILL)
            return .failure(LaunchError(message: "\(name) started but its process couldn't be read."))
        }
        return .success(Child(pid: pid, start: start, name: name, executable: path))
    }

    static func resume(_ pid: Int32) { kill(pid, SIGCONT) }

    /// A child that exits stays a zombie until its parent waits for it: wait on a thread of its own.
    private static func reap(_ pid: pid_t) {
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
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
