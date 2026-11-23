import Foundation
import Security

/// Shared between the app and the root helper (same binary, run with `--helper`).
enum HelperConfig {
    /// `local.procxray` for release builds, `local.procxray.dev` for dev builds (see build-app.sh). Read from this
    /// binary's own signature, so the app and the helper (same binary, started by launchd) always agree, and a dev
    /// build registers, serves and talks to its own helper instead of taking over the installed app's.
    static let bundleID: String = {
        var me: SecCode?
        var info: CFDictionary?
        if SecCodeCopySelf([], &me) == errSecSuccess, let me,
           SecCodeCopySigningInformation(unsafeBitCast(me, to: SecStaticCode.self), [], &info) == errSecSuccess,
           let id = (info as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String, id.hasPrefix("local.procxray") {
            return id
        }
        return "local.procxray"
    }()
    static var machService: String { "\(bundleID).helper" }
    static var plistName: String { "\(bundleID).helper.plist" }

    /// Team ID and cdhash of this binary's signature (app and helper are the same binary).
    /// Note: an "Apple Development: Name (XXXXXXXXXX)" certificate's parenthesised ID is NOT the team ID.
    private static let signature: (team: String, cdhash: String)? = {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(unsafeBitCast(me, to: SecStaticCode.self),
                                            SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let d = info as? [String: Any],
              let team = d[kSecCodeInfoTeamIdentifier as String] as? String,
              let unique = d[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return (team, unique.map { String(format: "%02x", $0) }.joined())
    }()
    static var teamID: String? { signature?.team }

    /// Both sides require the peer to be this exact binary: same identifier and team, and the same cdhash.
    /// The cdhash pin is what matters — identifier and team alone would admit anything else signed with
    /// the same certificate. Unsigned/ad-hoc builds get an unsatisfiable requirement, so the helper can
    /// never be driven by unsigned code.
    static var peerRequirement: String {
        guard let s = signature else { return #"identifier "never.matches" and anchor apple"# }
        return #"identifier "\#(bundleID)" and anchor apple generic and certificate leaf[subject.OU] = "\#(s.team)" and cdhash H"\#(s.cdhash)""#
    }
    /// Bumped whenever the XPC interface changes.
    static let protocolVersion = 25  // 25: metrics (asked-for processes only), netRates(every:), 24: taskDetail, PrivMetrics.suspendCount, 23: PrivMetrics.asid, 22: launch, launched, 21: traceThreads (names), dyld, trace-string and MIG events, 20: traceThreadOwners, scheduler events in the trace, 19: machPortKinds, 5: MachSnapshot.counts, 6: exceptionRoutes, 7: MachLink notes, 8: machPortDetail, 9: threads, 10: stacks tool, 11: thread core counters, 12: bankLedger, 13: securityConfig, 14: securityConfig replies SecurityDetail, 15: vmmap lists every region, 16: groupFootprint, 17: netRates, 18: systemCounters
}

/// Read-only surface, but for `launch`: no other call accepts a path, a command or free-form arguments. `launch`
/// runs what the caller asks, as root or any user, so it takes an administrator's authorization granted for that
/// launch (AdminAuthorization), not just an admin caller.
@objc protocol HelperProtocol {
    func version(reply: @escaping (Int, Int32) -> Void)                 // (protocolVersion, helper pid)
    /// `extras`: ExtraReads raw value; only the per-process ones the helper can do (ExtraReads.viaHelper).
    func allMetrics(extras: Int, reply: @escaping (Data) -> Void)       // JSON [PrivMetrics]
    /// allMetrics for the processes the caller can't read itself: those in `pids` (packed Int32s) get their
    /// metrics only, and every process started after `since` (seconds since 1970) gets everything, as allMetrics
    /// gives it. Reading and encoding every process on every refresh was most of the helper's CPU time.
    func metrics(pids: Data, since: Double, extras: Int, reply: @escaping (Data) -> Void)   // JSON [PrivMetrics]
    func argsEnv(pid: Int32, reply: @escaping (Data?) -> Void)          // JSON PrivArgsEnv
    /// Every thread of one process (ThreadReader), for processes the app can't read itself. JSON ThreadSnapshot.
    func threads(pid: Int32, reply: @escaping (Data?) -> Void)
    /// JSON SecurityDetail, or nil when it can't be read (gone, or not the caller's and the caller isn't an admin).
    func securityConfig(pid: Int32, reply: @escaping (Data?) -> Void)
    /// JSON TaskDetail (task_info through a name port), or nil when the process is gone. The audit token for every
    /// caller; the rest, like the other per-process reads, only for a caller who may inspect the process.
    func taskDetail(pid: Int32, reply: @escaping (Data?) -> Void)
    func runTool(_ tool: Int, pid: Int32, reply: @escaping (String) -> Void)
    /// `footprint` over a set of processes (JSON [Int32], at most `GroupFootprint.maxPids`), for a group's memory
    /// with shared pages counted once (GroupFootprint). Another user's processes only for an admin caller; the
    /// others are left out. (footprint's output, nil) or (nil, why not).
    func groupFootprint(_ pids: Data, reply: @escaping (String?, String?) -> Void)
    /// Every process's Mach port links: `lsmp -a` paired in the helper, so the reply is the links (~1 MB of
    /// JSON MachSnapshot), not lsmp's ~40 MB. Admin callers only. (snapshot, nil) or (nil, why not).
    func machPorts(reply: @escaping (Data?, String?) -> Void)
    /// The ports behind the Mach link between two processes, both directions, from the helper's last lsmp
    /// run (or a new one if it has none). Admin callers only. (JSON MachPortDetailReply, nil) or (nil, why not).
    func machPortDetail(pid: Int32, peer: Int32, reply: @escaping (Data?, String?) -> Void)
    /// One process's port names that lead to no other process, from the same lsmp run: name → "task port",
    /// "IOKit connection (…)", "own port"… (MachSnapshot.portKinds). Admin callers only. (JSON [UInt32: String], nil)
    /// or (nil, why not).
    func machPortKinds(pid: Int32, reply: @escaping (Data?, String?) -> Void)

    /// Syscall trace of one process (kdebug, read by the helper itself or through `ktrace trace`), at most one
    /// per connection. The trace stops when the connection ends, so the app gives each trace a connection of its own.
    /// `stacks`: a user stack per call (kperf; kdebug format only). Reply: (nil, SyscallTraceConfig.Format raw
    /// value) when started, else (why not, 0).
    func traceStart(pid: Int32, stacks: Bool, reply: @escaping (String?, Int) -> Void)
    /// Data written since the last read (up to `SyscallTraceConfig.maxRead`, whole records or lines), whether
    /// the trace is still running, anything ktrace wrote to stderr or the helper has to say (drops, exit), and
    /// the images behind stack frames found since the last read (JSON [StackRegion], empty Data when none).
    func traceRead(reply: @escaping (Data, Bool, String, Data) -> Void)
    func traceStop(reply: @escaping () -> Void)
    /// What some descriptors of the traced process are now (JSON [Int32] in, JSON [String: String] by fd out):
    /// for labelling fd arguments. Empty when no trace runs on this connection.
    func traceDescribeFds(_ fds: Data, reply: @escaping (Data) -> Void)
    /// The process and name of each thread id (JSON [UInt64] in, JSON [String: ThreadInfo] by thread id out;
    /// threads gone or not found are left out): for naming the traced process's threads and the receivers a message
    /// woke. Empty when no trace runs on this connection.
    func traceThreads(_ tids: Data, reply: @escaping (Data) -> Void)

    /// Records every process's voucher (BANK) settlements for `seconds` (at most BankLedger.maxSeconds) and
    /// replies with the per-pair sums: who did work for whom. Uses kdebug, so not while a trace runs. Stops
    /// early when the connection ends. Admin callers only. (JSON BankLedger.Recording, nil) or (nil, why not).
    func bankLedger(seconds: Int, reply: @escaping (Data?, String?) -> Void)

    /// Every process's network rates and totals from the helper's own NetworkStatistics reader (NativeNetStats),
    /// started by the first call and kept for the helper's life. As root it sees every user's sockets and the
    /// user-space (Network.framework) flows, which the kernel keeps from an unprivileged reader. JSON NetRatesReply.
    func netRates(reply: @escaping (Data) -> Void)
    /// netRates, and from now on the helper's reader reads every `every` seconds (the pace of whoever shows the
    /// figures: NetSampler.setPace).
    func netRates(every: Double, reply: @escaping (Data) -> Void)

    /// System counters only root reads: the allowlisted sysctls (HelperCounters.sysctlAllowlist, fixed names) and
    /// the kernel's zones. Takes no input. JSON HelperCounters.
    func systemCounters(reply: @escaping (Data) -> Void)

    /// Starts a program (JSON Launcher.Request) with posix_spawn, as root or the user, group and groups the request
    /// names. `authorization`: an AdminAuthorization external form the helper checks first. Reply: (JSON
    /// Launcher.Child, the read ends of its stdout and stderr pipes when the request asked for them, nil) or (nil,
    /// nil, nil, why not). The helper reaps it, and only the caller's user may signal it afterwards (`launched`).
    func launch(_ request: Data, authorization: Data, reply: @escaping (Data?, FileHandle?, FileHandle?, String?) -> Void)
    /// A program `launch` started for this user: sends `signal` (SIGCONT, SIGSTOP, SIGTERM, SIGINT, SIGKILL; 0
    /// sends none), then replies with (JSON Launcher.Exit once it has ended, else nil; nil, or why the signal
    /// wasn't sent).
    func launched(pid: Int32, signal: Int32, reply: @escaping (Data?, String?) -> Void)
}

/// The helper's network reading (HelperProtocol.netRates).
struct NetRatesReply: Codable {
    struct Entry: Codable {
        var pid: Int32
        var inPerSec: Double, outPerSec: Double
        var inTotal: UInt64, outTotal: UInt64
    }
    /// When the helper's reader started (NativeNetStats.since).
    var since: Date
    /// nil until the reader has compared two queries (~2 s after the first call).
    var rates: [Entry]?
}

/// What the helper traces, and the one ktrace command line it runs when it doesn't read kdebug itself.
enum SyscallTraceConfig {
    /// How `traceRead`'s data is laid out.
    enum Format: Int {
        /// `ktrace trace --ndjson` lines.
        case ndjson = 1
        /// KdebugTrace.Record, 64 bytes each.
        case kdebug = 2
    }
    /// BSD syscalls (class 4, subclass 0x0c), Mach traps (1/0x0c) and VFS path lookups (3/0x01).
    /// BSD syscalls, Mach traps, VFS lookups, the scheduler (DBG_MACH_SCHED: which thread a message woke, whether
    /// the caller blocked; SyscallDecoder.sched), trace strings (thread names, dyld's paths and symbol names) and
    /// dyld (image loads, initializers, dlopen/dlsym) and MIG (the kernel routine behind each message to a kernel
    /// object; indexes below 16,384, so subclass 0). The scheduler about doubles the events of a process sending
    /// messages; dyld adds a few thousand at an app's launch and little after.
    static let classSubclasses: [UInt16] = [0x040c, 0x010c, 0x0301, 0x0140, 0x0701, 0x1f05, 0x1f07, 0x1f08, 0xff00]
    static let filter = classSubclasses.map { "S0x" + String(format: "%04x", $0) }.joined(separator: ",")
    /// A forgotten trace ends on its own.
    static let maxSeconds = 15 * 60
    static func argv(pid: Int32) -> (String, [String])? {
        pid > 0 ? ("/usr/bin/ktrace", ["trace", "-p", "\(pid)", "-f", filter, "--ndjson", "-T", "\(maxSeconds)"]) : nil
    }
    /// Unread output the helper keeps; beyond it, output is dropped (and counted) until the app catches up.
    static let maxPending = 32 << 20
    static let maxRead = 4 << 20
}

/// Allowlisted tools; the helper builds the argv itself.
enum HelperTool: Int, CaseIterable {
    case lsof = 1, vmmap, sample, launchctlProcinfo, btmDump, lsofAll, pidDomain, taskinfo, powermetrics, stacks, heap

    func argv(pid: Int32) -> (String, [String])? {
        switch self {
        case .lsof: return pid > 0 ? ("/usr/sbin/lsof", ["-n", "-P", "-p", "\(pid)"]) : nil
        // Every region (-w: paths not truncated), then the same summary --summary prints; as fast as --summary
        // (1.1–1.4 s for 7–16k regions) and 1–2 MB of text.
        case .vmmap: return pid > 0 ? ("/usr/bin/vmmap", ["-w", "\(pid)"]) : nil
        // Without -file, sample also writes its report to /tmp (as root, world-readable when run by the helper).
        case .sample: return pid > 0 ? ("/usr/bin/sample", ["\(pid)", "1", "-mayDie", "-file", "/dev/stdout"]) : nil
        // One sample of every thread's stack (duration 0): ~0.3 s with symbols, against ~20 s for a 1 s run of
        // an Electron app. The target is suspended only for that one sample.
        case .stacks: return pid > 0 ? ("/usr/bin/sample", ["\(pid)", "0", "1", "-mayDie", "-file", "/dev/stdout"]) : nil
        // Every live malloc block, matched to its ObjC, Swift, CF or C type and summed per type. --forkCorpse walks
        // a copy-on-write corpse of the target, so the target runs on: Safari was suspended 9–39 s without it,
        // and the run itself was 4 s instead of 9 (27.2).
        case .heap: return pid > 0 ? ("/usr/bin/heap", ["--forkCorpse", "\(pid)"]) : nil
        case .launchctlProcinfo: return pid > 0 ? ("/bin/launchctl", ["procinfo", "\(pid)"]) : nil
        case .btmDump: return ("/usr/bin/sfltool", ["dumpbtm"])
        // Every process's descriptors in field form (pid, fd, type, address, name, protocol, TCP state), for
        // resolving the other end of pipes and sockets. ~0.15 s and ~2 MB for one user's processes.
        case .lsofAll: return ("/usr/sbin/lsof", ["-n", "-P", "-F", "pftdnPT"])
        // The launchd domain this process owns: the services it has launched (an extension host's extensions).
        case .pidDomain: return pid > 0 ? ("/bin/launchctl", ["print", "pid/\(pid)"]) : nil
        // Scheduling policy, boosts, billed CPU, per-thread dispatch queues. Root reads it for any process.
        case .taskinfo: return pid > 0 ? ("/usr/bin/taskinfo", ["\(pid)", "--threads", "--dq"]) : nil
        // Machine-wide per-process energy/CPU/wakeups over one 500 ms sample.
        case .powermetrics: return ("/usr/bin/powermetrics", ["--samplers", "tasks", "--show-process-energy",
                                                               "--show-process-wait-times", "-n", "1", "-i", "500"])
        }
    }

    /// Seconds before the helper kills the tool. Under HelperClient.run's 60 s wait, so the reply still arrives.
    var timeout: Double {
        switch self {
        case .sample, .heap: 45   // heap: walks every block; sample: 1 s of sampling, then symbolication: ~13 s for a 39-thread daemon
        case .vmmap, .btmDump: 30
        case .lsof, .lsofAll: 20
        case .powermetrics: 15
        case .launchctlProcinfo, .pidDomain, .taskinfo: 10
        case .stacks: 15
        }
    }
    /// Output beyond this is dropped: it goes back as one XPC reply and the app parses all of it.
    static let maxOutput = 8 << 20
}

struct PrivMetrics: Codable, Sendable {
    var pid: Int32
    var rss: UInt64?
    var virt: UInt64?
    var threads: Int32?
    var cpuNanos: UInt64?
    var footprint: UInt64?
    var diskRead: UInt64?
    var diskWrite: UInt64?
    var energyNJ: UInt64?
    var wakeups: UInt64?
    var counters: Counters?
    var responsible: Int32?
    var sandboxed: Bool?
    /// Audit session id (LoginSessions.asid).
    var asid: Int32?
    /// task_suspend count (MACH_TASK_BASIC_INFO), when asked for (ExtraReads.suspended).
    var suspendCount: Int32?
    /// Scheduling priority (proc_taskinfo), always read; the rest only when asked for (ExtraReads).
    var priority: Int32?
    var nice: Int32?
    var openFiles: Int?
    var compressed: UInt64?
    var jetsam: JetsamInfo?
}

/// Cumulative counters from the same two calls as the metrics above (proc_taskinfo, rusage_info_v6).
/// Times are nanoseconds.
struct Counters: Codable, Hashable, Sendable {
    // proc_taskinfo. The kernel stores these as 32-bit ints; read as unsigned they wrap at 2^32.
    var runningThreads: UInt32?
    var contextSwitches: UInt32?
    var faults: UInt32?
    var cowFaults: UInt32?
    var pageins: UInt32?
    var machMsgsSent: UInt32?
    var machMsgsReceived: UInt32?
    var machSyscalls: UInt32?
    var unixSyscalls: UInt32?
    // rusage_info_v6
    var instructions: UInt64?
    var cycles: UInt64?
    var pCoreNanos: UInt64?
    /// Time the threads were runnable but not running. The kernel's runnable time includes running time
    /// (measured: a CPU-bound process on an oversubscribed machine got 1.69 s of CPU and 3.95 s of
    /// runnable time in 4 s), so this is runnable minus CPU time.
    var waitingNanos: UInt64?
    var logicalWrites: UInt64?
    var peakFootprint: UInt64?
    var neuralFootprint: UInt64?
    /// Mach-voucher (BANK) accounting: CPU time and energy this process spent servicing other processes'
    /// requests (`serviced*`), and that other processes spent servicing this one (`billed*`). Most of it
    /// flows automatically over XPC, where the handler adopts the caller's voucher. Times are nanoseconds.
    /// `billedEnergyNJ` is kept apart from the process's own energy (see `energyNJ`).
    var billedEnergyNJ: UInt64?
    var servicedEnergyNJ: UInt64?
    var billedCpuNanos: UInt64?
    var servicedCpuNanos: UInt64?
    /// CPU time per QoS class, nanoseconds, in `Counters.qosClasses` order.
    var qosNanos: [UInt64]?

    static let qosClasses = ["User interactive", "User initiated", "Default", "Utility", "Background", "Maintenance", "Legacy"]
}

extension PrivMetrics {
    /// Everything proc_taskinfo and rusage give for `pid`; fields stay nil when a call fails.
    static func read(_ pid: Int32) -> PrivMetrics {
        var m = PrivMetrics(pid: pid)
        var c = Counters()
        var any = false
        if let ti = Native.taskInfo(pid) {
            m.priority = ti.pti_priority
            m.rss = ti.pti_resident_size
            m.virt = ti.pti_virtual_size
            m.threads = ti.pti_threadnum
            m.cpuNanos = Native.machToNanos(ti.pti_total_user &+ ti.pti_total_system)
            func u(_ v: Int32) -> UInt32 { UInt32(bitPattern: v) }
            c.runningThreads = u(ti.pti_numrunning)
            c.contextSwitches = u(ti.pti_csw)
            c.faults = u(ti.pti_faults)
            c.cowFaults = u(ti.pti_cow_faults)
            c.pageins = u(ti.pti_pageins)
            c.machMsgsSent = u(ti.pti_messages_sent)
            c.machMsgsReceived = u(ti.pti_messages_received)
            c.machSyscalls = u(ti.pti_syscalls_mach)
            c.unixSyscalls = u(ti.pti_syscalls_unix)
            any = true
        }
        if let ru = Native.rusage(pid) {
            m.footprint = ru.ri_phys_footprint
            m.diskRead = ru.ri_diskio_bytesread
            m.diskWrite = ru.ri_diskio_byteswritten
            // The process's own CPU energy. (ri_billed_energy is something else: measured 0 for a process
            // busy on a CPU at 4 W.)
            m.energyNJ = ru.ri_energy_nj
            c.billedEnergyNJ = ru.ri_billed_energy
            c.servicedEnergyNJ = ru.ri_serviced_energy
            // ri_billed/serviced_system_time are mach ticks, like ri_user_time (converted below).
            c.billedCpuNanos = Native.machToNanos(ru.ri_billed_system_time)
            c.servicedCpuNanos = Native.machToNanos(ru.ri_serviced_system_time)
            m.wakeups = ru.ri_pkg_idle_wkups &+ ru.ri_interrupt_wkups
            let cpu = ru.ri_user_time &+ ru.ri_system_time
            if m.cpuNanos == nil { m.cpuNanos = Native.machToNanos(cpu) }
            c.instructions = ru.ri_instructions
            c.cycles = ru.ri_cycles
            c.pCoreNanos = Native.machToNanos(ru.ri_user_ptime &+ ru.ri_system_ptime)
            c.waitingNanos = Native.machToNanos(ru.ri_runnable_time > cpu ? ru.ri_runnable_time - cpu : 0)
            c.logicalWrites = ru.ri_logical_writes
            c.peakFootprint = ru.ri_lifetime_max_phys_footprint
            c.neuralFootprint = ru.ri_neural_footprint
            c.qosNanos = [ru.ri_cpu_time_qos_user_interactive, ru.ri_cpu_time_qos_user_initiated, ru.ri_cpu_time_qos_default,
                          ru.ri_cpu_time_qos_utility, ru.ri_cpu_time_qos_background, ru.ri_cpu_time_qos_maintenance,
                          ru.ri_cpu_time_qos_legacy].map(Native.machToNanos)
            any = true
        }
        if any { m.counters = c }
        return m
    }

    /// The per-process extra reads asked for.
    mutating func readExtras(_ e: ExtraReads) {
        if e.contains(.openFiles) { openFiles = ExtraRead.openFiles(pid) }
        if e.contains(.nice) { nice = ExtraRead.nice(pid) }
        if e.contains(.compressed) { compressed = ExtraRead.compressed(pid) }
        if e.contains(.suspended) { suspendCount = TaskBasic.suspendCount(pid) }
    }
}

struct PrivArgsEnv: Codable, Sendable {
    var execPath: String
    var args: [String]
    var env: [String]
    var cwd: String?
}
