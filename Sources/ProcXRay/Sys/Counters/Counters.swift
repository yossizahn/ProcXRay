import Foundation

/// Every system-wide counter macOS exposes, from six sources behind one interface: Mach host statistics,
/// sysctl, IOReport, IORegistry statistics properties, HID temperature sensors and network interfaces. A source lists its counters once (`groups()`) and
/// reads only the groups asked for (`read`), since a full read is costly for some of them: all 7,600 IOReport
/// channels take ~58 ms to sample on an M1, most of it in the Wi-Fi driver, against 0.1 ms for AMC Stats.
///
/// Values are what the source gives, since boot. Whether one is a cumulative counter or a gauge isn't marked by
/// most sources, so the browser shows both the value and its change per second.
enum CounterSourceKind: String, CaseIterable, Sendable {
    case mach, sysctl, ioreport, ioreg, sensors, net, smc, proto, zones

    var title: String {
        switch self {
        case .mach: "Mach host statistics"
        case .sysctl: "sysctl"
        case .ioreport: "IOReport"
        case .ioreg: "IORegistry"
        case .sensors: "Sensors"
        case .net: "Network interfaces"
        case .smc: "SMC"
        case .proto: "Network protocols"
        case .zones: "Kernel zones (helper)"
        }
    }

    var help: String {
        switch self {
        case .mach: "host_statistics64, host_processor_info and processor_set_statistics: the kernel's own totals for memory, CPU time, load and exited processes"
        case .sysctl: "Every readable sysctl node, found by walking the tree (sysctl's {0, 2} \"next\" call), as sysctl -a lists them"
        case .ioreport: "libIOReport channels that drivers publish: energy, clocks, memory bandwidth, interrupts, storage, Wi-Fi and more. Private API, loaded at run time"
        case .ioreg: "Statistics dictionaries in the IORegistry (disks, APFS, GPU, Thunderbolt) and the battery's and power manager's properties"
        case .sensors: "Temperature sensors of the HID event system (IOHIDEventSystemClient, private API)"
        case .net: "Each network interface's exact 64-bit counters (sysctl net.link.generic.ifdata)"
        case .smc: "Every key of the System Management Controller (AppleSMC user client): temperatures, power, voltages, currents, fans, battery"
        case .proto: "The network stack's protocol statistics (netstat -s, netstat -m); TCP's through the helper"
        case .zones: "The kernel's memory zones (zprint), read by the root helper"
        }
    }
}

/// One counter.
struct CounterInfo: Identifiable, Hashable, Sendable {
    /// "<source>|<group>|…". Stable across launches, so pins are saved by it.
    var id: String
    /// The `CounterGroup.id` it belongs to.
    var group: String
    var name: String
    /// What it belongs to within the group: an IOReport subgroup and driver, an IORegistry object.
    var sub: String = ""
    var unit: String = ""
    var format: Format = .number

    enum Format: Sendable { case number, state, histogram, text }
}

struct CounterGroup: Identifiable, Hashable, Sendable {
    var id: String
    var source: CounterSourceKind
    var name: String
    /// Where the values come from, for the group's tooltip.
    var note: String = ""
    var counters: [CounterInfo]
}

enum CounterValue: Sendable, Hashable {
    case signed(Int64)
    case unsigned(UInt64)
    case double(Double)
    /// Time spent in each state (IOReport state channels), in the channel's own ticks.
    case states([CounterState])
    case histogram([CounterBucket])
    case text(String)

    var number: Double? {
        switch self {
        case .signed(let v): Double(v)
        case .unsigned(let v): Double(v)
        case .double(let v): v
        default: nil
        }
    }

    /// The change from `a` to this value: exact for integers (counters near 2^64 lose nothing).
    func delta(from a: CounterValue) -> Double? {
        switch (a, self) {
        case let (.signed(x), .signed(y)): return Double(y &- x)
        case let (.unsigned(x), .unsigned(y)): return y >= x ? Double(y - x) : -Double(x - y)
        default:
            guard let x = a.number, let y = number else { return nil }
            return y - x
        }
    }
}

struct CounterState: Sendable, Hashable { var name: String; var residency: Int64 }
struct CounterBucket: Sendable, Hashable { var min: Int64; var max: Int64; var hits: Int64 }

struct CounterReading: Sendable {
    var at: UInt64 = DispatchTime.now().uptimeNanoseconds
    var values: [String: CounterValue] = [:]
}

/// A source of counters. Used only from `CounterEngine.queue`.
protocol CounterSource: AnyObject {
    var kind: CounterSourceKind { get }
    func groups() -> [CounterGroup]
    /// The values of the given groups' counters (by counter id); nil reads every group.
    func read(_ groups: Set<String>?) -> [String: CounterValue]
}

