import Darwin
import Foundation

/// Every readable sysctl node. The tree is walked once with the {0, 2} ("next") call, as sysctl -a does; each
/// node's type comes from {0, 4} ("oidfmt"). Integers, strings and the few structs sysctl(8) itself knows
/// (loadavg, timeval, xsw_usage, clockinfo) are read; other opaque structs are left out.
///
/// sysctl mixes counters with settings and doesn't say which is which: the browser's "changing only" filter is
/// what tells them apart.
final class SysctlCounters: CounterSource {
    let kind = CounterSourceKind.sysctl

    private enum Decode { case int, string, loadavg, timeval, swap, clockinfo }
    private struct Node { var mib: [Int32]; var decode: Decode; var unsigned: Bool; var wide: Bool }

    /// By group id, then counter id.
    private var nodes: [String: [(id: String, node: Node)]] = [:]

    private static let topNotes: [String: String] = [
        "kern": "Kernel", "vm": "Virtual memory", "hw": "Hardware", "net": "Networking", "vfs": "File systems",
        "machdep": "Machine-dependent", "security": "Security policy modules", "debug": "Debugging", "kperf": "Kernel performance sampling",
    ]

    func groups() -> [CounterGroup] {
        nodes = [:]
        var byGroup: [String: [CounterInfo]] = [:]
        var oid: [Int32] = [CTL_KERN]
        var seen = 0
        while let n = Self.next(oid), seen < 20_000 {
            seen += 1
            oid = n
            guard let name = Self.name(n), let (kind, fmt) = Self.format(n) else { continue }
            guard kind & 0x8000_0000 != 0, name != "kern.procname" else { continue }
            let type = Int32(kind & UInt32(CTLTYPE))
            let decode: Decode
            switch type {
            case CTLTYPE_INT, CTLTYPE_QUAD: decode = .int
            case CTLTYPE_STRING: decode = .string
            case CTLTYPE_OPAQUE:
                switch fmt {
                case "S,loadavg": decode = .loadavg
                case "S,timeval": decode = .timeval
                case "S,xsw_usage": decode = .swap
                case "S,clockinfo": decode = .clockinfo
                default: continue
                }
            default: continue
            }
            let parts = name.split(separator: ".", omittingEmptySubsequences: false)
            let depth = parts.count >= 3 ? 2 : 1
            let group = "sysctl|" + parts.prefix(depth).joined(separator: ".")
            let short = parts.dropFirst(depth).joined(separator: ".")
            let id = "sysctl|" + name
            let node = Node(mib: n, decode: decode, unsigned: fmt.hasSuffix("U"), wide: type == CTLTYPE_QUAD || fmt.hasPrefix("Q") || fmt.hasPrefix("L"))
            nodes[group, default: []].append((id, node))
            byGroup[group, default: []].append(CounterInfo(id: id, group: group, name: short.isEmpty ? name : short,
                                                           format: decode == .int ? .number : .text))
        }
        return byGroup.map { gid, counters in
            let name = String(gid.dropFirst("sysctl|".count))
            let top = String(name.prefix { $0 != "." })
            let note = (Self.topNotes[top].map { "\($0): " } ?? "") + "sysctl \(name).*"
            return CounterGroup(id: gid, source: .sysctl, name: name, note: note, counters: counters)
        }
        .sorted { $0.name < $1.name }
    }

    func read(_ groups: Set<String>?) -> [String: CounterValue] {
        var out: [String: CounterValue] = [:]
        for (gid, list) in nodes where groups?.contains(gid) ?? true {
            for (id, node) in list {
                if let v = Self.value(node) { out[id] = v }
            }
        }
        return out
    }

    // MARK: sysctl calls

