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
