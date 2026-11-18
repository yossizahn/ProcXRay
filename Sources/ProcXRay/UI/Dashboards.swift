import Darwin
import Foundation

/// The counters one dashboard tick sees, with lookups by group and name. Curated panels find counters by name
/// within a group, never by a full id: driver names and channel sets differ from chip to chip, and a panel shows
/// nothing rather than something wrong when a name isn't there.
struct DashContext {
    let groups: [String: CounterGroup]
    let values: [String: CounterValue]
    let previous: [String: CounterValue]
    let rates: [String: Double]
    let extras: OverviewExtras

    func counters(_ gid: String) -> [CounterInfo] { groups[gid]?.counters ?? [] }

    func first(_ gid: String, _ name: String) -> CounterInfo? { counters(gid).first { $0.name == name } }

    func num(_ c: CounterInfo?) -> Double? { c.flatMap { values[$0.id]?.number } }
    func num(_ gid: String, _ name: String) -> Double? { num(first(gid, name)) }
    func rate(_ c: CounterInfo?) -> Double? { c.flatMap { rates[$0.id] } }
    func rate(_ gid: String, _ name: String) -> Double? { rate(first(gid, name)) }
    func text(_ c: CounterInfo?) -> String? {
        guard let c, let v = values[c.id] else { return nil }
        if case .text(let s) = v { return s }
        return CounterText.value(v, unit: c.unit)
    }

    /// Ticks spent in each state since the previous reading.
    func stateDelta(_ c: CounterInfo) -> [(name: String, ticks: Int64)]? {
        guard case .states(let b)? = values[c.id], case .states(let a)? = previous[c.id], a.count == b.count else { return nil }
        return zip(a, b).map { (name: $1.name, ticks: max(0, $1.residency &- $0.residency)) }
    }

    /// An energy counter's rate as watts (IOReport units mJ, µJ, nJ).
    func watts(_ c: CounterInfo?) -> Double? {
        guard let c, let r = rates[c.id] else { return nil }
        switch c.unit.lowercased() {
        case "mj": return r / 1e3
        case "uj", "µj": return r / 1e6
        case "nj": return r / 1e9
        case "pj": return r / 1e12
        default: return nil
        }
    }

    /// An IOReport counter's subgroup (its `sub` is "subgroup · driver").
    static func subgroup(_ c: CounterInfo) -> String { c.sub.components(separatedBy: " · ").first ?? "" }
}

enum Dashboards {
    // MARK: Groups to read

    static func groups(for tab: SystemOverview.Tab, in catalog: [String: CounterGroup]) -> Set<String> {
        func have(_ ids: [String]) -> [String] { ids.filter { catalog[$0] != nil } }
        let ids: [String]
        switch tab {
        case .cpu:
            ids = have(["mach|cpu", "mach|percpu", "mach|pset", "mach|load", "mach|expired", "ioreport|CPU Stats", "ioreport|PMP",
                        "ioreport|Interrupt Statistics (by index)"])
        case .memory:
            ids = have(["mach|vm", "sysctl|vm", "sysctl|vm.compressor", "sysctl|hw", "sysctl|kern", "ioreport|AMC Stats", ZoneCounters.groupID])
        case .power:
            ids = have(["ioreg|AppleSmartBattery", "ioreg|AppleSmartBattery|PowerTelemetryData", "ioreport|PMP", "ioreg|IOPMrootDomain", "sysctl|kern"])
        case .thermal:
            ids = have([SensorCounters.groupID, "smc|F"])
        case .storage:
            ids = have(["ioreg|IOBlockStorageDriver|Statistics", "ioreg|AppleAPFSVolume|Statistics", "sysctl|vfs.vnstats", "sysctl|kern"])
        case .network:
            ids = catalog.keys.filter { $0.hasPrefix("net|") } + have(["sysctl|net.necp", "sysctl|net.local", "sysctl|net.systm", "ioreport|Chip",
                                                                         "proto|tcp", "proto|udp", "proto|ip", "proto|mbuf"])
        case .gpu:
            ids = catalog.keys.filter { $0.hasPrefix("ioreg|") && $0.hasSuffix("|PerformanceStatistics") }
                + have(["ioreport|GPU Stats", "ioreport|PMP", "ioreport|AMC Stats", "ioreport|Energy Model"])
        }
        return Set(ids)
    }

    static func build(_ tab: SystemOverview.Tab, _ c: DashContext) -> [Panel] {
        let panels: [Panel] = switch tab {
        case .cpu: cpu(c)
        case .memory: memory(c)
        case .power: power(c)
        case .thermal: thermal(c)
        case .storage: storage(c)
        case .network: network(c)
        case .gpu: gpu(c)
        }
        // Panels with nothing in them (a counter this Mac doesn't have) are left out.
        return panels.filter {
            switch $0.kind {
            case .tiles(let m), .bars(let m), .facts(let m): !m.isEmpty
            case .table(_, let rows, _): !rows.isEmpty
            case .note: true
            }
        }
    }

    // MARK: Formatting

    static func pct(_ v: Double) -> String { String(format: v < 10 ? "%.1f %%" : "%.0f %%", v) }
    static func bytes(_ v: Double) -> String { Compact.bytes(v) + "B" }
    static func bps(_ v: Double) -> String { Compact.bytes(v) + "B/s" }
    static func perSec(_ v: Double) -> String { CounterText.short(v) + "/s" }
    static func count(_ v: Double) -> String { Int64(v).formatted() }
    static func watts(_ w: Double) -> String { w < 1 ? String(format: "%.0f mW", w * 1e3) : String(format: "%.2f W", w) }
    static func mhz(_ v: Double) -> String { v >= 1000 ? String(format: "%.2f GHz", v / 1000) : String(format: "%.0f MHz", v) }

    private static let timebase: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    /// Average clock and busy share over a state channel's last interval, as `ClusterStats` works it out for a
    /// cluster: the states after the idle ones, weighted by time, against pmgr's DVFS table for that kind.
    static func clock(_ d: [(name: String, ticks: Int64)], kind: String) -> (mhz: Double?, active: Double)? {
        let total = d.reduce(Int64(0)) { $0 &+ $1.ticks }
        guard total > 0 else { return nil }
        let idle: Set = ["IDLE", "DOWN", "OFF"]
        let first = d.firstIndex { !idle.contains($0.name) } ?? d.count
        let running = Array(d[first...])
        let busy = running.reduce(Int64(0)) { $0 &+ $1.ticks }
        var mhz: Double?
        if busy > 0, let table = ClusterReader.shared.tables[kind] {
            mhz = ClusterStats.clock(running: running, kind: kind, table: table, busy: busy)
        }
        return (mhz, Double(busy) / Double(total))
    }

    // MARK: CPU