    private static func next(_ oid: [Int32]) -> [Int32]? {
        var q: [Int32] = [0, 2] + oid
        var out = [Int32](repeating: 0, count: Int(CTL_MAXNAME))
        var len = out.count * MemoryLayout<Int32>.size
        guard sysctl(&q, u_int(q.count), &out, &len, nil, 0) == 0, len > 0 else { return nil }
        return Array(out.prefix(len / MemoryLayout<Int32>.size))
    }

    private static func name(_ oid: [Int32]) -> String? {
        var q: [Int32] = [0, 1] + oid
        var buf = [CChar](repeating: 0, count: 1024)
        var len = buf.count
        guard sysctl(&q, u_int(q.count), &buf, &len, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    private static func format(_ oid: [Int32]) -> (UInt32, String)? {
        var q: [Int32] = [0, 4] + oid
        var buf = [UInt8](repeating: 0, count: 256)
        var len = buf.count
        guard sysctl(&q, u_int(q.count), &buf, &len, nil, 0) == 0, len >= 4 else { return nil }
        let kind = buf.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return (kind, String(decoding: buf[4..<len].prefix { $0 != 0 }, as: UTF8.self))
    }

    private static func raw(_ mib: [Int32]) -> [UInt8]? {
        var m = mib
        var len = 0
        guard sysctl(&m, u_int(m.count), nil, &len, nil, 0) == 0, len > 0, len <= 64 * 1024 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&m, u_int(m.count), &buf, &len, nil, 0) == 0 else { return nil }
        return Array(buf.prefix(len))
    }

    private static func value(_ n: Node) -> CounterValue? {
        guard let b = raw(n.mib) else { return nil }
        return b.withUnsafeBytes { p -> CounterValue? in
            switch n.decode {
            case .int:
                // One value, or a short array (kern.monotonic.pmis) shown as text.
                // Width from the type, as sysctl(8) decides it: CTLTYPE_INT is 4 bytes per value even when 8
                // come back (kern.monotonic.pmis is two).
                let stride = n.wide && b.count % 8 == 0 ? 8 : 4
                guard b.count >= stride else { return nil }
                func at(_ i: Int) -> CounterValue {
                    if stride == 8 {
                        let v = p.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)
                        return n.unsigned ? .unsigned(v) : .signed(Int64(bitPattern: v))
                    }
                    let v = p.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                    return n.unsigned ? .unsigned(UInt64(v)) : .signed(Int64(Int32(bitPattern: v)))
                }
                let count = b.count / stride
                if count == 1 { return at(0) }
                return .text((0..<min(count, 16)).map { CounterText.value(at($0), unit: "") }.joined(separator: " "))
            case .string:
                return .text(String(decoding: b.prefix { $0 != 0 }, as: UTF8.self))
            case .loadavg:
                guard b.count >= MemoryLayout<loadavg>.size else { return nil }
                let l = p.loadUnaligned(as: loadavg.self)
                let s = Double(l.fscale)
                return .text(String(format: "%.2f %.2f %.2f", Double(l.ldavg.0) / s, Double(l.ldavg.1) / s, Double(l.ldavg.2) / s))
            case .timeval:
                guard b.count >= MemoryLayout<timeval>.size else { return nil }
                let t = p.loadUnaligned(as: timeval.self)
                guard t.tv_sec > 0 else { return .text("never") }
                let d = Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1e6)
                return .text(d.formatted(date: .abbreviated, time: .standard))
            case .swap:
                guard b.count >= MemoryLayout<xsw_usage>.size else { return nil }
                let x = p.loadUnaligned(as: xsw_usage.self)
                return .text("used \(Compact.bytes(Double(x.xsu_used)))B of \(Compact.bytes(Double(x.xsu_total)))B\(x.xsu_encrypted != 0 ? ", encrypted" : "")")
            case .clockinfo:
                guard b.count >= MemoryLayout<clockinfo>.size else { return nil }
                let c = p.loadUnaligned(as: clockinfo.self)
                return .text("hz \(c.hz), tick \(c.tick) µs, stathz \(c.stathz), profhz \(c.profhz)")
            }
        }
    }
}
