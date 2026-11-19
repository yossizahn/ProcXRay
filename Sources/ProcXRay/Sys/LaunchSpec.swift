import Darwin
import Foundation

/// Everything the Launch window can set, for every way of starting a program (File ▸ Launch…). Saved as one JSON
/// default, so a method's knobs keep their values while another method is chosen.
///
/// What each knob does was checked on macOS 27.2 by launching a program that reports its own state; knobs that
/// macOS accepts but ignores, or refuses without an entitlement Proc X-Ray can't have, aren't offered:
/// - posix_spawn coalitions (joining one or creating one: EPERM even as root), personas (EPERM), sandbox spawn
///   attributes (the child is SIGKILLed) and the per-process fd, thread, port and kqworkloop limits (accepted, not
///   enforced). A new coalition comes from launchd: a launchd job or a Launch Services launch.
/// - Launch Services' own launch modifiers (launch stopped, no ASLR, umask, uid): NSWorkspace ignores them.
struct LaunchSpec: Codable, Equatable, Sendable {
    enum Method: String, Codable, CaseIterable, Identifiable, Sendable {
        /// posix_spawn, as Proc X-Ray's child and user.
        case spawn
        /// posix_spawn in the root helper, as root or any user, after an administrator's authorization.
        case root
        /// A launchd job in the user's GUI domain (launchctl bootstrap gui/<uid>).
        case launchd
        /// NSWorkspace.openApplication: how the Finder and the Dock start an app.
        case launchServices
        /// /usr/bin/open, Launch Services' command line, with its stdio and wait options.
        case open

        var id: String { rawValue }
        var label: String {
            switch self {
            case .spawn: "Direct (posix_spawn)"
            case .root: "As root or another user (helper)"
            case .launchd: "launchd job"
            case .launchServices: "Launch Services (NSWorkspace)"
            case .open: "open command"
            }
        }
        /// Whether the program can be held before its first instruction, so a trace sees all of it.
        var startsSuspended: Bool { self == .spawn || self == .root || self == .launchd }
        /// Only an app bundle (Launch Services won't run a bare executable as an app, and open hands one to Terminal).
        var needsApp: Bool { self == .launchServices || self == .open }
        /// The program's own stdout and stderr can be shown.
        var hasOutput: Bool { self != .launchServices }
        var hasWorkingDirectory: Bool { self == .spawn || self == .root || self == .launchd }
        var hasArgv0: Bool { self == .spawn || self == .root || self == .launchd }
        /// Variables can be removed, or the environment started empty (not only added to).
        var hasFullEnvironment: Bool { self == .spawn || self == .root }
        var hasStdin: Bool { self == .spawn || self == .root || self == .launchd || self == .open }
        /// pxr-exec's settings (resource limits, umask, nice, I/O policy, sandbox).
        var hasProcessSettings: Bool { self == .spawn || self == .root }
    }

    var method: Method = .spawn
    /// An app bundle or an executable.
    var path = ""
    /// Split as a shell splits words (Launcher.splitArguments).
    var arguments = ""
    /// argv[0], when not the executable's path.
    var argv0 = ""
    /// Empty: the method's default (Proc X-Ray's own for a direct spawn, / for launchd and the helper).
    var workingDirectory = ""

    enum EnvironmentBase: String, Codable, CaseIterable, Sendable {
        /// Proc X-Ray's environment.
        case inherit
        /// HOME, USER, LOGNAME, SHELL, PATH and TMPDIR, as a login gives (for the user the program runs as).
        case login
        case empty
    }
    var environmentBase: EnvironmentBase = .inherit
    /// One per line: NAME=value sets it, -NAME removes it. Blank lines and lines starting with # are skipped.
    var environment = ""

    enum Input: String, Codable, CaseIterable, Sendable { case null, file }
    var stdin: Input = .null
    var stdinPath = ""

    enum Output: String, Codable, CaseIterable, Sendable {
        /// Shown in the Launch window's Output pane.
        case show
        case null
        case file
        /// stderr only: wherever stdout goes.
        case stdout
    }
    var stdout: Output = .show
    var stdoutPath = ""
    var stderr: Output = .show
    var stderrPath = ""
    /// Append to an output file instead of replacing it.
    var appendOutput = false

    /// Start a syscall trace on it: from its first instruction when the method can start it suspended.
    var trace = false
    var stacks = false

    var spawn = SpawnSettings()
    var process = ProcessSettings()
    var root = RootSettings()
    var launchd = LaunchdSettings()
    var launchServices = LaunchServicesSettings()
    var open = OpenSettings()

