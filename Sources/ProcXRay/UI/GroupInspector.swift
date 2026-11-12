import AppKit
import SwiftUI

/// The inspector for a group row (an app with its helpers, a category, a role group, a coalition…):
/// what the whole group costs, now and since start, and which processes are in it.
///
/// Only values that really add up are summed: CPU, footprint, disk, energy, wakeups, system calls and
/// messages. Resident and virtual size count shared pages once per process, and peaks happened at
/// different times, so the group page leaves them out. Ratios (P-core share, instructions per cycle)
/// are worked out from the summed parts, not averaged.
struct GroupInspectorView: View {
    @Environment(Store.self) var store
    let node: ProcNode

    private var members: [ProcInfo] {
        var out: [ProcInfo] = []
        func walk(_ n: ProcNode) { if let p = n.proc { out.append(p) }; n.children?.forEach(walk) }
        walk(node)
        return out
    }

    var body: some View {
        let ms = members
        let readable = ms.filter(\.isInspectable)
        let root = node.rootPid.flatMap { store.procs[$0] }
        VStack(spacing: 0) {
            header(ms, root: root)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if readable.count < ms.count {
                        Label("Sums cover \(readable.count) of \(ms.count) processes: the other \(ms.count - readable.count) belong to other users"
                              + (store.helperState.isRunning ? " and couldn't be read." : ". The privileged helper can read them."),
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    tiles(ms)
                    sections(ms)
                    processes(ms)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Header

    private func header(_ ms: [ProcInfo], root: ProcInfo?) -> some View {
        let count = node.shownCount == node.totalCount ? "\(node.totalCount) processes"
                                                       : "\(node.shownCount) of \(node.totalCount) processes (search)"
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Group {
                    if let root, let img = IconCache.icon(for: root) { Image(nsImage: img) }
                    else { Image(systemName: node.category?.symbol ?? "square.stack.3d.up").foregroundStyle(.secondary) }
                }
                .frame(width: 16, height: 16)
                Text(node.title).font(.headline).lineLimit(1)
                Text(count).foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: 0)
            }
            .frame(height: 22)
            HStack(spacing: 5) {
                if let root {
                    Text("Main process").foregroundStyle(.secondary)
                    ProcessChip(proc: root)
                    Text("· select it in the list to inspect it alone").foregroundStyle(.tertiary)
                } else {
                    Text(kindLine).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .font(.callout).lineLimit(1)
            .frame(height: 20)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
    }

    private var kindLine: String {
        switch node.kind {
        case .category: "Category: everything placed here and below"
        case .ghost: "Processes whose app has exited"
        default: "Group: every process under this row"
        }
    }

    // MARK: Sums

    /// Sum of `f` over the processes that have it, or nil when none do.
    private func sum(_ ms: [ProcInfo], _ f: (ProcInfo) -> Double?) -> Double? {
        var total = 0.0, any = false
        for m in ms { if let v = f(m) { total += v; any = true } }
        return any ? total : nil
    }

    /// Per refresh, the sum over the processes that have a value then, newest at the end. Histories are
    /// aligned on the newest refresh; a process that started later simply has fewer entries.
    private func summedHistory(_ ms: [ProcInfo], _ pick: (History) -> [Double?]) -> [Double?] {
        let series = ms.compactMap { store.history[$0.key].map(pick) }
        let n = series.map(\.count).max() ?? 0
        guard n > 0 else { return [] }
        var out = [Double?](repeating: nil, count: n)
        for s in series {
            for (i, v) in s.enumerated() {
                guard let v else { continue }
                let j = n - s.count + i
                out[j] = (out[j] ?? 0) + v
            }
        }
        return out
    }

    private func tiles(_ ms: [ProcInfo]) -> some View {
        let cpu = sum(ms) { $0.rates?.cpuPercent }
        let mem = sum(ms) { $0.footprint.map { Double($0) } }
        let disk = sum(ms) { p in p.rates.flatMap { r in r.diskRead.flatMap { a in r.diskWrite.map { a + $0 } } } }
        let watts = sum(ms) { $0.rates?.watts }
        return HStack(spacing: 8) {
            SparkTile(title: "CPU", value: cpu.map { "\(Fmt.pct($0)) %" } ?? "—",
                      values: summedHistory(ms, \.cpu), format: { "\(Fmt.pct($0)) %" })
            SparkTile(title: "Memory", value: mem.map { Fmt.bytes(UInt64($0)) } ?? "—",
                      values: summedHistory(ms, \.memory), fromZero: false, format: { Fmt.bytes(UInt64($0)) })
            SparkTile(title: "Disk read + written", value: disk.map(bytesPerSecFormat) ?? "—",
                      values: summedHistory(ms, \.disk), format: bytesPerSecFormat)
            SparkTile(title: "Power", value: watts.map(wattsFormat) ?? "—",
                      values: summedHistory(ms, \.power), format: wattsFormat)
            Spacer(minLength: 0)
        }
    }

    private func sections(_ ms: [ProcInfo]) -> some View {
        func rate(_ f: (Rates) -> Double?) -> String { sum(ms) { $0.rates.flatMap(f) }.map(perSecFormat) ?? "—" }
        func count(_ f: (Counters) -> UInt32?) -> String { sum(ms) { $0.counters.flatMap(f).map { Double($0) } }.map { Fmt.count(Int64($0)) } ?? "—" }
        func bytes(_ v: Double?) -> String { v.map { Fmt.bytes(UInt64($0)) } ?? "—" }
        let cpu = sum(ms) { $0.rates?.cpuPercent }
        let cpuNanos = sum(ms) { $0.cpuNanos.map { Double($0) } }
        let pCoreNanos = sum(ms) { p in p.counters?.pCoreNanos.flatMap { pc in p.cpuNanos.map { _ in Double(pc) } } }
        // P-core share now: each process's share weighted by its CPU over the same interval.
        let pCoreNow = sum(ms) { p in p.rates.flatMap { r in r.pCoreShare.flatMap { s in r.cpuPercent.map { s * $0 } } } }
        let pCoreCPU = sum(ms) { p in p.rates.flatMap { r in r.pCoreShare.flatMap { _ in r.cpuPercent } } }
        let instrNow = sum(ms) { $0.rates?.instructions }, cyclesNow = sum(ms) { $0.rates?.cycles }
        let instr = sum(ms) { $0.counters?.instructions.map { Double($0) } }, cycles = sum(ms) { $0.counters?.cycles.map { Double($0) } }
        return VStack(alignment: .leading, spacing: 12) {
        UsageTab.section("CPU", "cpu", summedHistory(ms, \.cpu), format: { "\(Fmt.pct($0)) %" }, rows: [
            ("CPU", cpu.map { "\(Fmt.pct($0)) %" } ?? "—", cpuNanos.map { Fmt.secs(UInt64($0)) } ?? "—"),
            ("On performance cores",
             pCoreNow.flatMap { n in pCoreCPU.flatMap { $0 > 0 ? String(format: "%.0f %%", n / $0) : nil } } ?? "—",
             pCoreNanos.map { pc in Fmt.secs(UInt64(pc)) + (cpuNanos.flatMap { $0 > 0 ? String(format: " (%.0f %%)", pc / $0 * 100) : nil } ?? "") } ?? "—"),
            ("Waiting for a CPU", sum(ms) { $0.rates?.waitingPercent }.map { String(format: "%.1f %%", $0) } ?? "—",
             sum(ms) { $0.counters?.waitingNanos.map { Double($0) } }.map { Fmt.secs(UInt64($0)) } ?? "—"),
            ("Threads", sum(ms) { $0.threads.map { Double($0) } }.map { Fmt.count(Int64($0)) } ?? "—", ""),
            ("Instructions per cycle", instrNow.flatMap { i in cyclesNow.flatMap { $0 > 0 ? String(format: "%.2f", i / $0) : nil } } ?? "—",
             instr.flatMap { i in cycles.flatMap { $0 > 0 ? String(format: "%.2f", i / $0) : nil } } ?? "—"),
            ("Context switches", rate(\.contextSwitches), count(\.contextSwitches)),
        ])
        UsageTab.section("Memory", "memorychip", summedHistory(ms, \.memory), fromZero: false, format: { Fmt.bytes(UInt64($0)) }, rows: [
            ("Footprint", bytes(sum(ms) { $0.footprint.map { Double($0) } }), ""),
            ("Neural Engine", bytes(sum(ms) { $0.counters?.neuralFootprint.map { Double($0) } }), ""),
            ("Page faults", rate(\.faults), count(\.faults)),
            ("Page-ins", rate(\.pageins), count(\.pageins)),
        ])
        UsageTab.section("Disk", "internaldrive", summedHistory(ms, \.disk), format: bytesPerSecFormat, rows: [
            ("Read", sum(ms) { $0.rates?.diskRead }.map(bytesPerSecFormat) ?? "—", bytes(sum(ms) { $0.diskRead.map { Double($0) } })),
            ("Written", sum(ms) { $0.rates?.diskWrite }.map(bytesPerSecFormat) ?? "—", bytes(sum(ms) { $0.diskWrite.map { Double($0) } })),
            ("Logical writes", sum(ms) { $0.rates?.logicalWrites }.map(bytesPerSecFormat) ?? "—",
             bytes(sum(ms) { $0.counters?.logicalWrites.map { Double($0) } })),
        ])
        UsageTab.section("Energy and wakeups", "bolt", summedHistory(ms, \.power), format: wattsFormat, rows: [
            ("CPU energy", sum(ms) { $0.rates?.watts }.map(wattsFormat) ?? "—",
             sum(ms) { $0.energyNJ.map { Double($0) } }.map { String(format: "%.2f J", $0 / 1e9) } ?? "—"),
            ("Billed energy", "", sum(ms) { $0.counters?.billedEnergyNJ.map { Double($0) } }.map { String(format: "%.2f J", $0 / 1e9) } ?? "—"),
            ("Wakeups (idle + interrupt)", rate(\.wakeups),
             sum(ms) { $0.wakeups.map { Double($0) } }.map { Fmt.count(Int64($0)) } ?? "—"),
        ])
        UsageTab.section("System calls and IPC", "arrow.left.arrow.right", nil, format: { _ in "" }, rows: [
            ("BSD system calls", rate(\.unixSyscalls), count(\.unixSyscalls)),
            ("Mach system calls", rate(\.machSyscalls), count(\.machSyscalls)),
            ("Mach messages sent", rate(\.machMsgsSent), count(\.machMsgsSent)),
            ("Mach messages received", rate(\.machMsgsReceived), count(\.machMsgsReceived)),
        ])
        Text("Resident and virtual size aren't summed: shared pages would be counted once per process.")
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Members

    private func processes(_ ms: [ProcInfo]) -> some View {
        Card(title: "Processes", systemImage: "list.bullet", trailing: "\(ms.count)") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 24) {
                    top("Top by CPU", ms.sorted { ($0.cpuPercent ?? 0) > ($1.cpuPercent ?? 0) }) { "\(Fmt.pct($0.cpuPercent)) %" }
                    top("Top by memory", ms.sorted { ($0.footprint ?? 0) > ($1.footprint ?? 0) }) { Fmt.bytes($0.footprint) }
                    top("Top by power", ms.sorted { ($0.rates?.watts ?? 0) > ($1.rates?.watts ?? 0) }) { $0.rates?.watts.map(wattsFormat) ?? "—" }
                }
                Collapsible(title: "All \(ms.count)", startsOpen: ms.count <= 12) {
                    ChipFlow(procs: ms.sorted { $0.pid < $1.pid })
                }
            }
        }
    }

    private func top(_ title: String, _ ps: [ProcInfo], _ value: @escaping (ProcInfo) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                ForEach(ps.prefix(5), id: \.key) { p in
                    GridRow {
                        ProcessChip(proc: p)
                        Text(verbatim: value(p)).monospacedDigit().gridColumnAlignment(.trailing)
                    }
                }
            }
        }
    }
}
