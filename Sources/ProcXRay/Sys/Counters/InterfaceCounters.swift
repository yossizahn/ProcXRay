import Darwin
import Foundation

/// Each network interface's counters, from the interface MIB (sysctl net.link.generic.ifdata, IFMIB_IFDATA):
/// exact 64-bit counts. NET_RT_IFLIST2, which getifaddrs-style readers use, cuts the byte counts to 32 bits and
/// rounds them down to 1 KiB on macOS 27.2 (measured: en0 10,542,904,749 bytes in through the MIB, 1,952,969,728
/// through IFLIST2, i.e. the same mod 2^32, rounded). One group per interface present when the catalog was made.
final class InterfaceCounters: CounterSource {
    let kind = CounterSourceKind.net

    static let fields: [(name: String, unit: String)] = [
        ("bytes in", "B"), ("bytes out", "B"), ("packets in", ""), ("packets out", ""),
        ("errors in", ""), ("errors out", ""), ("drops in", ""), ("collisions", ""),
        ("multicast in", ""), ("multicast out", ""), ("unknown protocol", ""),
        ("link speed", "bit/s"), ("MTU", ""), ("state", ""),
    ]

    func groups() -> [CounterGroup] {
        Self.list().map { i in
            let gid = "net|" + i.name
            return CounterGroup(id: gid, source: .net, name: i.name, note: "Interface \(i.name): sysctl net.link.generic.ifdata (IFMIB_IFDATA, if_data64)",
                                counters: Self.fields.map { f in
                                    CounterInfo(id: gid + "|" + f.name, group: gid, name: f.name, unit: f.unit, format: f.name == "state" ? .text : .number)
                                })
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func read(_ groups: Set<String>?) -> [String: CounterValue] {
        var out: [String: CounterValue] = [:]
        for i in Self.list() {
            let gid = "net|" + i.name
            guard groups?.contains(gid) ?? true else { continue }
            let d = i.data
            let vals: [UInt64] = [d.ifi_ibytes, d.ifi_obytes, d.ifi_ipackets, d.ifi_opackets, d.ifi_ierrors, d.ifi_oerrors,
                                  d.ifi_iqdrops, d.ifi_collisions, d.ifi_imcasts, d.ifi_omcasts, d.ifi_noproto, d.ifi_baudrate,
                                  UInt64(d.ifi_mtu)]
            for (f, v) in zip(Self.fields, vals) { out[gid + "|" + f.name] = .unsigned(v) }
            let up = i.flags & UInt32(IFF_UP) != 0, running = i.flags & UInt32(IFF_RUNNING) != 0
            out[gid + "|state"] = .text(up ? (running ? "up" : "up, no link") : "down")
        }
        return out
    }

    struct Interface { var name: String; var flags: UInt32; var data: if_data64 }

    /// Every interface, from the interface MIB: net.link.generic.system.ifcount, then each index's ifmibdata.
    static func list() -> [Interface] {
        var count: UInt32 = 0
        var size = MemoryLayout<UInt32>.size
        var cmib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_SYSTEM, IFMIB_IFCOUNT]
        guard sysctl(&cmib, 5, &count, &size, nil, 0) == 0 else { return [] }
        var out: [Interface] = []
        for idx in 1...max(1, Int32(count)) {
            var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, idx, IFDATA_GENERAL]
            var d = ifmibdata()
            var len = MemoryLayout<ifmibdata>.size
            guard sysctl(&mib, 6, &d, &len, nil, 0) == 0 else { continue }
            let name = withUnsafeBytes(of: d.ifmd_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            out.append(Interface(name: name, flags: d.ifmd_flags, data: d.ifmd_data))
        }
        return out
    }
}