    static func cpu(_ c: DashContext) -> [Panel] {
        var tiles: [Metric] = []
        let st = ["user", "system", "idle", "nice"]
        let r = st.map { c.rate("mach|cpu", $0) }
        let coreCount = c.counters("mach|percpu").count / 4
        if let u = r[0], let s = r[1], let i = r[2] {
            let n = r[3] ?? 0, all = u + s + i + n
            if all > 0 {
                let use = (u + s + n) / all * 100
                // Busy cores from the share, not the raw rate: the 10 ms tick counters run ahead of or behind the
                // reading interval, so the rates alone can add up to more cores than there are.
                tiles.append(Metric(id: "cpu.use", title: "CPU use", value: use, text: pct(use),
                                    sub: String(format: "%.1f of %d cores busy", use / 100 * Double(coreCount), coreCount),
                                    help: "Time all cores spent running rather than idle over the last second (HOST_CPU_LOAD_INFO)",
                                    counter: c.first("mach|cpu", "user")?.id, max: 100))
                tiles.append(Metric(id: "cpu.kernel", title: "Kernel time", value: s / all * 100, text: pct(s / all * 100),
                                    sub: String(format: "user %@", pct((u + n) / all * 100)),
                                    help: "Share of all cores' time spent in the kernel (CPU_STATE_SYSTEM)",
                                    counter: c.first("mach|cpu", "system")?.id, max: 100))
            }
        }
        if let l5 = c.num("mach|load", "load_5s") {
            tiles.append(Metric(id: "cpu.load", title: "Load (5 s · 30 s · 60 s)", value: l5, text: String(format: "%.2f", l5),
                                sub: String(format: "%.2f · %.2f", c.num("mach|load", "load_30s") ?? 0, c.num("mach|load", "load_60s") ?? 0),
                                help: "Runnable threads averaged over 5, 30 and 60 seconds (HOST_LOAD_INFO avenrun). uptime's 1, 5 and 15 minute figures are sysctl vm.loadavg",
                                counter: c.first("mach|load", "load_5s")?.id))
        }
        if let th = c.num("mach|pset", "threads") {
            tiles.append(Metric(id: "cpu.threads", title: "Threads", value: th, text: count(th),
                                sub: c.num("mach|pset", "tasks").map { "in \(count($0)) tasks" } ?? "",
                                help: "Threads and tasks the kernel has, kernel_task's included (PROCESSOR_SET_LOAD_INFO)",
                                counter: c.first("mach|pset", "threads")?.id))
        }
        let irq = c.counters("ioreport|Interrupt Statistics (by index)")
        let irqCounts = irq.filter { $0.name == "First Level Interrupt Handler Count" }
        let irqTimes = irq.filter { $0.name == "First Level Interrupt Handler Time (MATUs)" }
        if !irqCounts.isEmpty {
            let n = irqCounts.compactMap { c.rate($0) }.reduce(0, +)
            let t = irqTimes.compactMap { c.rate($0) }.reduce(0, +) * timebase   // ns per second
            tiles.append(Metric(id: "cpu.irq", title: "Interrupts", value: n, text: perSec(n),
                                sub: String(format: "handlers %.1f ms/s", t / 1e6),
                                help: "Hardware interrupts handled per second, and the time their first-level handlers took (IOReport Interrupt Statistics)",
                                counter: irqCounts.first?.id))
        }
        let energy = c.counters("ioreport|PMP").filter { DashContext.subgroup($0) == "Energy Counters" }
        let clusters = energy.filter { $0.name.count == 4 && $0.name.hasSuffix("CPU") }
        let cw = clusters.compactMap { x in c.watts(x).map { (x.name, $0) } }
        if !cw.isEmpty {
            let total = cw.reduce(0) { $0 + $1.1 }
            tiles.append(Metric(id: "cpu.power", title: "CPU power", value: total, text: watts(total),
                                sub: cw.map { "\($0.0.prefix(1)) \(watts($0.1))" }.joined(separator: " · "),
                                help: "Energy the CPU clusters used over the last second (IOReport PMP Energy Counters: ECPU, PCPU)",
                                counter: clusters.first?.id))
        }
        if let eu = c.rate("mach|expired", "user"), let es = c.rate("mach|expired", "system") {
            let total = ((c.num("mach|expired", "user") ?? 0) + (c.num("mach|expired", "system") ?? 0)) / 1e9
            tiles.append(Metric(id: "cpu.exited", title: "Exited processes", value: (eu + es) / 1e9,
                                text: String(format: "+%.2f s", (eu + es) / 1e9),
                                sub: String(format: "%.1f h of CPU since boot", total / 3600),
                                help: "CPU time of processes that exited in the last second, added as they exit, and the total since boot (HOST_EXPIRED_TASK_INFO): the work of processes too short-lived for the process list to see",
                                counter: c.first("mach|expired", "user")?.id))
        }
        var panels = [Panel(id: "cpu.tiles", title: "", kind: .tiles(tiles))]

        // Per core: use, clock and power. host_processor_info lists efficiency cores first.
        let kinds = SystemStats.coreKinds
        let coreStates = c.counters("ioreport|CPU Stats").filter { DashContext.subgroup($0) == "CPU Core Performance States" }
        var cores: [Metric] = []
        for i in 0..<c.counters("mach|percpu").count / 4 {
            let rr = st.map { c.rate("mach|percpu", "cpu\(i).\($0)") }
            guard let u = rr[0], let s = rr[1], let idle = rr[2] else { continue }
            let n = rr[3] ?? 0, all = u + s + idle + n
            guard all > 0 else { continue }
            let use = (u + s + n) / all * 100
            let (k, j) = kinds.performance > 0 && i >= kinds.efficiency ? ("P", i - kinds.efficiency) : (kinds.performance > 0 ? "E" : "", i)
            var sub: [String] = []
            if let ch = coreStates.first(where: { $0.name == "\(k)CPU\(j)" }), let d = c.stateDelta(ch), let cl = clock(d, kind: k) {
                sub.append(cl.active < 0.005 ? "idle" : cl.mhz.map(mhz) ?? "")
            }
            if let w = c.watts(energy.first { $0.name == "\(k)CORE\(j)" }) { sub.append(watts(w)) }
            cores.append(Metric(id: "cpu.core\(i)", title: k.isEmpty ? "Core \(i)" : "\(k == "E" ? "Efficiency" : "Performance") core \(j)",
                                value: use, text: pct(use), sub: sub.filter { !$0.isEmpty }.joined(separator: " · "),
                                help: "Core \(i): busy share (PROCESSOR_CPU_LOAD_INFO), average clock while running (IOReport CPU Core Performance States with pmgr's DVFS table) and power (PMP Energy Counters)",
                                counter: c.first("mach|percpu", "cpu\(i).user")?.id, max: 100))
        }
        panels.append(Panel(id: "cpu.cores", title: "Cores", kind: .bars(cores)))

        // Clusters: share of time running and the clock while running.
        var cl: [Metric] = []
        for ch in c.counters("ioreport|CPU Stats") where DashContext.subgroup(ch) == "CPU Complex Performance States"
            && ch.name.count == 4 && ch.name.hasSuffix("CPU") {
            let k = String(ch.name.prefix(1))
            guard let d = c.stateDelta(ch), let x = clock(d, kind: k) else { continue }
            let title = ["E": "Efficiency cluster", "P": "Performance cluster", "M": "M cluster"][k] ?? ch.name
            cl.append(Metric(id: "cpu.cluster.\(ch.name)", title: "\(title) (\(ch.name))", value: x.active * 100,
                             text: x.mhz.map(mhz) ?? (x.active < 0.005 ? "idle" : "–"),
                             sub: "running \(pct(x.active * 100)) of the time",
                             help: "Share of the last second the cluster spent out of its idle states, and its time-weighted clock meanwhile (IOReport CPU Complex Performance States)",
                             counter: ch.id, max: 100))
        }
        panels.append(Panel(id: "cpu.clusters", title: "Clusters", kind: .bars(cl)))

        // Interrupts by source: the subgroup without its index ("usb-drd0 3" → usb-drd0).
        var bySource: [String: (n: Double, t: Double, id: String)] = [:]
        for x in irqCounts {
            let src = DashContext.subgroup(x).replacingOccurrences(of: #"\s+\d+$"#, with: "", options: .regularExpression)
            bySource[src, default: (0, 0, x.id)].n += c.rate(x) ?? 0
        }
        for x in irqTimes {
            let src = DashContext.subgroup(x).replacingOccurrences(of: #"\s+\d+$"#, with: "", options: .regularExpression)
            bySource[src, default: (0, 0, x.id)].t += (c.rate(x) ?? 0) * timebase
        }
        let top = bySource.filter { $0.value.n > 0 }.sorted { $0.value.n > $1.value.n }.prefix(12)
        panels.append(Panel(id: "cpu.irq", title: "Interrupts by source",
                            help: "IOReport Interrupt Statistics, summed per interrupt source over its vectors",
                            kind: .bars(top.map { k, v in
                                Metric(id: "cpu.irq.\(k)", title: k, value: v.n, text: perSec(v.n),
                                       sub: String(format: "handler %.0f µs/s", v.t / 1e3), counter: v.id)
                            })))
        return panels
    }

    // MARK: Memory

    static let agentNames: [String: String] = [
        "PCPU": "Performance cores (PCPU)", "ECPU": "Efficiency cores (ECPU)", "GFX": "GPU (GFX)", "GFX1": "GPU (GFX1)",
        "ANE": "Neural Engine (ANE)", "ANS2": "SSD controller (ANS2)", "DISP": "Display (DISP)", "DISPEXT": "External display (DISPEXT)",
        "PCIE": "PCIe", "ISP": "Camera image processor (ISP)", "VDEC": "Video decoder (VDEC)", "VENC": "Video encoder (VENC)",
        "JPG": "JPEG codec (JPG)", "ATC0": "USB-C port 0 (ATC0)", "ATC1": "USB-C port 1 (ATC1)",
    ]

    static func memory(_ c: DashContext) -> [Panel] {
        let page = Double(vm_kernel_page_size)
        func pages(_ n: String) -> Double? { c.num("mach|vm", n).map { $0 * page } }
        func pageRate(_ n: String) -> Double? { c.rate("mach|vm", n).map { $0 * page } }
        let total = c.num("sysctl|hw", "memsize")
        var tiles: [Metric] = []
        let app = (pages("internal_pages") ?? 0) - (pages("purgeable") ?? 0)
        if let wired = pages("wired"), let comp = pages("compressor_pages") {
            let used = max(0, app) + wired + comp
            tiles.append(Metric(id: "mem.used", title: "Memory used", value: used, text: bytes(used),
                                sub: total.map { "of \(bytes($0))" } ?? "",
                                help: "App memory (anonymous, not purgeable) + wired + compressed, as Activity Monitor adds it (HOST_VM_INFO64)",
                                counter: c.first("mach|vm", "internal_pages")?.id, max: total))
            if let unc = pages("uncompressed_pages_in_compressor"), comp > 0 {
                tiles.append(Metric(id: "mem.compressed", title: "Compressed", value: comp, text: bytes(comp),
                                    sub: String(format: "holds %@ (%.1f×)", bytes(unc), unc / comp),
                                    help: "Memory the compressor occupies, and how much uncompressed data it holds (compressor_page_count, total_uncompressed_pages_in_compressor)",
                                    counter: c.first("mach|vm", "compressor_pages")?.id))
            }
        }
        if let level = c.num("sysctl|kern", "memorystatus_level") {
            let p = c.extras.pressure
            tiles.append(Metric(id: "mem.available", title: "Available", value: level, text: "\(Int(level)) %",
                                sub: p.map { "pressure: " + ($0 == 4 ? "critical" : $0 == 2 ? "warning" : "normal") } ?? "",
                                help: "The share of memory the kernel counts as available, which its pressure levels are decided from (kern.memorystatus_level, kern.memorystatus_vm_pressure_level)",
                                counter: c.first("sysctl|kern", "memorystatus_level")?.id, max: 100))
        }
        if let used = c.extras.swapUsed {
            tiles.append(Metric(id: "mem.swap", title: "Swap used", value: Double(used), text: bytes(Double(used)),
                                sub: c.extras.swapTotal.map { "of \(bytes(Double($0))) in swap files" } ?? "",
                                help: "sysctl vm.swapusage", counter: "sysctl|vm.swapusage"))
        }
        if let t = c.rate("ioreport|AMC Stats", "DCS RD"), let w = c.rate("ioreport|AMC Stats", "DCS WR") {
            tiles.append(Metric(id: "mem.dram", title: "DRAM traffic", value: t + w, text: bps(t + w),
                                sub: "read \(bps(t)) · write \(bps(w))",
                                help: "Bytes read from and written to DRAM over the last second (IOReport AMC Stats, DCS RD and DCS WR: the DRAM controller side)",
                                counter: c.first("ioreport|AMC Stats", "DCS RD")?.id))
        }
        let events: [(String, String, String, Bool)] = [
            ("faults", "Page faults", "Faults of every kind (HOST_VM_INFO64 faults)", false),
            ("zero_fill", "Zero-filled pages", "New pages handed out zeroed (zero_fill_count)", true),
            ("pageins", "Page-ins", "Pages read in from files (pageins)", true),
            ("pageouts", "Page-outs", "Pages written out to files (pageouts)", true),
            ("compressions", "Compressions", "Pages compressed (compressions)", true),
            ("decompressions", "Decompressions", "Pages decompressed (decompressions)", true),
            ("swapins", "Swap-ins", "Compressed pages read back from swap (swapins)", true),
            ("swapouts", "Swap-outs", "Compressed pages written to swap (swapouts)", true),
            ("purges", "Purges", "Purgeable pages discarded (purges)", false),
            ("cow_faults", "Copy-on-write faults", "cow_faults", false),
        ]
        for (n, title, help, asBytes) in events {
            guard let r = c.rate("mach|vm", n) else { continue }
            tiles.append(Metric(id: "mem.\(n)", title: title, value: r, text: asBytes ? bps(r * page) : perSec(r),
                                sub: asBytes ? perSec(r) + " pages" : "", help: help + ", per second", counter: c.first("mach|vm", n)?.id))
        }
        var panels = [Panel(id: "mem.tiles", title: "", kind: .tiles(tiles))]

        let parts: [(String, Double?, String, String)] = [
            ("App memory", app > 0 ? app : nil, "Anonymous memory that isn't purgeable (internal_page_count − purgeable_count)", "internal_pages"),
            ("Wired", pages("wired"), "Memory the kernel keeps resident (wire_count)", "wired"),
            ("Compressed", pages("compressor_pages"), "compressor_page_count", "compressor_pages"),
            ("Cached files", (pages("external_pages") ?? 0) + (pages("purgeable") ?? 0), "File-backed and purgeable pages that can be dropped (external_page_count + purgeable_count)", "external_pages"),
            ("Free", pages("free"), "free_count", "free"),
            ("Speculative", pages("speculative"), "Read-ahead pages not used yet (speculative_count)", "speculative"),
            ("Active", pages("active"), "Pages on the active queue (active_count)", "active"),
            ("Inactive", pages("inactive"), "Pages on the inactive queue, next to be reclaimed (inactive_count)", "inactive"),
        ]
        panels.append(Panel(id: "mem.parts", title: "Where memory is",
                            help: "Page counts from HOST_VM_INFO64. The queues (active, inactive) overlap the kinds above them, so the bars don't add up to the total",
                            kind: .bars(parts.compactMap { t, v, h, n in
                                v.map { Metric(id: "mem.part.\(n)", title: t, value: $0, text: bytes($0), help: h, counter: c.first("mach|vm", n)?.id, max: total) }
                            })))

        // DRAM traffic by agent: the "<agent> RD/WR" channels, without the controller-side (DCS) duplicates.
        var agents: [String: (rd: Double, wr: Double, id: String)] = [:]
        for x in c.counters("ioreport|AMC Stats") where DashContext.subgroup(x) == "Perf Counters" && !x.name.contains("DCS") {
            let isRead = x.name.hasSuffix(" RD"), isWrite = x.name.hasSuffix(" WR")
            guard isRead || isWrite, let r = c.rate(x) else { continue }
            var agent = String(x.name.dropLast(3))
            for p in ["NRT ", "RT "] where agent.hasPrefix(p) { agent = String(agent.dropFirst(p.count)) }
            var e = agents[agent] ?? (0, 0, x.id)
            if isRead { e.rd += r } else { e.wr += r }
            agents[agent] = e
        }
        panels.append(Panel(id: "mem.agents", title: "Memory requests by agent",
                            help: "Bytes each part of the chip read and wrote through the memory controller over the last second (IOReport AMC Stats, Perf Counters). These include requests the system-level cache served, so they add up to more than the DRAM traffic (measured on M1: 11 GB/s of requests against 4.5 GB/s at DRAM)",
                            kind: .bars(agents.filter { $0.value.rd + $0.value.wr > 0 }.sorted { $0.value.rd + $0.value.wr > $1.value.rd + $1.value.wr }
                                .map { a, v in
                                    Metric(id: "mem.agent.\(a)", title: agentNames[a] ?? a, value: v.rd + v.wr, text: bps(v.rd + v.wr),
                                           sub: "read \(bps(v.rd)) · write \(bps(v.wr))", counter: v.id)
                                })))

        // Kernel memory by zone (through the helper).
        let zoneCounters = c.counters(ZoneCounters.groupID)
        if zoneCounters.isEmpty {
            panels.append(Panel(id: "mem.zones", title: "Kernel memory by zone", kind: .note(
                "Kernel zone sizes need root: install the privileged helper (Settings ▸ Helper) to see them. Without it the kernel returns every zone's size as 0.")))
        } else {
            let byZone = Dictionary(grouping: zoneCounters, by: \.sub)
            var zones: [(String, Double, Double?, String?, String)] = []
            var total = 0.0
            for (zone, list) in byZone {
                guard let size = c.num(list.first { $0.name == "size" }) else { continue }
                total += size
                let n = c.num(list.first { $0.name == "elements" }) ?? 0, e = c.num(list.first { $0.name == "element size" }) ?? 0
                let alloc = c.rate(list.first { $0.name == "allocated since boot" })
                zones.append((zone, size, alloc, list.first?.id, "\(count(n)) × \(bytes(e))"))
            }
            panels.append(Panel(id: "mem.zones", title: "Kernel memory by zone, \(bytes(total)) in \(zones.count) zones",
                                help: "The kernel's allocator zones, largest first (mach_memory_info through the root helper, as zprint shows them)",
                                kind: .bars(zones.sorted { $0.1 > $1.1 }.prefix(15).map { z in
                                    Metric(id: "mem.zone.\(z.0)", title: z.0, value: z.1, text: bytes(z.1),
                                           sub: z.4 + (z.2.map { $0 > 0 ? " · allocating \(bps($0))" : "" } ?? ""), counter: z.3)
                                })))
        }

        // Compressor and swap since boot.
        var facts: [Metric] = []
        if let inB = c.num("sysctl|vm", "compressor_input_bytes"), let outB = c.num("sysctl|vm", "compressor_compressed_bytes"), outB > 0 {
            facts.append(Metric(id: "mem.ratio", title: "Compressed since boot", text: String(format: "%@ into %@ (%.1f×)", bytes(inB), bytes(outB), inB / outB),
                                help: "vm.compressor_input_bytes and vm.compressor_compressed_bytes", counter: c.first("sysctl|vm", "compressor_input_bytes")?.id))
        }
        if let seg = c.num("sysctl|vm.compressor", "segment.total") {
            facts.append(Metric(id: "mem.segments", title: "Compressor segments", text: count(seg),
                                help: "vm.compressor.segment.total", counter: c.first("sysctl|vm.compressor", "segment.total")?.id))
        }
        if let so = c.num("sysctl|vm.compressor", "swapper.swapouts_total") {
            let causes = c.counters("sysctl|vm.compressor").filter { $0.name.hasPrefix("swapper.swapouts_") && $0.name != "swapper.swapouts_total"
                && !$0.name.hasPrefix("swapper.swapouts_under") }
                .compactMap { x in c.num(x).flatMap { $0 > 0 ? "\(x.name.dropFirst("swapper.swapouts_".count)): \(count($0))" : nil } }
            facts.append(Metric(id: "mem.swapouts", title: "Swap-outs since boot", text: count(so) + (causes.isEmpty ? "" : " (" + causes.joined(separator: ", ") + ")"),
                                help: "Compressor segments swapped out, by what asked for it (vm.compressor.swapper.swapouts_*)",
                                counter: c.first("sysctl|vm.compressor", "swapper.swapouts_total")?.id))
        }
        panels.append(Panel(id: "mem.facts", title: "Compressor and swap", kind: .facts(facts)))

        let wakeNames = [
            "swap_threshold_exceeded": "Swap threshold reached", "fragmentation_detected": "Compressor fragmented",
            "thrashing_detected": "Thrashing detected", "free_below_reserved": "Free pages below reserve",
            "external_q_throttled": "File page queue throttled", "minor_compactions": "Minor compactions", "target_age": "Target age",
            "scavenger": "Scavenger",
        ]
        let wakes = c.counters("sysctl|vm.compressor").filter { $0.name.hasPrefix("swapper.wakeups.") && $0.name != "swapper.wakeups.total" }
            .compactMap { x -> Metric? in
                guard let v = c.num(x), v > 0 else { return nil }
                let term = String(x.name.dropFirst("swapper.wakeups.".count))
                return Metric(id: "mem.wake.\(term)", title: wakeNames[term].map { "\($0) (\(term))" } ?? term, value: v, text: count(v),
                              help: "vm.compressor.swapper.wakeups.\(term)", counter: x.id)
            }
            .sorted { ($0.value ?? 0) > ($1.value ?? 0) }
        panels.append(Panel(id: "mem.wakes", title: "Why the swapper woke, since boot",
                            help: "vm.compressor.swapper.wakeups.*: what woke the thread that swaps compressed memory out", kind: .bars(wakes)))
        return panels
    }

    // MARK: Power

    static let componentNames: [String: String] = [
        "ECPU": "Efficiency cores (ECPU)", "PCPU": "Performance cores (PCPU)", "MCPU": "M cores (MCPU)", "GPU": "GPU",
        "GPU SRAM": "GPU SRAM", "ANE": "Neural Engine (ANE)", "DRAM": "Memory (DRAM)", "DISP": "Display (DISP)",
        "ISP": "Camera image processor (ISP)", "AVE": "Video encoder (AVE)", "VDEC": "Video decoder (VDEC)",
        "SOC_AON": "Always-on part of the chip (SOC_AON)",
    ]

    static func power(_ c: DashContext) -> [Panel] {
        let bat = "ioreg|AppleSmartBattery", tel = "ioreg|AppleSmartBattery|PowerTelemetryData"
        var tiles: [Metric] = []
        if let load = c.num(tel, "SystemLoad") {
            var sub: [String] = []
            if let pin = c.num(tel, "SystemPowerIn"), pin > 0 { sub.append("adapter \(watts(pin / 1e3))") }
            if let bp = c.num(tel, "BatteryPower"), bp != 0 { sub.append("battery \(watts(abs(bp) / 1e3))") }
            tiles.append(Metric(id: "pwr.system", title: "System power", value: load / 1e3, text: watts(load / 1e3),
                                sub: sub.joined(separator: " · "),
                                help: "What the whole Mac draws, from the battery's power telemetry (AppleSmartBattery PowerTelemetryData SystemLoad, in mW), and how much comes in from the adapter (SystemPowerIn)",
                                counter: c.first(tel, "SystemLoad")?.id))
        }
        if let pctCharge = c.num(bat, "CurrentCapacity") {
            let charging = c.text(c.first(bat, "IsCharging")) == "yes", ext = c.text(c.first(bat, "ExternalConnected")) == "yes"
            let full = c.text(c.first(bat, "FullyCharged")) == "yes"
            tiles.append(Metric(id: "pwr.battery", title: "Battery", value: pctCharge, text: "\(Int(pctCharge)) %",
                                sub: charging ? "charging" : full ? "charged" : ext ? "on power adapter, not charging" : "on battery",
                                help: "AppleSmartBattery CurrentCapacity, IsCharging, ExternalConnected", counter: c.first(bat, "CurrentCapacity")?.id, max: 100))
        }
        let energy = c.counters("ioreport|PMP").filter { DashContext.subgroup($0) == "Energy Counters" }
        func w(_ n: String) -> (Double, String)? { energy.first { $0.name == n }.flatMap { x in c.watts(x).map { ($0, x.id) } } }
        let cpuW = energy.filter { $0.name.count == 4 && $0.name.hasSuffix("CPU") }.compactMap { c.watts($0) }
        if !cpuW.isEmpty {
            let s = cpuW.reduce(0, +)
            tiles.append(Metric(id: "pwr.cpu", title: "CPU", value: s, text: watts(s), help: "PMP Energy Counters: the CPU clusters",
                                counter: energy.first { $0.name.hasSuffix("CPU") }?.id))
        }
        for (n, title) in [("GPU", "GPU"), ("DRAM", "Memory (DRAM)"), ("DISP", "Display (DISP)"), ("ANE", "Neural Engine (ANE)")] {
            if let (v, id) = w(n) {
                tiles.append(Metric(id: "pwr.\(n)", title: title, value: v, text: watts(v), help: "PMP Energy Counters: \(n)", counter: id))
            }
        }
        var panels = [Panel(id: "pwr.tiles", title: "", kind: .tiles(tiles))]

        // Every component, the per-core channels aside (the CPU tab has them).
        let comps = energy.filter { $0.name.range(of: #"^[EPM]CORE\d+$"#, options: .regularExpression) == nil }
            .compactMap { x -> Metric? in
                guard let v = c.watts(x) else { return nil }
                return Metric(id: "pwr.c.\(x.name)", title: componentNames[x.name] ?? x.name, value: v, text: watts(v),
                              help: "IOReport PMP Energy Counters: \(x.name), over the last second. Some overlap (a cluster includes its cores), so they don't add up to the system's power",
                              counter: x.id)
            }
            .sorted { ($0.value ?? 0) > ($1.value ?? 0) }
        panels.append(Panel(id: "pwr.components", title: "Power by component",
                            help: "Energy the power manager (PMP) counts per part of the chip, as watts over the last second", kind: .bars(comps)))

        var facts: [Metric] = []
        if let nominal = c.num(bat, "BatteryData › NominalChargeCapacity"), let design = c.num(bat, "BatteryData › DesignCapacity"), design > 0 {
            facts.append(Metric(id: "pwr.health", title: "Maximum capacity", text: String(format: "%.0f %% (%@ of %@ mAh designed)", nominal / design * 100, count(nominal), count(design)),
                                help: "BatteryData NominalChargeCapacity ÷ DesignCapacity", counter: c.first(bat, "BatteryData › NominalChargeCapacity")?.id))
        }
        if let cycles = c.num(bat, "CycleCount") {
            facts.append(Metric(id: "pwr.cycles", title: "Cycle count", text: count(cycles) + (c.num(bat, "DesignCycleCount9C").map { " of \(count($0)) designed" } ?? ""),
                                counter: c.first(bat, "CycleCount")?.id))
        }
        if let v = c.num(bat, "Voltage") {
            facts.append(Metric(id: "pwr.voltage", title: "Voltage", text: String(format: "%.2f V", v / 1000), counter: c.first(bat, "Voltage")?.id))
        }
        if let a = c.num(bat, "InstantAmperage") ?? c.num(bat, "Amperage") {
            facts.append(Metric(id: "pwr.current", title: "Current", text: "\(count(a)) mA" + (a < 0 ? " (discharging)" : a > 0 ? " (charging)" : ""),
                                counter: c.first(bat, "InstantAmperage")?.id))
        }
        if let adapter = c.num(bat, "AdapterDetails › Watts") {
            facts.append(Metric(id: "pwr.adapter", title: "Power adapter", text: "\(Int(adapter)) W", counter: c.first(bat, "AdapterDetails › Watts")?.id))
        }
        if let t = c.num(bat, "TimeRemaining"), t > 0, t < 65535 {
            facts.append(Metric(id: "pwr.remaining", title: "Time remaining", text: "\(Int(t) / 60) h \(Int(t) % 60) min", counter: c.first(bat, "TimeRemaining")?.id))
        }
        panels.append(Panel(id: "pwr.battery", title: "Battery", help: "AppleSmartBattery properties in the IORegistry", kind: .facts(facts)))

        let rows = c.extras.assertions.map { a in
            TableRow(id: "\(a.pid)|\(a.type)|\(a.name)", cells: ["\(a.process) (\(a.pid))", a.type, a.name],
                     help: "Right-click to inspect \(a.process)", pid: a.pid)
        }
        panels.append(Panel(id: "pwr.assertions", title: "Keeping the Mac awake",
                            help: "Power assertions held right now, by process (IOPMCopyAssertionsByProcess), as pmset -g assertions lists them",
                            kind: rows.isEmpty ? .note("No process holds a power assertion.") : .table(columns: ["Process", "Assertion", "Reason"], rows: rows, leading: 3)))

        var sleep: [Metric] = []
        func k(_ n: String, _ title: String, _ help: String) {
            if let x = c.first("sysctl|kern", n), let t = c.text(x), !t.isEmpty { sleep.append(Metric(id: "pwr.\(n)", title: title, text: t, help: help, counter: x.id)) }
        }
        k("boottime", "Booted", "kern.boottime")
        k("sleeptime", "Last sleep", "kern.sleeptime")
        k("waketime", "Last wake", "kern.waketime")
        k("wakereason", "Wake reason", "kern.wakereason")
        if let x = c.counters("ioreg|IOPMrootDomain").first(where: { $0.name == "Last Sleep Reason" }), let t = c.text(x) {
            sleep.append(Metric(id: "pwr.sleepreason", title: "Last sleep reason", text: t, help: "IOPMrootDomain Last Sleep Reason", counter: x.id))
        }
        k("shutdownreason", "Previous shutdown", "kern.shutdownreason: how the last shutdown or restart before this boot happened")
        panels.append(Panel(id: "pwr.sleep", title: "Sleep and wake", kind: .facts(sleep)))
        return panels
    }

    // MARK: Thermal

    static func thermal(_ c: DashContext) -> [Panel] {
        var tiles: [Metric] = []
        if let th = c.extras.thermal {
            tiles.append(Metric(id: "th.pressure", title: "Thermal pressure", value: Double(th), text: SystemStats.thermalLevelName(th),
                                sub: th == 0 ? "not throttling" : "the system is slowing work down",
                                help: "The kernel's thermal pressure level (com.apple.system.thermalpressurelevel): nominal, moderate, heavy, trapping, sleeping",
                                max: 4))
        }
        let all = c.counters(SensorCounters.groupID).compactMap { x in c.num(x).map { (x, $0) } }
        let good = all.filter { $0.1 > 0 && $0.1 < 130 }
        if let hot = good.max(by: { $0.1 < $1.1 }) {
            tiles.append(Metric(id: "th.hottest", title: "Hottest sensor", value: hot.1, text: String(format: "%.1f °C", hot.1), sub: hot.0.name,
                                help: "The highest plausible reading of the HID temperature sensors", counter: hot.0.id))
        }
        for (title, key) in [("Efficiency cluster", "eACC"), ("Performance cluster", "pACC"), ("GPU", "GPU"), ("SSD (NAND)", "NAND"),
                             ("Battery", "battery"), ("Chip die (PMU tdie)", "tdie")] {
            let m = good.filter { $0.0.name.localizedCaseInsensitiveContains(key) }
            guard let hot = m.max(by: { $0.1 < $1.1 }) else { continue }
            tiles.append(Metric(id: "th.\(key)", title: title, value: hot.1, text: String(format: "%.1f °C", hot.1),
                                sub: m.count > 1 ? "hottest of \(m.count) sensors" : hot.0.name,
                                help: "HID temperature sensors whose name contains \"\(key)\"", counter: hot.0.id))
        }
        var panels = [Panel(id: "th.tiles", title: "", kind: .tiles(tiles))]
        panels.append(Panel(id: "th.all", title: "All sensors", help: "Every HID temperature sensor (IOHIDEventSystemClient), hottest first",
                            kind: .bars(good.sorted { $0.1 > $1.1 }.map { x, v in
                                Metric(id: "th.s.\(x.name)", title: x.name, value: v, text: String(format: "%.1f °C", v), counter: x.id, max: 110)
                            })))
        // Fans, from the SMC: F<n>Ac (actual), Mn and Mx (range), Tg (target), in rpm.
        let fanKeys = c.counters("smc|F")
        var fans: [Metric] = []
        for i in 0..<8 {
            guard let ac = fanKeys.first(where: { $0.name == "F\(i)Ac" }), let rpm = c.num(ac) else { continue }
            let mn = c.num(fanKeys.first { $0.name == "F\(i)Mn" }), mx = c.num(fanKeys.first { $0.name == "F\(i)Mx" })
            let tg = c.num(fanKeys.first { $0.name == "F\(i)Tg" })
            fans.append(Metric(id: "th.fan\(i)", title: "Fan \(i + 1)", value: rpm, text: "\(Int(rpm)) rpm",
                               sub: [tg.map { "target \(Int($0))" }, mn.flatMap { a in mx.map { "range \(Int(a))–\(Int($0))" } }].compactMap { $0 }.joined(separator: " · "),
                               help: "SMC keys F\(i)Ac, F\(i)Tg, F\(i)Mn, F\(i)Mx", counter: ac.id, max: mx))
        }
        panels.insert(Panel(id: "th.fans", title: "Fans", kind: .tiles(fans)), at: 1)
        let odd = all.count - good.count
        panels.append(Panel(id: "th.note", title: "", kind: .note(
            (odd > 0 ? "\(odd) sensor\(odd == 1 ? "" : "s") reading 0 °C or less, or 130 °C or more, \(odd == 1 ? "is" : "are") left out (All Counters ▸ Sensors lists them). " : "")
            + (fans.isEmpty ? "This Mac reports no fans (no SMC F…Ac keys)." : "")
            + " The SMC's own temperature keys (T…) are in All Counters ▸ SMC.")))
        return panels
    }

    // MARK: Storage

    static func storage(_ c: DashContext) -> [Panel] {
        let gid = "ioreg|IOBlockStorageDriver|Statistics"
        let byDisk = Dictionary(grouping: c.counters(gid), by: \.sub)
        var rows: [TableRow] = []
        var totR = 0.0, totW = 0.0, totOps = 0.0, any = false
        for (disk, list) in byDisk.sorted(by: { $0.key < $1.key }) {
            func r(_ n: String) -> Double? { c.rate(list.first { $0.name == n }) }
            func v(_ n: String) -> Double? { c.num(list.first { $0.name == n }) }
            guard let br = r("Bytes (Read)"), let bw = r("Bytes (Write)") else { continue }
            let ops = (r("Operations (Read)") ?? 0) + (r("Operations (Write)") ?? 0)
            let time = (r("Total Time (Read)") ?? 0) + (r("Total Time (Write)") ?? 0)
            let errors = (v("Errors (Read)") ?? 0) + (v("Errors (Write)") ?? 0)
            totR += br; totW += bw; totOps += ops; any = true
            let name = disk.range(of: #"\((\w+)\)$"#, options: .regularExpression).map { String(disk[$0].dropFirst().dropLast()) } ?? disk
            rows.append(TableRow(id: disk, cells: [name, bps(br), bps(bw),
                                                   perSec(ops), ops > 0 ? String(format: "%.2f ms", time / ops / 1e6) : "–", count(errors)],
                                 help: "IOBlockStorageDriver Statistics. Latency is Total Time ÷ Operations over the last second"))
        }
        var tiles: [Metric] = []
        if any {
            let first = c.counters(gid).first?.id
            tiles.append(Metric(id: "st.read", title: "Disk reads", value: totR, text: bps(totR), help: "Bytes read per second, every disk", counter: first))
            tiles.append(Metric(id: "st.write", title: "Disk writes", value: totW, text: bps(totW), help: "Bytes written per second, every disk", counter: first))
            tiles.append(Metric(id: "st.ops", title: "Disk operations", value: totOps, text: perSec(totOps), help: "Reads and writes per second, every disk", counter: first))
        }
        if let files = c.num("sysctl|kern", "num_files") {
            tiles.append(Metric(id: "st.files", title: "Open files", value: files, text: count(files),
                                sub: c.num("sysctl|kern", "maxfiles").map { "limit \(count($0))" } ?? "",
                                help: "File structures open system-wide (kern.num_files, kern.maxfiles)", counter: c.first("sysctl|kern", "num_files")?.id))
        }
        if let vn = c.num("sysctl|vfs.vnstats", "num_vnodes") {
            let recycled = c.rate("sysctl|vfs.vnstats", "num_recycledvnodes")
            tiles.append(Metric(id: "st.vnodes", title: "Vnodes", value: vn, text: count(vn),
                                sub: [c.num("sysctl|vfs.vnstats", "num_free_vnodes").map { "\(count($0)) free" }, recycled.map { "recycled \(perSec($0))" }]
                                    .compactMap { $0 }.joined(separator: " · "),
                                help: "The kernel's file-system nodes in memory (vfs.vnstats). Recycling means the cache is full and old entries are reused",
                                counter: c.first("sysctl|vfs.vnstats", "num_vnodes")?.id))
        }
        var panels = [Panel(id: "st.tiles", title: "", kind: .tiles(tiles))]
        panels.append(Panel(id: "st.disks", title: "Disks", kind: .table(columns: ["Disk", "Read", "Write", "Operations", "Latency", "Errors since boot"], rows: rows, leading: 1)))

        let vg = "ioreg|AppleAPFSVolume|Statistics"
        var vrows: [TableRow] = []
        for (vol, list) in Dictionary(grouping: c.counters(vg), by: \.sub).sorted(by: { $0.key < $1.key }) {
            func r(_ n: String) -> Double? { c.rate(list.first { $0.name == n }) }
            func v(_ n: String) -> Double? { c.num(list.first { $0.name == n }) }
            guard let ur = v("Bytes read by user"), let uw = v("Bytes written by user") else { continue }
            vrows.append(TableRow(id: vol, cells: [vol, bps(r("Bytes read by user") ?? 0), bps(r("Bytes written by user") ?? 0),
                                                   bytes(ur), bytes(v("Bytes read from block device") ?? 0),
                                                   bytes(uw), bytes(v("Bytes written to block device") ?? 0)],
                                  help: "AppleAPFSVolume Statistics: what apps read and wrote, and what went to and from the disk"))
        }
        panels.append(Panel(id: "st.volumes", title: "APFS volumes",
                            help: "Per volume (AppleAPFSVolume Statistics). Apps' reads include those the file cache served, so they can far exceed what the disk read; the disk's writes include metadata and copy-on-write, so they exceed what apps wrote",
                            kind: .table(columns: ["Volume", "Apps read", "Apps wrote", "Apps read since boot", "From disk since boot",
                                                   "Apps wrote since boot", "To disk since boot"], rows: vrows, leading: 1)))
        return panels
    }

    // MARK: Network

    static func network(_ c: DashContext) -> [Panel] {
        let ifs = c.groups.keys.filter { $0.hasPrefix("net|") }.sorted()
        var rows: [TableRow] = []
        var inT = 0.0, outT = 0.0, pk = 0.0
        for gid in ifs {
            let name = String(gid.dropFirst(4))
            // Interfaces that have moved under 1 KB since boot (idle tunnels) are left out.
            guard let bin = c.num(gid, "bytes in"), let bout = c.num(gid, "bytes out"), bin + bout >= 1024 else { continue }
            let ri = c.rate(gid, "bytes in") ?? 0, ro = c.rate(gid, "bytes out") ?? 0
            let pi = c.rate(gid, "packets in") ?? 0, po = c.rate(gid, "packets out") ?? 0
            if name != "lo0" { inT += ri; outT += ro; pk += pi + po }
            let errs = (c.num(gid, "errors in") ?? 0) + (c.num(gid, "errors out") ?? 0) + (c.num(gid, "drops in") ?? 0)
            let speed = c.num(gid, "link speed").map { $0 > 0 ? Compact.bytes($0).replacingOccurrences(of: "K", with: " k") + "bit/s" : "–" } ?? "–"
            rows.append(TableRow(id: gid, cells: [name, c.text(c.first(gid, "state")) ?? "", bps(ri), bps(ro), perSec(pi + po),
                                                  bytes(bin), bytes(bout), count(errs), speed],
                                 help: "Interfaces that have moved at least 1 KB since boot (sysctl net.link.generic.ifdata)"))
        }
        var tiles = [
            Metric(id: "net.in", title: "Received", value: inT, text: bps(inT), help: "Bytes per second in, every interface but loopback", counter: ifs.first.map { $0 + "|bytes in" }),
            Metric(id: "net.out", title: "Sent", value: outT, text: bps(outT), help: "Bytes per second out, every interface but loopback", counter: ifs.first.map { $0 + "|bytes out" }),
            Metric(id: "net.packets", title: "Packets", value: pk, text: perSec(pk), help: "Packets per second in and out, every interface but loopback"),
        ]
        if let n = c.num("sysctl|net.necp", "client_count") {
            tiles.append(Metric(id: "net.necp", title: "Network clients (NECP)", value: n, text: count(n),
                                sub: c.num("sysctl|net.necp", "socket_flow_count").map { "\(count($0)) socket flows" } ?? "",
                                help: "Clients and flows the network policy layer tracks (net.necp.client_count, socket_flow_count)",
                                counter: c.first("sysctl|net.necp", "client_count")?.id))
        }
        if let n = c.num("sysctl|net.local", "pcbcount") {
            tiles.append(Metric(id: "net.unix", title: "Unix domain sockets", value: n, text: count(n), help: "net.local.pcbcount",
                                counter: c.first("sysctl|net.local", "pcbcount")?.id))
        }
        var panels = [Panel(id: "net.tiles", title: "", kind: .tiles(tiles))]
        panels.append(Panel(id: "net.ifs", title: "Interfaces", help: "Each interface that has moved data since boot",
                            kind: .table(columns: ["Interface", "State", "In", "Out", "Packets", "In since boot", "Out since boot", "Errors and drops", "Link"], rows: rows, leading: 2)))

        // TCP, UDP and IP (netstat -s); TCP through the helper.
        func p(_ g: String, _ f: String) -> CounterInfo? { c.first("proto|" + g, f) }
        var tcp: [Metric] = []
        let tcpZero = c.counters("proto|tcp").allSatisfy { (c.num($0) ?? 0) == 0 }
        if !tcpZero, let st = c.rate(p("tcp", "tcps_sndtotal")), let rt = c.rate(p("tcp", "tcps_rcvtotal")) {
            tcp.append(Metric(id: "net.tcp.seg", title: "TCP segments", value: st + rt, text: perSec(st + rt),
                              sub: "out \(perSec(st)) · in \(perSec(rt))", help: "tcps_sndtotal, tcps_rcvtotal", counter: p("tcp", "tcps_sndtotal")?.id))
            if let data = c.rate(p("tcp", "tcps_sndpack")), let rex = c.rate(p("tcp", "tcps_sndrexmitpack")) {
                let since = (c.num(p("tcp", "tcps_sndrexmitpack")) ?? 0) / max(1, c.num(p("tcp", "tcps_sndpack")) ?? 1) * 100
                tcp.append(Metric(id: "net.tcp.rexmit", title: "Retransmitted", value: data > 0 ? rex / data * 100 : 0,
                                  text: data > 0 ? pct(rex / data * 100) : "–", sub: "since boot \(pct(since))",
                                  help: "Data segments sent again ÷ data segments sent (tcps_sndrexmitpack, tcps_sndpack)",
                                  counter: p("tcp", "tcps_sndrexmitpack")?.id, max: 100))
            }
            let opened = (c.rate(p("tcp", "tcps_connattempt")) ?? 0) + (c.rate(p("tcp", "tcps_accepts")) ?? 0)
            tcp.append(Metric(id: "net.tcp.conn", title: "Connections opened", value: opened, text: perSec(opened),
                              sub: "\(count(c.num(p("tcp", "tcps_connects")) ?? 0)) established since boot",
                              help: "Outgoing attempts and accepted connections per second (tcps_connattempt + tcps_accepts); tcps_connects since boot",
                              counter: p("tcp", "tcps_connattempt")?.id))
            if let dup = c.rate(p("tcp", "tcps_rcvduppack")) {
                tcp.append(Metric(id: "net.tcp.dup", title: "Duplicates received", value: dup, text: perSec(dup),
                                  sub: "out of order \(perSec(c.rate(p("tcp", "tcps_rcvoopack")) ?? 0))",
                                  help: "tcps_rcvduppack, tcps_rcvoopack", counter: p("tcp", "tcps_rcvduppack")?.id))
            }
        }
        if let ui = c.rate(p("udp", "udps_ipackets")), let uo = c.rate(p("udp", "udps_opackets")) {
            tcp.append(Metric(id: "net.udp", title: "UDP datagrams", value: ui + uo, text: perSec(ui + uo),
                              sub: "out \(perSec(uo)) · in \(perSec(ui))", help: "udps_opackets, udps_ipackets", counter: p("udp", "udps_ipackets")?.id))
        }
        if let ip = c.rate(p("ip", "ips_total")) {
            tcp.append(Metric(id: "net.ip", title: "IPv4 packets in", value: ip, text: perSec(ip),
                              sub: "sent \(perSec(c.rate(p("ip", "ips_localout")) ?? 0))", help: "ips_total, ips_localout", counter: p("ip", "ips_total")?.id))
        }
        panels.append(Panel(id: "net.proto", title: "Protocols", help: "The network stack's protocol counters (netstat -s)", kind: .tiles(tcp)))
        if tcpZero && !c.counters("proto|tcp").isEmpty {
            panels.append(Panel(id: "net.tcpnote", title: "", kind: .note(
                "TCP's counters read as zeros without root: install the privileged helper (Settings ▸ Helper) to see them.")))
        }
        var problems: [Metric] = []
        for (g, f, title) in [("tcp", "tcps_drops", "TCP connections dropped"), ("tcp", "tcps_rcvbadsum", "TCP bad checksums"),
                              ("tcp", "tcps_listendrop", "TCP listen queue overflows"), ("udp", "udps_noport", "UDP to a port nobody listens on"),
                              ("udp", "udps_fullsock", "UDP dropped, socket buffer full"), ("ip", "ips_badsum", "IPv4 bad checksums"),
                              ("ip", "ips_odropped", "IPv4 dropped on output"), ("ip", "ips_noroute", "IPv4 with no route"),
                              ("mbuf", "m_drops", "Network buffer requests denied"), ("mbuf", "m_wait", "Network buffer requests delayed")] {
            guard let x = p(g, f), let v = c.num(x), !(g == "tcp" && tcpZero) else { continue }
            problems.append(Metric(id: "net.err.\(f)", title: "\(title) (\(f))", text: count(v) + (c.rate(x).map { $0 > 0 ? " · \(perSec($0)) now" : "" } ?? ""),
                                   counter: x.id))
        }
        panels.append(Panel(id: "net.problems", title: "Drops and errors since boot", kind: .facts(problems)))

        // Wi-Fi radio (IOReport "Chip" group, Broadcom-based Wi-Fi).
        let chip = "ioreport|Chip"
        var radio: [Metric] = []
        if let tx = c.rate(chip, "Tx Data Frames") {
            let retry = c.rate(chip, "Tx Retransmissions") ?? 0
            radio.append(Metric(id: "net.wifi.tx", title: "Frames sent", value: tx, text: perSec(tx),
                                sub: tx > 0 ? String(format: "%.1f %% resent", retry / tx * 100) : "",
                                help: "Wi-Fi data frames sent and retransmitted per second (IOReport Chip, Tx Counters)", counter: c.first(chip, "Tx Data Frames")?.id))
        }
        if let rx = c.rate(chip, "Rx Data Frames") {
            let err = c.rate(chip, "Rx Data Errors") ?? 0
            radio.append(Metric(id: "net.wifi.rx", title: "Frames received", value: rx, text: perSec(rx),
                                sub: "\(perSec(err)) with errors",
                                help: "Wi-Fi data frames received and those with errors per second (IOReport Chip, Rx Counters)", counter: c.first(chip, "Rx Data Frames")?.id))
        }
        if let fail = c.num(chip, "MSDU failed due to exceeded transmits") {
            radio.append(Metric(id: "net.wifi.fail", title: "Gave up sending", value: c.rate(chip, "MSDU failed due to exceeded transmits"), text: count(fail) + " since boot",
                                help: "Frames dropped after too many retries (dot11 MIB, MSDU failed due to exceeded transmits)",
                                counter: c.first(chip, "MSDU failed due to exceeded transmits")?.id))
        }
        panels.append(Panel(id: "net.wifi", title: "Wi-Fi radio", kind: .tiles(radio)))
        return panels
    }

    // MARK: GPU

    static func gpu(_ c: DashContext) -> [Panel] {
        var tiles: [Metric] = []
        let perf = c.groups.keys.filter { $0.hasPrefix("ioreg|") && $0.hasSuffix("|PerformanceStatistics") }.sorted()
        for gid in perf {
            if let u = c.num(gid, "Device Utilization %") {
                tiles.append(Metric(id: "gpu.use.\(gid)", title: "GPU use", value: u, text: pct(u),
                                    sub: "renderer \(pct(c.num(gid, "Renderer Utilization %") ?? 0)) · tiler \(pct(c.num(gid, "Tiler Utilization %") ?? 0))",
                                    help: "IOAccelerator PerformanceStatistics: Device, Renderer (fragment) and Tiler (vertex) Utilization %",
                                    counter: c.first(gid, "Device Utilization %")?.id, max: 100))
            }
            if let m = c.num(gid, "In use system memory") {
                tiles.append(Metric(id: "gpu.mem.\(gid)", title: "GPU memory in use", value: m, text: bytes(m),
                                    sub: c.num(gid, "Alloc system memory").map { "\(bytes($0)) allocated" } ?? "",
                                    help: "Unified memory the GPU's allocations hold (In use system memory, Alloc system memory)",
                                    counter: c.first(gid, "In use system memory")?.id, max: c.num(gid, "Alloc system memory")))
            }
        }
        if let ph = c.counters("ioreport|GPU Stats").first(where: { $0.name == "GPUPH" }), let d = c.stateDelta(ph), let x = clock(d, kind: "GPU") {
            tiles.append(Metric(id: "gpu.clock", title: "GPU clock", value: x.mhz ?? 0, text: x.mhz.map(mhz) ?? (x.active < 0.005 ? "idle" : "–"),
                                sub: "active \(pct(x.active * 100))",
                                help: "Time-weighted clock while the GPU was out of its off state (IOReport GPU Performance States, GPUPH, with pmgr's DVFS table)",
                                counter: ph.id, max: ClusterReader.shared.tables["GPU"]?.max()))
        }
        let energy = c.counters("ioreport|PMP").filter { DashContext.subgroup($0) == "Energy Counters" && $0.name == "GPU" }.first
            ?? c.first("ioreport|Energy Model", "GPU Energy")
        if let w = c.watts(energy) {
            tiles.append(Metric(id: "gpu.power", title: "GPU power", value: w, text: watts(w), help: "IOReport PMP Energy Counters: GPU", counter: energy?.id))
        }
        let amc = c.counters("ioreport|AMC Stats").filter { DashContext.subgroup($0) == "Perf Counters" && $0.name.hasPrefix("GFX") && !$0.name.contains("DCS") }
        let rd = amc.filter { $0.name.hasSuffix(" RD") }.compactMap { c.rate($0) }.reduce(0, +)
        let wr = amc.filter { $0.name.hasSuffix(" WR") }.compactMap { c.rate($0) }.reduce(0, +)
        if !amc.isEmpty {
            tiles.append(Metric(id: "gpu.dram", title: "GPU memory traffic", value: rd + wr, text: bps(rd + wr),
                                sub: "read \(bps(rd)) · write \(bps(wr))", help: "IOReport AMC Stats: GFX read and write bytes", counter: amc.first?.id))
        }
        var panels = [Panel(id: "gpu.tiles", title: "", kind: .tiles(tiles))]

        // System-level cache hit rate per GPU client (AMC Stats, DSID Group Stats "<client> Hits"/"Misses").
        let dsid = c.counters("ioreport|AMC Stats").filter { DashContext.subgroup($0) == "DSID Group Stats" }
        var cache: [Metric] = []
        for h in dsid where h.name.hasSuffix(" Hits") {
            let client = String(h.name.dropLast(5))
            guard let m = dsid.first(where: { $0.name == client + " Misses" }) else { continue }
            let (hr, mr) = (c.rate(h) ?? 0, c.rate(m) ?? 0)
            let (hs, ms) = (c.num(h) ?? 0, c.num(m) ?? 0)
            guard hs + ms > 0 else { continue }
            let now = hr + mr > 0 ? hr / (hr + mr) * 100 : nil
            cache.append(Metric(id: "gpu.slc.\(client)", title: client.hasPrefix("k") ? String(client.dropFirst()) : client,
                                value: now ?? hs / (hs + ms) * 100, text: now.map(pct) ?? "idle",
                                sub: "since boot \(pct(hs / (hs + ms) * 100)) · \(perSec(hr + mr)) lookups",
                                help: "System-level cache hits ÷ lookups for this client (IOReport AMC Stats, DSID Group Stats)", counter: h.id, max: 100))
        }
        panels.append(Panel(id: "gpu.slc", title: "System-level cache hit rate by client",
                            help: "Every client of the system-level cache the memory controller counts, the GPU's and others' (display, video, Neural Engine, DART)",
                            kind: .bars(cache)))

        var facts: [Metric] = []
        for n in ["Total Restarts", "Throttle Counter Total", "THM Activation Count"] {
            if let x = c.counters("ioreport|GPU Stats").first(where: { $0.name == n }), let v = c.num(x) {
                facts.append(Metric(id: "gpu.f.\(n)", title: ["Total Restarts": "GPU restarts", "Throttle Counter Total": "Times throttled",
                                                               "THM Activation Count": "Thermal management activations"][n] ?? n,
                                    text: count(v) + " since boot", help: "IOReport GPU Stats: \(n)", counter: x.id))
            }
        }
        panels.append(Panel(id: "gpu.facts", title: "Since boot", kind: .facts(facts)))
        return panels
    }
}