    init() {}

    // Decoding fills in fields saved by an older build with their defaults.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ k: CodingKeys, _ v: inout T) { if let x = try? c.decode(T.self, forKey: k) { v = x } }
        get(.method, &method); get(.path, &path); get(.arguments, &arguments); get(.argv0, &argv0)
        get(.workingDirectory, &workingDirectory); get(.environmentBase, &environmentBase); get(.environment, &environment)
        get(.stdin, &stdin); get(.stdinPath, &stdinPath); get(.stdout, &stdout); get(.stdoutPath, &stdoutPath)
        get(.stderr, &stderr); get(.stderrPath, &stderrPath); get(.appendOutput, &appendOutput)
        get(.trace, &trace); get(.stacks, &stacks)
        get(.spawn, &spawn); get(.process, &process); get(.root, &root); get(.launchd, &launchd)
        get(.launchServices, &launchServices); get(.open, &open)
    }

    var argumentList: [String] { Launcher.splitArguments(arguments) }

    /// The environment edits, in order: (name, value), value nil to remove the variable.
    var environmentEdits: [(String, String?)] {
        environment.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { return nil }
            if line.hasPrefix("-") { return (String(line.dropFirst()), nil) }
            guard let eq = line.firstIndex(of: "="), eq != line.startIndex else { return nil }
            return (String(line[..<eq]), String(line[line.index(after: eq)...]))
        }
    }

    /// The program's whole environment, for the methods that set it all (hasFullEnvironment).
    func resolvedEnvironment(user: Launcher.Account) -> [String: String] {
        var env: [String: String]
        switch environmentBase {
        case .inherit: env = ProcessInfo.processInfo.environment
        case .empty: env = [:]
        case .login:
            env = ["HOME": user.home, "USER": user.name, "LOGNAME": user.name, "SHELL": user.shell,
                   "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            if user.uid == getuid(), let t = ProcessInfo.processInfo.environment["TMPDIR"] { env["TMPDIR"] = t }
        }
        for (k, v) in environmentEdits { env[k] = v }
        return env
    }

    /// Only the additions, for the methods that add to an environment someone else builds (launchd, Launch Services, open).
    var addedEnvironment: [String: String] {
        var env: [String: String] = [:]
        for (k, v) in environmentEdits { if let v { env[k] = v } else { env[k] = nil } }
        return env
    }
}

/// posix_spawn attributes, for a direct spawn and for the helper's.
struct SpawnSettings: Codable, Equatable, Sendable {
    /// POSIX_SPAWN_SETSID: a session (and process group) of its own, with no controlling terminal.
    var newSession = false
    /// POSIX_SPAWN_SETPGROUP with 0: a process group of its own.
    var newProcessGroup = false
    /// POSIX_SPAWN_RESETIDS: effective ids from the real ones (and only the primary group).
    var resetIDs = false
    /// Without POSIX_SPAWN_CLOEXEC_DEFAULT: every descriptor Proc X-Ray has open without close-on-exec.
    var inheritDescriptors = false
    /// POSIX_SPAWN_SETSIGDEF and SETSIGMASK: every signal at its default action, none blocked.
    var defaultSignals = true
    /// _POSIX_SPAWN_DISABLE_ASLR (0x100): the main image and dyld at their unslid addresses.
    var disableASLR = false

    enum Architecture: String, Codable, CaseIterable, Sendable {
        case any, arm64e, arm64, x86_64
        var label: String {
            switch self {
            case .any: "Default"
            case .arm64e: "arm64e"
            case .arm64: "arm64"
            case .x86_64: "x86_64 (Rosetta)"
            }
        }
    }
    /// posix_spawnattr_setarchpref_np: which slice of a universal binary runs.
    var architecture: Architecture = .any

    enum QoSClamp: String, Codable, CaseIterable, Sendable {
        case none, utility, background, maintenance
        var value: UInt64 { switch self { case .none: 0; case .utility: 1; case .background: 2; case .maintenance: 3 } }
    }
    /// posix_spawnattr_set_qos_clamp_np: no thread runs above this QoS.
    var qosClamp: QoSClamp = .none

