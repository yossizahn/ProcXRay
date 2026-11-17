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
    static let protocolVersion = 16  // 5: MachSnapshot.counts, 6: exceptionRoutes, 7: MachLink notes, 8: machPortDetail, 9: threads, 10: stacks tool, 11: thread core counters, 12: bankLedger, 13: securityConfig, 14: securityConfig replies SecurityDetail, 15: vmmap lists every region, 16: groupFootprint
}

/// Read-only surface. No call accepts a path, a command or free-form arguments.
@objc protocol HelperProtocol {
    func version(reply: @escaping (Int, Int32) -> Void)                 // (protocolVersion, helper pid)
    /// `extras`: ExtraReads raw value; only the per-process ones the helper can do (ExtraReads.viaHelper).
    func allMetrics(extras: Int, reply: @escaping (Data) -> Void)       // JSON [PrivMetrics]
    func argsEnv(pid: Int32, reply: @escaping (Data?) -> Void)          // JSON PrivArgsEnv
    /// Every thread of one process (ThreadReader), for processes the app can't read itself. JSON ThreadSnapshot.
    func threads(pid: Int32, reply: @escaping (Data?) -> Void)
    /// JSON SecurityDetail, or nil when it can't be read (gone, or not the caller's and the caller isn't an admin).
    func securityConfig(pid: Int32, reply: @escaping (Data?) -> Void)
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

    /// Records every process's voucher (BANK) settlements for `seconds` (at most BankLedger.maxSeconds) and
    /// replies with the per-pair sums: who did work for whom. Uses kdebug, so not while a trace runs. Stops
    /// early when the connection ends. Admin callers only. (JSON BankLedger.Recording, nil) or (nil, why not).
    func bankLedger(seconds: Int, reply: @escaping (Data?, String?) -> Void)
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
    static let classSubclasses: [UInt16] = [0x040c, 0x010c, 0x0301]
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
    case lsof = 1, vmmap, sample, launchctlProcinfo, btmDump, lsofAll, pidDomain, taskinfo, powermetrics, stacks

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
        case .sample: 45   // 1 s of sampling, then symbolication: ~13 s for a 39-thread daemon
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
    }
}

struct PrivArgsEnv: Codable, Sendable {
    var execPath: String
    var args: [String]
    var env: [String]
    var cwd: String?
}