/// All sources. Every call runs on `queue`, which keeps the sources' caches (sysctl MIBs, IOReport
/// subscriptions, registry entry ids) to one thread.
final class CounterEngine: @unchecked Sendable {
    static let shared = CounterEngine()
    let queue = DispatchQueue(label: "procxray.counters", qos: .utility)
    private let sources: [CounterSource] = [MachCounters(), SysctlCounters(), IOReportCounters(), RegistryCounters(),
                                            SensorCounters(), InterfaceCounters(), SMCCounters(), ProtocolCounters(), ZoneCounters()]
    private var cached: [CounterGroup]?

    /// Every counter, listed once and shared by the browser and the Overview. Listing is costly (~200 ms: the
    /// IOReport and IORegistry walks); `refresh` lists again (disks, interfaces and drivers come and go).
    func catalog(refresh: Bool = false) -> [CounterGroup] {
        dispatchPrecondition(condition: .onQueue(queue))
        if let cached, !refresh { return cached }
        let g = sources.flatMap { $0.groups() }
        cached = g
        return g
    }

    /// Reads the given groups (nil: all of them).
    func read(_ groups: Set<String>?) -> CounterReading {
        dispatchPrecondition(condition: .onQueue(queue))
        var r = CounterReading()
        for s in sources {
            let mine = groups.map { $0.filter { $0.hasPrefix(s.kind.rawValue + "|") } }
            if let mine, mine.isEmpty { continue }
            r.values.merge(s.read(mine)) { a, _ in a }
        }
        r.at = DispatchTime.now().uptimeNanoseconds
        return r
    }

    /// The group a counter id belongs to, from the id alone: "<source>|<group>|…", where an IORegistry group
    /// adds the property ("ioreg|<class>|<property>") and sysctl, sensor and interface ids are "<source>|<group>|<name>"
    /// except sysctl, whose group is the name's first one or two parts.
    static func groupID(of id: String) -> String? {
        let parts = id.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard let kind = parts.first.flatMap(CounterSourceKind.init(rawValue:)), parts.count >= 2 else { return nil }
        switch kind {
        case .sysctl:
            let name = parts[1].split(separator: ".", omittingEmptySubsequences: false)
            return "sysctl|" + name.prefix(name.count >= 3 ? 2 : 1).joined(separator: ".")
        case .ioreg:
            // "ioreg|<class>|<property>|<object>|<key>", or "ioreg|<class>|<object>|<key>" for a whole class.
            guard parts.count >= 3 else { return nil }
            return parts.prefix(RegistryCounters.statKeys.contains(parts[2]) ? 3 : 2).joined(separator: "|")
        default:
            return parts.prefix(2).joined(separator: "|")
        }
    }

    static func source(of id: String) -> CounterSourceKind? {
        id.firstIndex(of: "|").flatMap { CounterSourceKind(rawValue: String(id[..<$0])) }
    }

    /// Ids whose value changed between two readings.
    static func changed(_ a: CounterReading, _ b: CounterReading) -> Set<String> {
        Set(b.values.compactMap { id, v in a.values[id].map { $0 != v ? id : nil } ?? nil })
    }

    // MARK: Snapshot

