import Darwin
import Foundation
import IOKit

/// CPU cluster and GPU clocks, and GPU power, from IOReport (libIOReport, private, loaded at run time; no
/// privileges needed). One subscription covers three channel groups:
/// - "CPU Stats" / "CPU Complex Performance States": per cluster (ECPU, PCPU, PCPU1…, MCPU on newer chips),
///   cumulative time in IDLE/DOWN/OFF and in each performance state, lowest clock first.
/// - "GPU Stats" / "GPU Performance States", channel GPUPH: time in OFF and in P1…P15.
/// - "Energy Model", channel "GPU Energy": cumulative energy. The CPU energy channels in the same group read 0
///   for an unprivileged process (measured on M1, macOS 27.2); the PMP group's Energy Counters have the CPU's,
///   per cluster and per core, without privileges (the System Overview's CPU and Power tabs use them).
///
/// A state's clock comes from pmgr's DVFS tables in the IORegistry ("voltage-states<N>-sram" for the CPU,
/// "voltage-states9" for the GPU): pairs of (frequency, voltage), in Hz up to M3 and kHz from M4 on. Which
/// table belongs to which cluster changes from chip to chip, so a table is used only when it fits: as many
/// entries as the cluster has performance states (CPU), or no time spent past its end (GPU). A chip laid out
/// differently shows no clock rather than a wrong one. Measured on M1: E 600–2064 MHz (5 states), P 600–3204
/// MHz (15), GPU 396–1278 MHz (P1–P6 of 15). One sample costs ~1 ms.
final class ClusterReader: @unchecked Sendable {
    static let shared = ClusterReader()

    /// Cumulative readings; `ClusterStats.rates(since:)` compares two.
    struct Sample: Sendable {
        /// Per cluster kind ("E", "P", "M", "GPU"): time per state, idle states first.
        var states: [String: [(name: String, ticks: Int64)]] = [:]
        var gpuJoules: Double?
    }

    private typealias CopyGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias Merge = @convention(c) (CFMutableDictionary, CFMutableDictionary, CFTypeRef?) -> Void
    private typealias CreateSub = @convention(c) (UnsafeRawPointer?, CFMutableDictionary,
                                                  UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Str = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias IntAt = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias Count = @convention(c) (CFDictionary) -> Int32
    private typealias NameAt = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?

    private struct API {
        let samples: CreateSamples
        let group: Str, name: Str, unit: Str
        let int: IntAt, count: Count, stateName: NameAt, residency: IntAt
    }

    private let lock = NSLock()
    private var api: API?
    private var subscription: OpaquePointer?
    private var channels: CFMutableDictionary?
    /// Clock per performance state in MHz, by cluster kind.
    let tables: [String: [Double]]

    private init() {
        tables = Self.readTables()
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY) else { return }
        func f<T>(_ n: String) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: T.self) } }
        guard let copy: CopyGroup = f("IOReportCopyChannelsInGroup"), let merge: Merge = f("IOReportMergeChannels"),
              let sub: CreateSub = f("IOReportCreateSubscription"), let samples: CreateSamples = f("IOReportCreateSamples"),
              let group: Str = f("IOReportChannelGetGroup"), let name: Str = f("IOReportChannelGetChannelName"),
              let unit: Str = f("IOReportChannelGetUnitLabel"), let int: IntAt = f("IOReportSimpleGetIntegerValue"),
              let count: Count = f("IOReportStateGetCount"), let stateName: NameAt = f("IOReportStateGetNameForIndex"),
              let residency: IntAt = f("IOReportStateGetResidency") else { return }
        let api = API(samples: samples, group: group, name: name, unit: unit, int: int, count: count,
                      stateName: stateName, residency: residency)

        var parts: [CFMutableDictionary] = []
        if let c = copy("CPU Stats" as CFString, "CPU Complex Performance States" as CFString, 0, 0, 0)?.takeRetainedValue() { parts.append(c) }
        if let c = copy("GPU Stats" as CFString, "GPU Performance States" as CFString, 0, 0, 0)?.takeRetainedValue() { parts.append(c) }
        // The Energy Model group has ~100 channels (one per core and DVFS state); keep only the GPU's.
        if let c = copy("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
           let list = (c as NSDictionary)["IOReportChannels"] as? [CFDictionary] {
            let gpu = list.filter { (api.name($0)?.takeUnretainedValue() as String?) == "GPU Energy" }
            if !gpu.isEmpty {
                // Through NSMutableDictionary (toll-free bridged), which retains the key and value.
                (c as NSMutableDictionary)["IOReportChannels"] = gpu as NSArray
                parts.append(c)
            }
        }
        guard let first = parts.first else { return }
        for p in parts.dropFirst() { merge(first, p, nil) }
        var subbed: Unmanaged<CFMutableDictionary>?
        guard let s = sub(nil, first, &subbed, 0, nil), let chans = subbed?.takeRetainedValue() else { return }
        self.api = api
        self.subscription = s
        self.channels = chans
    }

    var available: Bool { api != nil }

    func read() -> Sample? {
        lock.lock(); defer { lock.unlock() }
        guard let api, let subscription, let channels,
              let raw = api.samples(subscription, channels, nil)?.takeRetainedValue(),
              let items = (raw as NSDictionary)["IOReportChannels"] as? [CFDictionary] else { return nil }
        var out = Sample()
        for it in items {
            let group = api.group(it)?.takeUnretainedValue() as String? ?? ""
            let name = api.name(it)?.takeUnretainedValue() as String? ?? ""
            if group == "Energy Model" {
                let unit = (api.unit(it)?.takeUnretainedValue() as String? ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                let scale: Double = switch unit { case "mj": 1e-3; case "uj", "µj": 1e-6; case "pj": 1e-12; default: 1e-9 }
                out.gpuJoules = (out.gpuJoules ?? 0) + Double(api.int(it, 0)) * scale
                continue
            }
            guard let kind = Self.kind(group: group, channel: name) else { continue }
            let n = api.count(it)
            guard n > 0 else { continue }
            var states = (0..<n).map { i in (name: api.stateName(it, i)?.takeUnretainedValue() as String? ?? "", ticks: api.residency(it, i)) }
            // Clusters of one kind (PCPU and PCPU1) share a table: add their times state by state.
            if let prev = out.states[kind], prev.count == states.count {
                for i in states.indices { states[i].ticks &+= prev[i].ticks }
            }
            out.states[kind] = states
        }
        return out
    }

    /// "ECPU" → E, "PCPU"/"PCPU1" → P, "MCPU" → M, "GPUPH" → GPU.
    private static func kind(group: String, channel: String) -> String? {
        if group == "GPU Stats" { return channel == "GPUPH" ? "GPU" : nil }
        guard group == "CPU Stats", channel.count >= 4 else { return nil }
        let base = channel.prefix { !$0.isNumber }
        guard base.count == 4, base.hasSuffix("CPU"), let k = base.first, "EPM".contains(k) else { return nil }
        return String(k)
    }

    /// pmgr's DVFS tables, in MHz. CPU tables are "-sram" entries; the GPU's is the plain voltage-states9.
    private static func readTables() -> [String: [Double]] {
        let keys = ["E": "voltage-states1-sram", "P": "voltage-states5-sram", "M": "voltage-states22-sram", "GPU": "voltage-states9"]
        var out: [String: [Double]] = [:]
        for service in ["pmgr", "pmgr-child"] {
            var it: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching(service), &it) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(it) }
            while case let e = IOIteratorNext(it), e != 0 {
                defer { IOObjectRelease(e) }
                for (kind, key) in keys where out[kind] == nil {
                    guard let data = IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?
                            .takeRetainedValue() as? Data, data.count >= 8 else { continue }
                    let words = data.withUnsafeBytes { raw in (0..<data.count / 4).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self) } }
                    let freqs = stride(from: 0, to: words.count - 1, by: 2).map { Double(words[$0]) }
                    // Hz (600 MHz = 6e8) up to M3, kHz (6e5) from M4.
                    let top = freqs.max() ?? 0
                    guard top > 0 else { continue }
                    out[kind] = freqs.map { top >= 1e7 ? $0 / 1e6 : $0 / 1e3 }
                }
            }
        }
        return out
    }
}

