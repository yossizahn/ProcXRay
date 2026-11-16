import Darwin

/// The runtime hardening the kernel turned on for a process: what `os_security_config_get_for_proc`
/// (macOS 26, <os/security_config.h>) reports. That function is `proc_pidinfo(PROC_PIDTBSDINFO)` with five
/// undocumented `pbi_flags` bits moved into its own bitmask (disassembled on 27.2; the decoding below matched
/// it on all 612 processes compared). Read here directly so the app and the helper share one path and no
/// availability check is needed. Same user, or root.
struct SecurityConfig: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt64
    // os_security_config_t values.
    static let hardenedHeap = SecurityConfig(rawValue: 0x1)
    static let tpro = SecurityConfig(rawValue: 0x2)
    static let mte = SecurityConfig(rawValue: 0x4)
    static let scriptRestrictions = SecurityConfig(rawValue: 0x40)
    static let guardObjects = SecurityConfig(rawValue: 0x100)

    /// pbi_flags bit → flag, as libsystem_platform maps them.
    private static let bits: [(UInt32, SecurityConfig)] = [
        (1 << 28, .hardenedHeap), (1 << 29, .tpro), (1 << 26, .mte), (1 << 30, .scriptRestrictions), (1 << 31, .guardObjects),
    ]

    init(rawValue: UInt64) { self.rawValue = rawValue }
    init(bsdFlags f: UInt32) {
        self = Self.bits.reduce(into: []) { if f & $1.0 != 0 { $0.insert($1.1) } }
    }

    static func read(_ pid: pid_t) -> SecurityConfig? {
        var b = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &b, size) == size else { return nil }
        return SecurityConfig(bsdFlags: b.pbi_flags)
    }

    /// Each flag with its name and what the SDK header says it is. Apple documents no more than that for
    /// script restrictions and guard objects, so nothing more is claimed here.
    static let all: [(SecurityConfig, name: String, about: String)] = [
        (.hardenedHeap, "Hardened heap", "security-critical settings for the system memory allocator"),
        (.tpro, "TPRO", "Trusted Path Read-Only: memory that stays read-only except to trusted code paths"),
        (.mte, "Memory tagging (MTE)", "hardware memory tags, which catch out-of-bounds and use-after-free accesses"),
        (.scriptRestrictions, "Script restrictions", "script restrictions are enabled"),
        (.guardObjects, "Guard objects", "the guard objects configuration is enabled"),
    ]
}

/// The public flags plus the kernel's own records behind them, read through a task name port (own
/// processes; root for all): TASK_SECURITY_CONFIG_INFO (32) and TASK_IPC_SPACE_POLICY_INFO (33), both new in
/// the macOS 26 SDK and undocumented beyond "configuration bitmask".
struct SecurityDetail: Codable, Equatable, Sendable {
    var config: SecurityConfig
    var kernel: KernelSecurityConfig?
    var ipcPolicy: IPCSpacePolicy?

    static func read(_ pid: pid_t) -> SecurityDetail? {
        guard let config = SecurityConfig.read(pid) else { return nil }
        var d = SecurityDetail(config: config)
        var t: mach_port_t = 0
        guard task_name_for_pid(mach_task_self_, pid, &t) == KERN_SUCCESS else { return d }
        defer { mach_port_deallocate(mach_task_self_, t) }
        func word(_ flavor: Int32) -> UInt32? {
            var v: UInt32 = 0
            var count = mach_msg_type_number_t(1)
            let r = withUnsafeMutablePointer(to: &v) {
                $0.withMemoryRebound(to: integer_t.self, capacity: 1) { task_info(t, task_flavor_t(flavor), $0, &count) }
            }
            return r == KERN_SUCCESS ? v : nil
        }
        d.kernel = word(32).map(KernelSecurityConfig.init)
        d.ipcPolicy = word(33).map(IPCSpacePolicy.init)
        return d
    }
}

/// TASK_SECURITY_CONFIG_INFO: the kernel's task_security_config bitfield. Fields worked out on macOS 27.2 by
/// signing a test binary with each hardened-process entitlement and reading its own value, then checked
/// against 443 running processes: every field below matched on all of them, except `noTaggedReceive`, which
/// is from those processes only (it matched the entitlement on 443 of 443; the test binary, on a Mac without
/// MTE, didn't get it).
struct KernelSecurityConfig: Codable, Equatable, Sendable {
    let raw: UInt32
    init(_ raw: UInt32) { self.raw = raw }
    private func bit(_ n: UInt32) -> Bool { raw & (1 << n) != 0 }

    var hardenedHeap: Bool { bit(0) }
    var tpro: Bool { bit(1) }
    /// Bits 3–5. 0: none; 2: the `hardened-process.platform-restrictions` entitlement (any value gave 2);
    /// 3: what Apple's own binaries get without it (347 of 347 arm64e ones here, and a few arm64 ones).
    var platformRestrictions: UInt32 { (raw >> 3) & 7 }
    var scriptRestrictions: Bool { bit(6) }
    /// `hardened-process.containment.ipc`.
    var ipcContainment: Bool { bit(7) }
    var guardObjects: Bool { bit(8) }
    /// `hardened-process.containment.vm.cow-defeatured`.
    var vmCopyOnWriteDefeatured: Bool { bit(9) }
    /// `hardened-process.checked-allocations.no-tagged-receive` (MTE).
    var noTaggedReceive: Bool { bit(11) }
    /// Bits 16–23: the enhanced-security version, 0 when not a hardened process. 2 by default; 1 when
    /// `hardened-process.enhanced-security-version` says 1, which also leaves guard objects off.
    var enhancedSecurityVersion: UInt32 { (raw >> 16) & 0xff }
    /// Bits set that no field above explains.
    var unexplained: UInt32 { raw & ~(0x1 | 0x2 | 0x38 | 0x40 | 0x80 | 0x100 | 0x200 | 0x800 | 0xff0000) }
}

/// TASK_IPC_SPACE_POLICY_INFO: the task's IPC space policy. Only partly understood; observed on 27.2:
/// 0x1 for a plain third-party binary, level 1 (0x103) for third-party arm64 apps, 3 (0x303) with the
/// platform-restrictions entitlement, 4 (0x407) for Apple's arm64e binaries.
struct IPCSpacePolicy: Codable, Equatable, Sendable {
    let raw: UInt32
    init(_ raw: UInt32) { self.raw = raw }
    /// Bits 8–15.
    var level: UInt32 { (raw >> 8) & 0xff }
    /// 0x8: the `hardened-process.containment.ipc` entitlement (verified with a signed test binary).
    var ipcContainment: Bool { raw & 0x8 != 0 }
    /// 0x80: set on exactly the Apple arm64e processes that run without TPRO (16 of 16, and on none of the 331
    /// with it). What it means isn't known.
    var withoutTPRO: Bool { raw & 0x80 != 0 }
}