    /// Every counter with its value now, as JSON: {"at", "counters": {id: {"group", "name", "unit", "value"}}}, values
    /// as numbers where they are numbers. For comparing two moments or two Macs.
    static func snapshot(_ groups: [CounterGroup], _ r: CounterReading) -> Data {
        var out: [String: Any] = [:]
        for g in groups {
            for c in g.counters {
                guard let v = r.values[c.id] else { continue }
                var e: [String: Any] = ["group": g.name, "name": c.name]
                if !c.unit.isEmpty { e["unit"] = c.unit }
                if !c.sub.isEmpty { e["sub"] = c.sub }
                switch v {
                case .signed(let x): e["value"] = x
                case .unsigned(let x): e["value"] = x
                case .double(let x): e["value"] = x
                case .text(let s): e["value"] = s
                case .states(let s): e["value"] = Dictionary(s.map { ($0.name, $0.residency) }, uniquingKeysWith: +)
                case .histogram(let b): e["value"] = b.map { ["min": $0.min, "max": $0.max, "hits": $0.hits] }
                }
                out[c.id] = e
            }
        }
        let doc: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date()), "counters": out]
        return (try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys, .prettyPrinted])) ?? Data()
    }

    // MARK: Command line

    /// `--counters [seconds] [filter]`: every counter whose id contains `filter`, with its value and change per
    /// second over `seconds`, and what each source cost to list and read.
    static func dump(seconds: Double, filter: String?, json: Bool = false) {
        let e = shared
        if json {
            // --counters --json: one reading of everything, as `snapshot` writes it.
            let data = e.queue.sync { snapshot(e.catalog(), e.read(nil)) }
            FileHandle.standardOutput.write(data)
            return
        }
        e.queue.sync {
            func ms(_ t: UInt64) -> String { String(format: "%.1f ms", Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6) }
            var groups: [CounterGroup] = []
            for s in e.sources {
                let t = DispatchTime.now().uptimeNanoseconds
                let g = s.groups()
                FileHandle.standardError.write(Data("\(s.kind.title): \(g.count) groups, \(g.reduce(0) { $0 + $1.counters.count }) counters, listed in \(ms(t))\n".utf8))
                groups += g
            }
            var readings: [CounterReading] = []
            for pass in 0..<2 {
                if pass == 1 { Thread.sleep(forTimeInterval: seconds) }
                var r = CounterReading()
                for s in e.sources {
                    let t = DispatchTime.now().uptimeNanoseconds
                    r.values.merge(s.read(nil)) { a, _ in a }
                    if pass == 1 { FileHandle.standardError.write(Data("\(s.kind.title): read all in \(ms(t))\n".utf8)) }
                }
                r.at = DispatchTime.now().uptimeNanoseconds
                readings.append(r)
            }
            let (a, b) = (readings[0], readings[1])
            let secs = Double(b.at - a.at) / 1e9
            var shown = 0, changing = 0, total = 0
            for g in groups {
                for c in g.counters {
                    total += 1
                    let v = b.values[c.id]
                    if let x = a.values[c.id], let v, x != v { changing += 1 }
                    if let filter, !filter.isEmpty, !c.id.localizedCaseInsensitiveContains(filter) { continue }
                    var line = "\(c.id)\t\(CounterText.value(v, unit: c.unit))"
                    if let x = a.values[c.id], let v, let d = v.delta(from: x), d != 0 { line += "\t\(CounterText.rate(d / secs, unit: c.unit))" }
                    print(line)
                    shown += 1
                }
            }
            FileHandle.standardError.write(Data("\(total) counters, \(changing) changed in \(String(format: "%.1f", secs)) s, \(shown) shown\n".utf8))
        }
    }
}

/// Text for values and rates, shared by the browser and `--counters`.
enum CounterText {
    private static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 3
        return f
    }()

    static func value(_ v: CounterValue?, unit: String) -> String {
        guard let v else { return "—" }
        switch v {
        case .signed(let x): return number(Double(x), exact: grouped.string(from: NSNumber(value: x)), unit: unit)
        case .unsigned(let x): return number(Double(x), exact: grouped.string(from: NSNumber(value: x)), unit: unit)
        case .double(let x): return number(x, exact: grouped.string(from: NSNumber(value: x)), unit: unit)
        case .text(let s): return s
        case .states(let s):
            let total = s.reduce(Int64(0)) { $0 &+ max(0, $1.residency) }
            guard total > 0, let top = s.max(by: { $0.residency < $1.residency }) else { return "\(s.count) states" }
            return "\(s.count) states, most in \(top.name.trimmingCharacters(in: .whitespaces)) (\(Int((Double(top.residency) / Double(total) * 100).rounded())) %)"
        case .histogram(let b):
            return "\(b.count) buckets, \(grouped.string(from: NSNumber(value: b.reduce(Int64(0)) { $0 &+ $1.hits })) ?? "") hits"
        }
    }

    private static func number(_ v: Double, exact: String?, unit: String) -> String {
        let s = exact ?? String(v)
        switch unit {
        case "B", "bytes": return abs(v) >= 1024 ? "\(Compact.bytes(v))B (\(s))" : "\(s) B"
        case "": return s
        default: return "\(s) \(unit)"
        }
    }

    /// A change per second, in the unit's natural rate: energy as watts, bytes as B/s, time as cores busy.
    static func rate(_ r: Double, unit: String) -> String {
        switch unit.lowercased() {
        case "mj": return watts(r / 1e3)
        case "uj", "µj": return watts(r / 1e6)
        case "nj": return watts(r / 1e9)
        case "pj": return watts(r / 1e12)
        case "b", "bytes": return (r < 0 ? "−" : "") + Compact.bytes(abs(r)) + "B/s"
        case "ns": return String(format: "%.2f cores", r / 1e9)
        default: return short(r) + "/s"
        }
    }

    private static func watts(_ w: Double) -> String {
        abs(w) < 1 ? String(format: "%.0f mW", w * 1e3) : String(format: "%.2f W", w)
    }

    static func short(_ v: Double) -> String {
        let a = abs(v)
        let (d, s): (Double, String) = a >= 1e12 ? (1e12, "T") : a >= 1e9 ? (1e9, "G") : a >= 1e6 ? (1e6, "M") : a >= 1e4 ? (1e3, "K") : (1, "")
        let x = v / d
        return (abs(x) >= 100 || (d == 1 && x == x.rounded()) ? String(format: "%.0f", x) : String(format: "%.1f", x)) + s
    }
}
