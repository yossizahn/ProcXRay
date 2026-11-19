import Darwin
import Foundation

/// The network stack's protocol statistics (what netstat -s and netstat -m print): sysctl net.inet.tcp.stats,
/// udp.stats, ip.stats, icmp.stats and kern.ipc.mbstat, decoded field by field with the SDK's structs (their sizes
/// match the kernel's on 27.2: 912, 104, 196, 368 and 584 bytes), so every field keeps its kernel name.
///
/// TCP's counters read as zeros for an unprivileged process (measured on 27.2; the others don't), so TCP comes
/// from the helper when it's installed, and is marked as such when it isn't.
final class ProtocolCounters: CounterSource {
    let kind = CounterSourceKind.proto

    private struct Proto { var key: String; var sysctl: String; var title: String; var read: (Data?) -> [(String, CounterValue)] }

    private static func decode<T>(_ blank: T, _ name: String, _ raw: Data?) -> [(String, CounterValue)] {
        var v = blank
        if let raw {
            guard raw.count == MemoryLayout<T>.size else { return [] }
            withUnsafeMutableBytes(of: &v) { _ = raw.copyBytes(to: $0) }
        } else {
            var len = MemoryLayout<T>.size
            let rc = withUnsafeMutableBytes(of: &v) { sysctlbyname(name, $0.baseAddress, &len, nil, 0) }
            guard rc == 0, len == MemoryLayout<T>.size else { return [] }
        }
        return fields(v)
    }

    /// Every numeric field, by its C name; arrays (icmp's per-type histograms) as "name[i]", nonzero ones only
    /// past 16 entries (mbstat's 256 mbuf types).
    static func fields(_ v: Any, prefix: String = "") -> [(String, CounterValue)] {
        var out: [(String, CounterValue)] = []
        for c in Mirror(reflecting: v).children {
            let name = prefix + (c.label ?? "")
            switch c.value {
            case let x as UInt32: out.append((name, .unsigned(UInt64(x))))
            case let x as UInt64: out.append((name, .unsigned(x)))
            case let x as UInt16: out.append((name, .unsigned(UInt64(x))))
            case let x as Int32: out.append((name, .signed(Int64(x))))
            case let x as Int64: out.append((name, .signed(x)))
            case let x as Int16: out.append((name, .signed(Int64(x))))
            default:
                let m = Mirror(reflecting: c.value)
                guard m.displayStyle == .tuple else { continue }
                let many = m.children.count > 16
                for (i, e) in m.children.enumerated() {
                    guard let n = (e.value as? UInt32).map(UInt64.init) ?? (e.value as? UInt16).map(UInt64.init) ?? (e.value as? Int16).map({ UInt64(max(0, $0)) }) else { continue }
                    if many && n == 0 { continue }
                    out.append(("\(name)[\(i)]", .unsigned(n)))
                }
            }
        }
        return out
    }

    private let protos: [Proto] = [
        Proto(key: "tcp", sysctl: "net.inet.tcp.stats", title: "TCP", read: { decode(tcpstat(), "net.inet.tcp.stats", $0) }),
        Proto(key: "udp", sysctl: "net.inet.udp.stats", title: "UDP", read: { decode(udpstat(), "net.inet.udp.stats", $0) }),
        Proto(key: "ip", sysctl: "net.inet.ip.stats", title: "IPv4", read: { decode(ipstat(), "net.inet.ip.stats", $0) }),
        Proto(key: "icmp", sysctl: "net.inet.icmp.stats", title: "ICMP", read: { decode(icmpstat(), "net.inet.icmp.stats", $0) }),
        Proto(key: "mbuf", sysctl: "kern.ipc.mbstat", title: "Network buffers (mbufs)", read: { decode(mbstat(), "kern.ipc.mbstat", $0) }),
    ]

    /// The sysctls only root reads in full; the helper reads them (HelperCounters.sysctlAllowlist).
    static let viaHelper: Set = ["net.inet.tcp.stats"]

    func groups() -> [CounterGroup] {
        protos.map { p in
            let gid = "proto|" + p.key
            let list = p.read(nil)
            var note = "sysctl \(p.sysctl), decoded with the SDK's struct (netstat -s)"
            if Self.viaHelper.contains(p.sysctl) { note += ". Zeros for an unprivileged reader: read through the helper when it's installed" }
            return CounterGroup(id: gid, source: .proto, name: p.title, note: note,
                                counters: list.map { CounterInfo(id: gid + "|" + $0.0, group: gid, name: $0.0,
                                                                 unit: $0.0.hasSuffix("byte") || $0.0.hasSuffix("bytes") ? "B" : "") })
        }
    }

    func read(_ groups: Set<String>?) -> [String: CounterValue] {
        var out: [String: CounterValue] = [:]
        let wanted = protos.filter { groups?.contains("proto|" + $0.key) ?? true }
        let remote = wanted.contains { Self.viaHelper.contains($0.sysctl) } ? HelperCounters.cached()?.sysctls : nil
        for p in wanted {
            for (k, v) in p.read(remote?[p.sysctl]) { out["proto|\(p.key)|\(k)"] = v }
        }
        return out
    }
}
