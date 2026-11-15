import AppKit
import SwiftUI

/// Opens a syscall's section-2 man page in the best viewer at hand: Dash, else `man` through x-man-page:// (Terminal,
/// iTerm or whatever claims it) when the page is installed, else Apple's pages on the web.
enum ManPage {
    /// The section-2 page for a traced name, if macOS has one: "open_nocancel" → "open", "stat64_extended" → "stat64".
    static func page(for name: String) -> String? {
        var n = name
        if n.hasSuffix("_nocancel") { n.removeLast(9) }
        if n.hasSuffix("_extended") { n.removeLast(9) }
        for c in [n, n.hasPrefix("__") ? String(n.dropFirst(2)) : n, n.hasSuffix("64") ? String(n.dropLast(2)) : n]
        where section2.contains(c) { return c }
        return nil
    }

    static func help(_ page: String) -> String { "Open the \(page)(2) man page" }

    static func open(_ page: String) {
        Task.detached(priority: .userInitiated) {
            let url = viewerURL(page)
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
        }
    }

    /// In order: Dash, `man` (only when the page is installed: section 2 comes with Xcode or the Command Line Tools,
    /// not with macOS), the web.
    private static func viewerURL(_ page: String) -> URL {
        // "open(2)" puts the section-2 page first in Dash's results; a bare "open" lists open(1) alongside.
        if let dash = URL(string: "dash-plugin://keys=manpages&query=\(page)(2)"),
           NSWorkspace.shared.urlForApplication(toOpen: dash) != nil { return dash }
        if let term = URL(string: "x-man-page://2/\(page)"),
           NSWorkspace.shared.urlForApplication(toOpen: term) != nil, installed(page) { return term }
        return URL(string: "https://keith.github.io/xcode-man-pages/\(page).2.html")!
    }

    private static func installed(_ page: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/man")
        p.arguments = ["-w", "2", page]
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

/// A small book button that opens a syscall's man page; nothing when it has none.
struct ManPageButton: View {
    let name: String
    var body: some View {
        if let page = ManPage.page(for: name) {
            Button { ManPage.open(page) } label: { Image(systemName: "book") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(ManPage.help(page))
                .accessibilityLabel(ManPage.help(page))
        }
    }
}
