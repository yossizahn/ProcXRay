import AppKit
import SwiftUI

/// Opens a syscall's section-2 man page in the best viewer at hand: Dash, else `man` through x-man-page:// (Terminal,
/// iTerm or whatever claims it) when the page is installed, else Apple's pages on the web.
enum ManPage {
    struct Page: Hashable, Sendable {
        let name: String
        let section: Int
        var title: String { "\(name)(\(section))" }
    }

    /// The man page for a traced name, if macOS has one: section 2 for syscalls ("open_nocancel" → open(2),
    /// "stat64_extended" → stat64(2)), section 3 for dyld's calls (dlopen(3)).
    static func page(for name: String) -> Page? {
        if section3.contains(name) { return Page(name: name, section: 3) }
        var n = name
        if n.hasSuffix("_nocancel") { n.removeLast(9) }
        if n.hasSuffix("_extended") { n.removeLast(9) }
        for c in [n, n.hasPrefix("__") ? String(n.dropFirst(2)) : n, n.hasSuffix("64") ? String(n.dropLast(2)) : n]
        where section2.contains(c) { return Page(name: c, section: 2) }
        return nil
    }

    /// The library calls the trace shows (dyld's, SyscallRecord.isLibraryCall) that have a page.
    static let section3: Set<String> = ["dlopen", "dlsym", "dlclose", "dladdr"]

    static func help(_ page: Page) -> String { "Open the \(page.title) man page" }

    static func open(_ page: Page) {
        Task.detached(priority: .userInitiated) {
            let url = viewerURL(page)
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
        }
    }

    /// In order: Dash, `man` (only when the page is installed: sections 2 and 3 come with Xcode or the Command Line
    /// Tools, not with macOS), the web.
    private static func viewerURL(_ page: Page) -> URL {
        // "open(2)" puts the section-2 page first in Dash's results; a bare "open" lists open(1) alongside.
        if let dash = URL(string: "dash-plugin://keys=manpages&query=\(page.name)(\(page.section))"),
           NSWorkspace.shared.urlForApplication(toOpen: dash) != nil { return dash }
        if let term = URL(string: "x-man-page://\(page.section)/\(page.name)"),
           NSWorkspace.shared.urlForApplication(toOpen: term) != nil, installed(page) { return term }
        return URL(string: "https://keith.github.io/xcode-man-pages/\(page.name).\(page.section).html")!
    }

    private static func installed(_ page: Page) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/man")
        p.arguments = ["-w", String(page.section), page.name]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// The section-2 pages in the macOS SDK whose names trace.codes uses (MacOSX.sdk/usr/share/man/man2).
    static let section2: Set<String> = Set("""
        accept access acct adjtime aio_cancel aio_error aio_fsync aio_read aio_readv aio_return aio_suspend aio_write
        aio_writev audit auditctl auditon bind chflags chmod chown chroot clonefileat connect connectx disconnectx
        exchangedata execve faccessat fchflags fchmod fchmodat fchown fchownat fclonefileat fgetattrlist fgetxattr
        fhopen flistxattr fork freadlink fremovexattr fsetattrlist fsetxattr fsgetpath fstatat fstatfs fstatfs64
        fsync ftruncate futimes getattrlist getattrlistat getattrlistbulk getaudit_addr getauid getdirentries
        getdirentriesattr getegid getentropy geteuid getfh getfsstat getgid getgroups gethostuuid getitimer getlogin
        getpeername getpgid getpgrp getpid getppid getpriority getrlimit getrusage getsid getsockname getsockopt
        gettimeofday getuid getumask getxattr ioctl issetugid kevent kevent_qos kevent64 kill kqueue lchown link
        linkat lio_listio listen listxattr lseek lstat lstat64 madvise mincore minherit mkdir mkdirat mkfifo mkfifoat
        mknod mknodat mlock mmap mount mprotect msync munlock munmap nfssvc open openat pathconf pipe pipe2 poll
        posix_spawn pread pselect pthread_kill pthread_sigmask ptrace pwrite quotactl read readlink readlinkat readv
        reboot recvfrom recvmsg removexattr rename renameat renameatx_np revoke rmdir searchfs select sem_close
        sem_open sem_post sem_trywait sem_unlink sem_wait semctl semget semop sendfile sendmsg sendto setattrlist
        setattrlistat setaudit_addr setauid setegid seteuid setgid setgroups setitimer setlogin setpgid setpriority
        setregid setreuid setrlimit setsid setsockopt settimeofday setuid setxattr shm_open shm_unlink shmat shmctl
        shmdt shmget shutdown sigaction sigaltstack sigpending sigprocmask sigsuspend sigwait socket socketpair stat
        stat64 statfs statfs64 symlink symlinkat sync truncate umask undelete unlink unlinkat unmount utimes vfork
        wait4 write writev
        """.split(whereSeparator: \.isWhitespace).map(String.init))
}
