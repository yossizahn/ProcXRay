import Darwin
import Foundation

/// System counters only root can read, read by the helper (HelperProtocol.systemCounters) and shared by the
/// sources that show them. Measured as root in a VM (27.2): net.inet.tcp.stats goes from all zeros to real
/// counts; mach_memory_info on the host-priv port gives every kernel zone's size (650 zones, 186 MB), where an
/// unprivileged caller gets the zone names with every size zero.
struct HelperCounters: Codable, Sendable {
    /// Raw sysctl values by name, from `sysctlAllowlist` only.
    var sysctls: [String: Data] = [:]
    var zones: [Zone]?
    /// Why `zones` is nil.
    var zoneError: String?

    struct Zone: Codable, Sendable {
        var name: String
        /// Bytes the zone holds now (mzi_cur_size) and elements in use (mzi_count).
        var size: UInt64, count: UInt64
        var elementSize: UInt64
        /// Bytes ever allocated from the zone (mzi_sum_size): a counter, so its rate is the allocation rate.
        var allocated: UInt64
    }

    /// The only sysctls the helper reads for a caller: fixed names, no input from the app.
    static let sysctlAllowlist = ["net.inet.tcp.stats"]

    // MARK: Helper side (root)

    static func read() -> HelperCounters {
        var r = HelperCounters()
        for name in sysctlAllowlist {
            var len = 0
            guard sysctlbyname(name, nil, &len, nil, 0) == 0, len > 0, len <= 64 * 1024 else { continue }
            var buf = [UInt8](repeating: 0, count: len)
            if sysctlbyname(name, &buf, &len, nil, 0) == 0 { r.sysctls[name] = Data(buf.prefix(len)) }
        }
        switch zones() {
        case .success(let z): r.zones = z
        case .failure(let e): r.zoneError = e.message
        }
        return r
    }

    struct Failure: Error { var message: String }

    static func zones() -> Result<[Zone], Failure> {
        var priv: host_priv_t = 0
        // host_get_host_priv_port is a C macro for this.
        let pr = host_get_special_port(mach_host_self(), HOST_LOCAL_NODE, HOST_PRIV_PORT, &priv)
        guard pr == KERN_SUCCESS else { return .failure(Failure(message: "host_get_host_priv_port: \(String(cString: mach_error_string(pr)))")) }
        defer { mach_port_deallocate(mach_task_self_, priv) }
        var names: mach_zone_name_array_t?
        var info: mach_zone_info_array_t?
        var mem: mach_memory_info_array_t?
        var nc: mach_msg_type_number_t = 0, ic: mach_msg_type_number_t = 0, mc: mach_msg_type_number_t = 0
        let kr = mach_memory_info(priv, &names, &nc, &info, &ic, &mem, &mc)
        guard kr == KERN_SUCCESS, let names, let info else { return .failure(Failure(message: "mach_memory_info: \(String(cString: mach_error_string(kr)))")) }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: names)), vm_size_t(nc) * vm_size_t(MemoryLayout<mach_zone_name_t>.stride))
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(ic) * vm_size_t(MemoryLayout<mach_zone_info_t>.stride))
            if let mem { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: mem)), vm_size_t(mc) * vm_size_t(MemoryLayout<mach_memory_info_t>.stride)) }
        }
        return .success((0..<Int(min(nc, ic))).map { i in
            let n = withUnsafeBytes(of: names[i].mzn_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let z = info[i]
            return Zone(name: n, size: z.mzi_cur_size, count: z.mzi_count, elementSize: z.mzi_elem_size, allocated: z.mzi_sum_size)
        })
    }

    // MARK: App side

    private static let lock = NSLock()
    nonisolated(unsafe) private static var last: (at: Date, value: HelperCounters?) = (.distantPast, nil)

    /// The helper's reading, asked for at most every 0.5 s (TCP and zones are read in the same tick); nil when
    /// the helper isn't installed or didn't answer, and then not asked again for 30 s.
    static func cached() -> HelperCounters? {
        lock.lock(); defer { lock.unlock() }
        let age = -last.at.timeIntervalSinceNow
        if age < 0.5 || (last.value == nil && age < 30) { return last.value }
        last = (Date(), HelperClient.shared.systemCounters(timeout: 1))
        return last.value
    }
}

/// Kernel memory by zone, through the helper (HelperCounters). No group when the helper isn't installed.
final class ZoneCounters: CounterSource {
    let kind = CounterSourceKind.zones
    static let groupID = "zones|zones"
    private static let fields: [(String, String)] = [("size", "B"), ("elements", ""), ("element size", "B"), ("allocated since boot", "B")]

    func groups() -> [CounterGroup] {
        guard let zones = HelperCounters.cached()?.zones, !zones.isEmpty else { return [] }
        let counters = Self.unique(zones).flatMap { name, _ in
            Self.fields.map { f, unit in CounterInfo(id: "\(Self.groupID)|\(name)|\(f)", group: Self.groupID, name: f, sub: name, unit: unit) }
        }
        return [CounterGroup(id: Self.groupID, source: .zones, name: "Kernel zones",
                             note: "mach_memory_info on the host-priv port, read by the root helper (zprint's source)", counters: counters)]
    }

    func read(_ groups: Set<String>?) -> [String: CounterValue] {
        guard groups?.contains(Self.groupID) ?? true, let zones = HelperCounters.cached()?.zones else { return [:] }
        var out: [String: CounterValue] = [:]
        for (name, z) in Self.unique(zones) {
            let p = "\(Self.groupID)|\(name)|"
            out[p + "size"] = .unsigned(z.size)
            out[p + "elements"] = .unsigned(z.count)
            out[p + "element size"] = .unsigned(z.elementSize)
            out[p + "allocated since boot"] = .unsigned(z.allocated)
        }
        return out
    }

    /// Zone names repeat (per-CPU and kalloc variants): number the repeats in the kernel's order.
    private static func unique(_ zones: [HelperCounters.Zone]) -> [(String, HelperCounters.Zone)] {
        var seen: [String: Int] = [:]
        return zones.map { z in
            seen[z.name, default: 0] += 1
            let n = seen[z.name]!
            return (n > 1 ? "\(z.name) #\(n)" : z.name, z)
        }
    }
}
