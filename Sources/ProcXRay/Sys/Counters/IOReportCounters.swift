import Foundation

/// Every IOReport channel (libIOReport, private, loaded at run time; no privileges needed). A channel is known by
/// its driver's registry id and its channel id, both in the legend. Reading a group subscribes to that group
/// alone: the cost is per driver, and some are slow (the Wi-Fi driver ~13–25 ms a sample on M1, PMP ~4 ms, AMC
/// Stats 0.1 ms), so the browser reads the groups on screen, and only the "what changes" pass reads them all
/// (one subscription to every channel, ~58 ms).
final class IOReportCounters: CounterSource {
    let kind = CounterSourceKind.ioreport

    private typealias CopyAll = @convention(c) (UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CopyGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSub = @convention(c) (UnsafeRawPointer?, CFMutableDictionary,
                                                  UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Str = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias Fmt = @convention(c) (CFDictionary) -> Int32
    private typealias IntAt = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias Count = @convention(c) (CFDictionary) -> Int32
    private typealias NameAt = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?

    private struct API {
        let all: CopyAll, group: CopyGroup, sub: CreateSub, samples: CreateSamples
        let groupName: Str, subName: Str, name: Str, unit: Str, driver: Str, format: Fmt
        let int: IntAt, stateCount: Count, stateName: NameAt, residency: IntAt
        let bucketCount: Count?, bucketHits: IntAt?, bucketMin: IntAt?, bucketMax: IntAt?
    }

    private struct Subscription { let sub: OpaquePointer; let channels: CFMutableDictionary }

    private let api: API?
    /// Channel key ("driverID:channelID") → counter id, and the group each key is in.
    private var ids: [String: String] = [:]
    private var subs: [String: Subscription] = [:]
    private var everything: Subscription?

    init() {
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY) else { api = nil; return }
        func f<T>(_ n: String) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: T.self) } }
        guard let all: CopyAll = f("IOReportCopyAllChannels"), let group: CopyGroup = f("IOReportCopyChannelsInGroup"),
              let sub: CreateSub = f("IOReportCreateSubscription"), let samples: CreateSamples = f("IOReportCreateSamples"),
              let groupName: Str = f("IOReportChannelGetGroup"), let subName: Str = f("IOReportChannelGetSubGroup"),
              let name: Str = f("IOReportChannelGetChannelName"), let unit: Str = f("IOReportChannelGetUnitLabel"),
              let driver: Str = f("IOReportChannelGetDriverName"), let format: Fmt = f("IOReportChannelGetFormat"),
              let int: IntAt = f("IOReportSimpleGetIntegerValue"), let stateCount: Count = f("IOReportStateGetCount"),
              let stateName: NameAt = f("IOReportStateGetNameForIndex"), let residency: IntAt = f("IOReportStateGetResidency")
        else { api = nil; return }
        api = API(all: all, group: group, sub: sub, samples: samples, groupName: groupName, subName: subName, name: name,
                  unit: unit, driver: driver, format: format, int: int, stateCount: stateCount, stateName: stateName,
                  residency: residency, bucketCount: f("IOReportHistogramGetBucketCount"), bucketHits: f("IOReportHistogramGetBucketHits"),
                  bucketMin: f("IOReportHistogramGetBucketMinValue"), bucketMax: f("IOReportHistogramGetBucketMaxValue"))
    }

    private static func key(_ ch: NSDictionary) -> String? {
        guard let d = (ch["DriverID"] as? NSNumber)?.uint64Value,
              let c = ((ch["LegendChannel"] as? [Any])?.first as? NSNumber)?.int64Value else { return nil }
        return "\(d):\(c)"
    }

    private func str(_ f: Str, _ ch: CFDictionary) -> String {
        (f(ch)?.takeUnretainedValue() as String? ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// "spi4 <id 0x100000275>" → "spi4".
    private static func driverName(_ s: String) -> String {
        s.range(of: " <id ").map { String(s[..<$0.lowerBound]) } ?? s
    }

    func groups() -> [CounterGroup] {
        guard let api, let all = api.all(0, 0)?.takeRetainedValue(),
              let list = (all as NSDictionary)["IOReportChannels"] as? [NSDictionary] else { return [] }
        ids = [:]
        var byGroup: [String: [CounterInfo]] = [:]
        var used: Set<String> = []
        for ch in list {
            let cf = ch as CFDictionary
            guard let key = Self.key(ch) else { continue }
            let group = str(api.groupName, cf), subgroup = str(api.subName, cf), name = str(api.name, cf)
            let driver = Self.driverName(str(api.driver, cf))
            let format: CounterInfo.Format = switch api.format(cf) {
            case 2: .state
            case 3: .histogram
            case 1: .number
            default: .text
            }
            let gid = "ioreport|" + group
            // Driver names repeat across instances (two "AppleT8103PMGR"…): number duplicates in listing order.
            var id = [gid, subgroup, driver, name].joined(separator: "|")
            if used.contains(id) {
                var n = 2
                while used.contains("\(id)#\(n)") { n += 1 }
                id += "#\(n)"
            }
            used.insert(id)
            ids[key] = id
            let sub = [subgroup, driver].filter { !$0.isEmpty }.joined(separator: " · ")
            byGroup[gid, default: []].append(CounterInfo(id: id, group: gid, name: name.isEmpty ? "(unnamed)" : name, sub: sub,
                                                         unit: str(api.unit, cf), format: format))
        }
        return byGroup.map { gid, counters in
            CounterGroup(id: gid, source: .ioreport, name: String(gid.dropFirst("ioreport|".count)),
                         note: "IOReport group \"\(gid.dropFirst("ioreport|".count))\", from \(Set(counters.map { $0.sub.components(separatedBy: " · ").last ?? "" }).count) driver(s)",
                         counters: counters)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func read(_ groups: Set<String>?) -> [String: CounterValue] {
        guard let api else { return [:] }
        var out: [String: CounterValue] = [:]
        if let groups {
            for g in groups { if let s = subscription(g) { sample(s, into: &out) } }
        } else {
            if everything == nil, let all = api.all(0, 0)?.takeRetainedValue() { everything = subscribe(all) }
            if let s = everything { sample(s, into: &out) }
        }
        return out
    }

    private func subscription(_ gid: String) -> Subscription? {
        if let s = subs[gid] { return s }
        guard let api, let ch = api.group(String(gid.dropFirst("ioreport|".count)) as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
              let s = subscribe(ch) else { return nil }
        subs[gid] = s
        return s
    }

    private func subscribe(_ channels: CFMutableDictionary) -> Subscription? {
        guard let api else { return nil }
        var subbed: Unmanaged<CFMutableDictionary>?
        guard let s = api.sub(nil, channels, &subbed, 0, nil), let c = subbed?.takeRetainedValue() else { return nil }
        return Subscription(sub: s, channels: c)
    }

    private func sample(_ s: Subscription, into out: inout [String: CounterValue]) {
        guard let api, let raw = api.samples(s.sub, s.channels, nil)?.takeRetainedValue(),
              let list = (raw as NSDictionary)["IOReportChannels"] as? [NSDictionary] else { return }
        for ch in list {
            guard let key = Self.key(ch), let id = ids[key] else { continue }
            let cf = ch as CFDictionary
            switch api.format(cf) {
            case 1:
                out[id] = .signed(api.int(cf, 0))
            case 2:
                let n = api.stateCount(cf)
                out[id] = .states((0..<max(0, n)).map { CounterState(name: api.stateName(cf, $0)?.takeUnretainedValue() as String? ?? "\($0)",
                                                                       residency: api.residency(cf, $0)) })
            case 3:
                guard let count = api.bucketCount, let hits = api.bucketHits, let lo = api.bucketMin, let hi = api.bucketMax else { continue }
                out[id] = .histogram((0..<max(0, count(cf))).map { CounterBucket(min: lo(cf, $0), max: hi(cf, $0), hits: hits(cf, $0)) })
            default:
                out[id] = .text("array channel (not decoded)")
            }
        }
    }
}