    enum Role: String, Codable, CaseIterable, Sendable {
        case unset, uiFocal, ui, nonUI, uiNonFocal, talLaunch, darwinBG
        var value: UInt64 {
            switch self {
            case .unset: 0; case .uiFocal: 1; case .ui: 2; case .nonUI: 3; case .uiNonFocal: 4; case .talLaunch: 5; case .darwinBG: 6
            }
        }
        var label: String {
            switch self {
            case .unset: "Default"
            case .uiFocal: "Frontmost app (UI focal)"
            case .ui: "App (UI)"
            case .nonUI: "No UI (non-UI)"
            case .uiNonFocal: "Background app (UI non-focal)"
            case .talLaunch: "Launched for App Nap (TAL)"
            case .darwinBG: "Background (Darwin BG)"
            }
        }
    }
    /// posix_spawnattr_set_darwin_role_np: the scheduler's role for the task (PRIO_DARWIN_ROLE).
    var role: Role = .unset

    enum ProcessType: String, Codable, CaseIterable, Sendable {
        case unset, appDefault, appTAL, daemonStandard, daemonInteractive, daemonBackground, daemonAdaptive
        var value: Int32 {
            switch self {
            case .unset: 0; case .appDefault: 0x100; case .appTAL: 0x200; case .daemonStandard: 0x300
            case .daemonInteractive: 0x400; case .daemonBackground: 0x500; case .daemonAdaptive: 0x600
            }
        }
        var label: String {
            switch self {
            case .unset: "Default"
            case .appDefault: "App"
            case .appTAL: "App (App Nap launch)"
            case .daemonStandard: "Daemon: standard"
            case .daemonInteractive: "Daemon: interactive"
            case .daemonBackground: "Daemon: background"
            case .daemonAdaptive: "Daemon: adaptive"
            }
        }
    }
    /// posix_spawnattr_setprocesstype_np: the resource policy launchd gives a job of this kind (QoS, I/O, memory).
    var processType: ProcessType = .unset

    /// responsibility_spawnattrs_setdisclaim: it is its own responsible process (TCC asks about it, not Proc X-Ray).
    var disclaimResponsibility = false
    /// posix_spawnattr_setnosmt_np: its threads never share a core with another task's.
    var noSMT = false
    /// posix_spawnattr_set_csm_np(POSIX_SPAWN_NP_CSM_ALL): every CPU security mitigation.
    var cpuMitigations = false
    /// posix_spawnattr_setjetsam_ext: a memory limit in MiB (0: none). Fatal: killed when over it, not just reported.
    var memoryLimitMB = 0
    var memoryLimitFatal = true
    /// posix_spawnattr_setjetsam_ext's priority (-1: unchanged). Higher is killed later under memory pressure.
    var jetsamPriority = -1
    /// Left stopped after launching (and after the trace starts), for attaching something else first.
    var leaveSuspended = false
}

/// What pxr-exec sets in the process before it execs the program (posix_spawn has no attribute for these).
struct ProcessSettings: Codable, Equatable, Sendable {
    struct Limit: Codable, Equatable, Hashable, Sendable {
        var soft = ""
        var hard = ""
        var isSet: Bool { !soft.isEmpty || !hard.isEmpty }
    }
    /// The setrlimit resources, by pxr-exec's names, with what each one limits.
    static let resources: [(name: String, label: String)] = [
        ("nofile", "Open files (NOFILE)"), ("nproc", "Processes (NPROC)"), ("cpu", "CPU seconds (CPU)"),
        ("fsize", "File size, bytes (FSIZE)"), ("data", "Data segment, bytes (DATA)"), ("stack", "Stack, bytes (STACK)"),
        ("core", "Core file, bytes (CORE)"), ("as", "Address space, bytes (AS)"), ("rss", "Resident set, bytes (RSS)"),
        ("memlock", "Locked memory, bytes (MEMLOCK)"),
    ]
    /// By resource name: a number, "inf", or empty to keep Proc X-Ray's (or the helper's) value.
    var limits: [String: Limit] = [:]
    /// Octal; empty keeps it.
    var umask = ""
    /// setpriority; nil keeps it. Lowering it (below the parent's) needs root.
    var nice: Int?
    /// PRIO_DARWIN_BG: background CPU and I/O priority.
    var darwinBackground = false

    enum IOPolicy: String, Codable, CaseIterable, Sendable {
        case unchanged, important, passive, throttle, utility, standard
        /// IOPOL_*.
        var value: Int32 {
            switch self {
            case .unchanged: -1; case .important: 1; case .passive: 2; case .throttle: 3; case .utility: 4; case .standard: 5
            }
        }
    }
    /// setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS).
    var ioPolicy: IOPolicy = .unchanged
    /// An SBPL profile, applied with sandbox_init (as sandbox-exec -p does). Empty: none.
    var sandboxProfile = ""