/// What a pair of `ClusterReader.Sample`s says about the interval between them.
struct ClusterStats: Sendable, Hashable {
    struct Cluster: Sendable, Hashable {
        /// "E", "P", "M" or "GPU".
        var kind: String
        /// Average clock while running (time-weighted over the performance states), in MHz; nil while the cluster
        /// stayed idle, or when the DVFS table doesn't fit this chip.
        var mhz: Double?
        /// Share of the interval spent running rather than idle/off (0…1).
        var active: Double
        /// The table's top clock, in MHz.
        var maxMHz: Double?

        var title: String {
            switch kind {
            case "E": "E-cores"
            case "P": "P-cores"
            case "M": "M-cores"
            default: kind
            }
        }
    }
    /// CPU clusters, efficiency first.
    var cpu: [Cluster] = []
    var gpu: Cluster?
    var gpuWatts: Double?

    static func rates(from a: ClusterReader.Sample, to b: ClusterReader.Sample, secs: Double, tables: [String: [Double]]) -> ClusterStats {
        var out = ClusterStats()
        for kind in ["E", "M", "P", "GPU"] {
            guard let x = a.states[kind], let y = b.states[kind], x.count == y.count else { continue }
            let d = zip(x, y).map { (name: $1.name, ticks: max(0, $1.ticks &- $0.ticks)) }
            let total = d.reduce(Int64(0)) { $0 &+ $1.ticks }
            guard total > 0 else { continue }
            let idle: Set = ["IDLE", "DOWN", "OFF"]
            let first = d.firstIndex { !idle.contains($0.name) } ?? d.count
            let running = d[first...]
            let busy = running.reduce(Int64(0)) { $0 &+ $1.ticks }
            var c = Cluster(kind: kind, active: Double(busy) / Double(total), maxMHz: tables[kind]?.max())
            if busy > 0, let table = tables[kind] {
                c.mhz = clock(running: Array(running), kind: kind, table: table, busy: busy)
            }
            if kind == "GPU" { out.gpu = c } else { out.cpu.append(c) }
        }
        if let ja = a.gpuJoules, let jb = b.gpuJoules, secs > 0, jb >= ja { out.gpuWatts = (jb - ja) / secs }
        return out
    }

    /// Time-weighted clock over the running states, in MHz; nil when the table doesn't fit.
    static func clock(running: [(name: String, ticks: Int64)], kind: String, table: [Double], busy: Int64) -> Double? {
        var sum = 0.0
        if kind == "GPU" {
            // P1…Pn index the table directly (entry 0 is the off state's 0 Hz).
            for s in running where s.ticks > 0 {
                guard s.name.first == "P", let i = Int(s.name.dropFirst()), i < table.count, table[i] > 0 else { return nil }
                sum += Double(s.ticks) * table[i]
            }
        } else {
            guard running.count == table.count else { return nil }
            for (s, f) in zip(running, table) { sum += Double(s.ticks) * f }
        }
        return sum / Double(busy)
    }
}
