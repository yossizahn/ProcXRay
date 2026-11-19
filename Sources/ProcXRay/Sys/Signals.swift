import AppKit

/// What the Send Signal menus offer: a Unix signal, or for an app the quit Apple Event that ⌘Q sends
/// (`NSRunningApplication.terminate`), which lets the app save, clean up or refuse.
enum ProcSignal: Hashable, Identifiable {
    case quit
    case unix(Int32)

    var id: Int32 { if case .unix(let n) = self { n } else { 0 } }

    /// The polite ones first, then kill, suspend and resume.
    static let common: [ProcSignal] = [.unix(SIGTERM), .unix(SIGINT), .unix(SIGHUP), .unix(SIGKILL), .unix(SIGSTOP), .unix(SIGCONT)]
    /// Every other signal, by number.
    static let others: [ProcSignal] = (1...31).map { ProcSignal.unix($0) }.filter { !common.contains($0) }

    /// "SIGTERM"; "Quit" for the Apple Event.
    var name: String {
        guard case .unix(let n) = self else { return "Quit" }
        return Self.table[n]?.name ?? "SIG\(n)"
    }
    /// Very terse: what it is, then what it does to a process that doesn't handle it.
    var detail: String {
        guard case .unix(let n) = self else { return "as ⌘Q; the app may ask to save (Apple Event)" }
        return Self.table[n]?.detail ?? ""
    }
    /// A menu row: "15  SIGTERM — ask to exit". Figure spaces keep one-digit numbers lined up.
    var menuTitle: String {
        guard case .unix(let n) = self else { return "Quit — \(detail)" }
        return (n < 10 ? "\u{2007}" : "") + "\(n)  \(name) — \(detail)"
    }
    /// For dialogs: "SIGTERM (15)", "Quit".
    var label: String {
        guard case .unix(let n) = self else { return "Quit" }
        return "\(name) (\(n))"
    }
    /// Sent without asking: by default these resume a process or are ignored.
    var isHarmless: Bool {
        guard case .unix(let n) = self else { return false }
        return [SIGCONT, SIGURG, SIGCHLD, SIGIO, SIGWINCH, SIGINFO].contains(n)
    }

    private static let table: [Int32: (name: String, detail: String)] = [
        SIGHUP: ("SIGHUP", "hang up; daemons often reload"),
        SIGINT: ("SIGINT", "interrupt, as Ctrl-C"),
        SIGQUIT: ("SIGQUIT", "quit, as Ctrl-\\; crashes"),
        SIGILL: ("SIGILL", "illegal instruction; crashes"),
        SIGTRAP: ("SIGTRAP", "breakpoint trap; crashes"),
        SIGABRT: ("SIGABRT", "abort(); crashes"),
        SIGEMT: ("SIGEMT", "emulator trap; crashes"),
        SIGFPE: ("SIGFPE", "arithmetic error; crashes"),
        SIGKILL: ("SIGKILL", "kill at once; can't be caught"),
        SIGBUS: ("SIGBUS", "bus error; crashes"),
        SIGSEGV: ("SIGSEGV", "bad memory access; crashes"),
        SIGSYS: ("SIGSYS", "bad system call; crashes"),
        SIGPIPE: ("SIGPIPE", "broken pipe; exits"),
        SIGALRM: ("SIGALRM", "alarm timer; exits"),
        SIGTERM: ("SIGTERM", "ask to exit; can be caught"),
        SIGURG: ("SIGURG", "urgent socket data; ignored"),
        SIGSTOP: ("SIGSTOP", "suspend; can't be caught"),
        SIGTSTP: ("SIGTSTP", "suspend, as Ctrl-Z; can be caught"),
        SIGCONT: ("SIGCONT", "resume if suspended"),
        SIGCHLD: ("SIGCHLD", "child exited; ignored"),
        SIGTTIN: ("SIGTTIN", "background terminal read; suspends"),
        SIGTTOU: ("SIGTTOU", "background terminal write; suspends"),
        SIGIO: ("SIGIO", "I/O ready; ignored"),
        SIGXCPU: ("SIGXCPU", "CPU time limit; crashes"),
        SIGXFSZ: ("SIGXFSZ", "file size limit; crashes"),
        SIGVTALRM: ("SIGVTALRM", "virtual timer; exits"),
        SIGPROF: ("SIGPROF", "profiling timer; exits"),
        SIGWINCH: ("SIGWINCH", "window resized; ignored"),
        SIGINFO: ("SIGINFO", "status request, as Ctrl-T; ignored"),
        SIGUSR1: ("SIGUSR1", "app-defined; exits if unhandled"),
        SIGUSR2: ("SIGUSR2", "app-defined; exits if unhandled"),
    ]

    /// Fills an AppKit menu: Quit (apps only) and the common signals, a separator, the rest. Number and
    /// explanation are dimmed so the names stand out.
    static func fill(_ menu: NSMenu, isApp: Bool, _ send: @escaping (ProcSignal) -> Void) {
        func add(_ s: ProcSignal) {
            let a = MenuFire { send(s) }
            let mi = NSMenuItem(title: s.menuTitle, action: #selector(MenuFire.fire), keyEquivalent: "")
            mi.target = a
            mi.representedObject = a    // keeps the target alive while the menu is up
            mi.attributedTitle = s.attributedTitle
            menu.addItem(mi)
        }
        if isApp { add(.quit); menu.addItem(.separator()) }
        common.forEach(add)
        menu.addItem(.separator())
        others.forEach(add)
    }

    private var attributedTitle: NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let dim: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let s = NSMutableAttributedString()
        if case .unix(let n) = self {
            let num = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
            s.append(NSAttributedString(string: (n < 10 ? "\u{2007}" : "") + "\(n)  ",
                                        attributes: [.font: num, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        s.append(NSAttributedString(string: name, attributes: [.font: font]))
        s.append(NSAttributedString(string: "  \(detail)", attributes: dim))
        return s
    }

    private final class MenuFire: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}