    var isEmpty: Bool {
        !limits.values.contains(where: \.isSet) && umask.isEmpty && nice == nil && !darwinBackground
            && ioPolicy == .unchanged && sandboxProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// pxr-exec's options, before `--`.
    var execArguments: [String] {
        var a: [String] = []
        for (name, _) in Self.resources {
            guard let l = limits[name], l.isSet else { continue }
            a += ["-r", "\(name)=\(l.soft.trimmingCharacters(in: .whitespaces)):\(l.hard.trimmingCharacters(in: .whitespaces))"]
        }
        if !umask.isEmpty { a += ["-u", umask] }
        if let nice { a += ["-n", String(nice)] }
        if darwinBackground { a.append("-b") }
        if ioPolicy != .unchanged { a += ["-i", String(ioPolicy.value)] }
        let profile = sandboxProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !profile.isEmpty { a += ["-S", profile] }
        return a
    }
}

/// Who the helper runs the program as.
struct RootSettings: Codable, Equatable, Sendable {
    /// A user name or uid; empty: root.
    var user = ""
    /// A group name or gid; empty: the user's primary group.
    var group = ""
    /// The user's supplementary groups (initgroups); off: only the primary group.
    var supplementaryGroups = true
}

/// launchd.plist keys (man launchd.plist), for a job in the user's GUI domain.
struct LaunchdSettings: Codable, Equatable, Sendable {
    enum ProcessType: String, Codable, CaseIterable, Sendable { case unset, Standard, Background, Adaptive, Interactive }
    var processType: ProcessType = .unset
    /// Nil: unset.
    var nice: Int?
    var lowPriorityIO = false
    var lowPriorityBackgroundIO = false
    /// Octal; empty: unset.
    var umask = ""
    /// SoftResourceLimits and HardResourceLimits, by ProcessSettings' resource names.
    var limits: [String: ProcessSettings.Limit] = [:]
    /// Restarted whenever it exits (KeepAlive true).
    var keepAlive = false
    /// Its child processes aren't killed with it (AbandonProcessGroup).
    var abandonProcessGroup = false
    /// Seconds between SIGTERM and SIGKILL when the job stops (ExitTimeOut); nil: launchd's 20.
    var exitTimeOut: Int?
    /// Seconds launchd waits before starting it again (ThrottleInterval); nil: launchd's 10.
    var throttleInterval: Int?
    /// Started stopped, as for a debugger (WaitForDebugger). Always on while tracing.
    var waitForDebugger = false
    /// launchd may kill it when idle under memory pressure (EnablePressuredExit).
    var enablePressuredExit = false
    /// Pending work keeps it from being killed when idle (EnableTransactions).
    var enableTransactions = false
    /// Timer coalescing off (LegacyTimers).
    var legacyTimers = false
    /// Reads of dataless (cloud) files download them (MaterializeDatalessFiles).
    var materializeDatalessFiles = false
    /// A new security session of its own (SessionCreate).
    var sessionCreate = false

    /// launchd's names for ProcessSettings' resources.
    static let limitKeys: [String: String] = [
        "nofile": "NumberOfFiles", "nproc": "NumberOfProcesses", "cpu": "CPU", "fsize": "FileSize", "data": "Data",
        "stack": "Stack", "core": "Core", "rss": "ResidentSetSize", "memlock": "MemoryLock",
    ]
}

/// NSWorkspace.OpenConfiguration.
struct LaunchServicesSettings: Codable, Equatable, Sendable {
    var activates = true
    var hides = false
    var hidesOthers = false
    var createsNewInstance = false
    /// An app already running from another copy may stand in (allowsRunningApplicationSubstitution).
    var allowsSubstitution = true
    var addsToRecentItems = true
    /// Ask the user when the app needs it (an app downloaded from the internet, a quarantined one).
    var promptsUserIfNeeded = true
    /// The documents are to be printed (isForPrinting).
    var forPrinting = false
    var architecture: SpawnSettings.Architecture = .any
    /// Files or URLs to open with it, one per line.
    var documents = ""
}

/// /usr/bin/open's options (man open).
struct OpenSettings: Codable, Equatable, Sendable {
    /// -n: a new instance even if one is running.
    var newInstance = false
    /// -g: don't bring it to the front.
    var background = false
    /// -j: launched hidden.
    var hidden = false
    /// -F: no windows restored.
    var fresh = false
    /// -W: open waits until the app quits (and its stdout/stderr files stay written to until then).
    var wait = true
    var architecture: SpawnSettings.Architecture = .any
    /// Files or URLs to open with it, one per line.
    var documents = ""
}
