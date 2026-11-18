import Foundation
import IOKit

/// Statistics the IORegistry keeps as properties: every object's "Statistics", "Stats", "PerformanceStatistics"
/// and "PowerTelemetryData" dictionaries (block storage, APFS containers and volumes, GPU, Thunderbolt, battery),
/// plus the scalar properties of the battery and the power manager (sleep and wake reasons). The plane is walked
/// once; reads look objects up by registry id.
final class RegistryCounters: CounterSource {
    let kind = CounterSourceKind.ioreg

    static let statKeys = ["Statistics", "Stats", "PerformanceStatistics", "PowerTelemetryData"]
    /// Classes whose own top-level scalars are worth listing.
    private static let wholeClasses: [String: String] = [
        "AppleSmartBattery": "Battery (AppleSmartBattery)",
        "IOPMrootDomain": "Power manager (IOPMrootDomain)",
    ]

    /// Per group: the objects to read and, per object, its counter id prefix and the property to flatten
    /// (nil: the object's top-level scalars).
    private struct Target { var entryID: UInt64; var prefix: String; var property: String? }
    private var targets: [String: [Target]] = [:]

    func groups() -> [CounterGroup] {
        targets = [:]
        var byGroup: [String: (name: String, note: String, counters: [CounterInfo])] = [:]
        var it: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        var names: [String: Int] = [:]
        while case let e = IOIteratorNext(it), e != 0 {
            defer { IOObjectRelease(e) }
            let cls = Self.className(e)
            var found: [(String?, [(String, CounterValue)])] = []
            for key in Self.statKeys {
                guard let v = IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                      v is NSDictionary else { continue }
                var flat: [(String, CounterValue)] = []
                Self.flatten(v, prefix: "", depth: 0, into: &flat)
                if !flat.isEmpty { found.append((key, flat)) }
            }
            if Self.wholeClasses[cls] != nil { found.append((nil, Self.scalars(e, cls))) }
            guard !found.isEmpty else { continue }
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(e, &entryID)
            var object = Self.label(e)
            names[cls + object, default: 0] += 1
            if let n = names[cls + object], n > 1 { object += " #\(n)" }
            for (property, flat) in found {
                let gid = "ioreg|" + cls + (property.map { "|" + $0 } ?? "")
                let gname = property == nil ? Self.wholeClasses[cls]! : "\(cls) \(property!)"
                let note = property == nil ? "Properties of \(cls) objects in the IORegistry" : "The \"\(property!)\" property of \(cls) objects in the IORegistry"
                let prefix = [gid, object].joined(separator: "|")
                targets[gid, default: []].append(Target(entryID: entryID, prefix: prefix, property: property))
                var g = byGroup[gid] ?? (gname, note, [])
                for (k, v) in flat {
                    let format: CounterInfo.Format = if case .text = v { .text } else { .number }
                    g.counters.append(CounterInfo(id: prefix + "|" + k, group: gid, name: k, sub: object,
                                                  unit: Self.unit(of: k), format: format))
                }
                byGroup[gid] = g
            }
        }
        return byGroup.map { CounterGroup(id: $0.key, source: .ioreg, name: $0.value.name, note: $0.value.note, counters: $0.value.counters) }
            .sorted { $0.name < $1.name }
    }

    func read(_ groups: Set<String>?) -> [String: CounterValue] {
        var out: [String: CounterValue] = [:]
        for (gid, list) in targets where groups?.contains(gid) ?? true {
            for t in list {
                let e = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(t.entryID))
                guard e != 0 else { continue }
                defer { IOObjectRelease(e) }
                var flat: [(String, CounterValue)] = []
                if let p = t.property {
                    guard let v = IORegistryEntryCreateCFProperty(e, p as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { continue }
                    Self.flatten(v, prefix: "", depth: 0, into: &flat)
                } else {
                    flat = Self.scalars(e, Self.className(e))
                }
                for (k, v) in flat { out[t.prefix + "|" + k] = v }
            }
        }
        return out
    }

    // MARK: Helpers

    private static func className(_ e: io_object_t) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(e, &buf)
        return String(cString: buf)
    }

    /// The object's name, with the BSD name of the disk under it when there is one ("IOBlockStorageDriver" alone
    /// says nothing).
    private static func label(_ e: io_object_t) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(e, &buf)
        var s = String(cString: buf)
        if let bsd = IORegistryEntrySearchCFProperty(e, kIOServicePlane, "BSD Name" as CFString, kCFAllocatorDefault,
                                                     IOOptionBits(kIORegistryIterateRecursively)) as? String {
            s += " (\(bsd))"
        }
        return s
    }

    /// Dictionaries of a whole class's object that are flattened with its scalars: the battery's capacities
    /// (health is NominalChargeCapacity / DesignCapacity) and the adapter's watts.
    private static let nestedKeys: [String: Set<String>] = ["AppleSmartBattery": ["BatteryData", "AdapterDetails"]]

    private static func scalars(_ e: io_object_t, _ cls: String) -> [(String, CounterValue)] {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(e, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return [] }
        let nested = nestedKeys[cls] ?? []
        var out: [(String, CounterValue)] = []
        for (k, v) in d.sorted(by: { $0.key < $1.key }) where nested.contains(k) || (!(v is NSDictionary) && !(v is NSArray)) {
            flatten(v, prefix: k, depth: 0, into: &out)
        }
        return out
    }

    /// Numbers, booleans and short strings, with nested dictionaries' keys joined by " › ".
    static func flatten(_ v: Any, prefix: String, depth: Int, into out: inout [(String, CounterValue)]) {
        switch v {
        case let d as NSDictionary:
            guard depth < 4 else { return }
            for case let (k as String, x) in d.sorted(by: { "\($0.key)" < "\($1.key)" }) {
                flatten(x, prefix: prefix.isEmpty ? k : prefix + " › " + k, depth: depth + 1, into: &out)
            }
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                out.append((prefix, .text(n.boolValue ? "yes" : "no")))
            } else if CFNumberIsFloatType(n) {
                out.append((prefix, .double(n.doubleValue)))
            } else if n.int64Value < 0, CFNumberGetType(n) == .sInt64Type, n.uint64Value > UInt64(Int64.max) {
                out.append((prefix, .unsigned(n.uint64Value)))
            } else {
                out.append((prefix, .signed(n.int64Value)))
            }
        case let s as String where s.count <= 200:
            out.append((prefix, .text(s)))
        case let a as NSArray where a.count <= 16 && a.allSatisfy({ $0 is NSNumber }):
            out.append((prefix, .text(a.map { "\($0)" }.joined(separator: " "))))
        default:
            break
        }
    }

    /// Units the property names spell out ("Bytes (Read)", "Total Time (Write)" in ns).
    private static func unit(of key: String) -> String {
        let k = key.lowercased()
        if k.hasPrefix("bytes") || k.contains("memory") && !k.contains("count") { return "B" }
        if k.contains("time (") || k.hasPrefix("total time") || k.hasPrefix("latency time") { return "ns" }
        return ""
    }
}
