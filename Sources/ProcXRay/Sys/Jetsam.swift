import Darwin

/// Where the kernel's memory killer (jetsam) puts a process, and the memory limit it enforces: what
/// `memorystatus_control` reports (libsystem_kernel SPI, not in the SDK). Root only (EPERM otherwise), so
/// other than in a root process it comes from the helper. Measured as root in the VM: the whole list in under
/// 0.1 ms and every process's limits in ~0.3 ms (326 processes).
struct JetsamInfo: Codable, Hashable, Sendable {
    /// Priority band: the lower, the sooner the process is killed when memory runs short. 0 is the idle band.
    /// macOS uses 0…210 here; Apple names no bands publicly, so none are named.
    var band: Int32
    /// The limit in force now, in MB; nil when there is none (the kernel's -1).
    var limitMB: Int32?
    /// The limits while the process is active and inactive (in MB, nil: none), when they could be read.
    var activeLimitMB: Int32?
    var inactiveLimitMB: Int32?
    /// The kernel's memorystatus state bits (undocumented; shown raw).
    var state: UInt32

    var limitBytes: UInt64? { limitMB.map { UInt64($0) << 20 } }
    var limitsDiffer: Bool { activeLimitMB != inactiveLimitMB }
}

enum Jetsam {
    @_silgen_name("memorystatus_control")
    private static func memorystatus_control(_ cmd: UInt32, _ pid: Int32, _ flags: UInt32,
                                             _ buffer: UnsafeMutableRawPointer?, _ size: Int) -> Int32

    private static let getPriorityList: UInt32 = 1         // MEMORYSTATUS_CMD_GET_PRIORITY_LIST
    private static let getMemlimitProperties: UInt32 = 8   // MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES

    /// memorystatus_priority_entry_t
    private struct Entry { var pid: Int32 = 0; var priority: Int32 = 0; var userData: UInt64 = 0; var limit: Int32 = 0; var state: UInt32 = 0 }
    /// memorystatus_memlimit_properties_t
    private struct Limits { var active: Int32 = 0; var activeAttr: UInt32 = 0; var inactive: Int32 = 0; var inactiveAttr: UInt32 = 0 }

    private static func mb(_ v: Int32) -> Int32? { v < 0 ? nil : v }

    /// Every process the kernel tracks, or nil when not permitted (not root).
    static func all() -> [pid_t: JetsamInfo]? {
        let need = memorystatus_control(getPriorityList, 0, 0, nil, 0)
        guard need > 0 else { return nil }
        // Room for processes started between the two calls.
        let stride = MemoryLayout<Entry>.stride
        var entries = [Entry](repeating: Entry(), count: Int(need) / stride + 64)
        let got = entries.withUnsafeMutableBytes { memorystatus_control(getPriorityList, 0, 0, $0.baseAddress, $0.count) }
        guard got > 0 else { return nil }
        var out: [pid_t: JetsamInfo] = [:]
        out.reserveCapacity(Int(got) / stride)
        for e in entries.prefix(Int(got) / stride) {
            var info = JetsamInfo(band: e.priority, limitMB: mb(e.limit), state: e.state)
            var l = Limits()
            if memorystatus_control(getMemlimitProperties, e.pid, 0, &l, MemoryLayout<Limits>.size) == 0 {
                info.activeLimitMB = mb(l.active)
                info.inactiveLimitMB = mb(l.inactive)
            }
            out[e.pid] = info
        }
        return out
    }
}
