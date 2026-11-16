import AppKit
import SwiftUI

// The process table's columns, as one table of descriptors (docs/tree-and-inspector-proposal.md, Part 2).
// A column is a title, a tooltip, a value for a process and a rule for group rows; the outline, sorting,
// the menus and the group-row pass all read this table, so a new column is one entry here.

/// What one cell shows, and how it sorts.
enum CellValue: Equatable, Sendable {
    case empty
    /// Couldn't be read ("—"); sorts with `empty`, after every real value.
    case unknown
    case text(String, Tint = .normal)
    case number(Double, String, Tint = .normal)
    case date(Date, String)

    enum Tint: Sendable { case normal, secondary, warning, danger }

    var display: String {
        switch self {
        case .empty: ""
        case .unknown: "—"
        case .text(let s, _), .number(_, let s, _), .date(_, let s): s
        }
    }

    var tint: Tint {
        switch self {
        case .unknown: .secondary
        case .text(_, let t), .number(_, _, let t): t
        default: .normal
        }
    }

    var number: Double? { if case .number(let v, _, _) = self { v } else { nil } }
    /// The same value in the secondary tint.
    var dimmed: CellValue {
        switch self {
        case .text(let s, _): .text(s, .secondary)
        case .number(let v, let s, _): .number(v, s, .secondary)
        default: self
        }
    }
    var date: Date? { if case .date(let d, _) = self { d } else { nil } }
    var hasValue: Bool { self != .empty && self != .unknown }

    /// Ascending order between two values. Empty and unknown values are not ordered here: the caller
    /// keeps them last whichever way the column is sorted.
    static func compare(_ a: CellValue, _ b: CellValue) -> ComparisonResult {
        switch (a, b) {
        case (.number(let x, _, _), .number(let y, _, _)): x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
        case (.date(let x, _), .date(let y, _)): x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
        default: a.display.localizedStandardCompare(b.display)
        }
    }
}

/// The table's sort: one column, either way.
struct ColumnSort: Hashable, Sendable {
    var id: String
    var ascending: Bool
    static let pid = ColumnSort(id: "pid", ascending: true)
}

struct Column: Identifiable {
    enum Section: Int, CaseIterable {
        // The one list of sections (docs/ui-regrouping-plan.md, Part 1): menus, the column manager,
        // the filter's field list and the inspector's cards all follow it.
        case identity, execution, lineage, cpu, gpu, memory, disk, network, ipc, energy, security
        var title: String {
            switch self {
            case .identity: "Identity"
            case .execution: "Execution"
            case .lineage: "Lineage"
            case .cpu: "CPU"
            case .gpu: "GPU"
            case .memory: "Memory"
            case .disk: "Disk"
            case .network: "Network"
            case .ipc: "IPC"
            case .energy: "Energy"
            case .security: "Security"
            }
        }
    }

    /// What a group row shows in this column.
    enum GroupRule {
        /// The total of its processes (values that really add up).
        case sum
        /// The members' values: the one value (dimmed when some members have none), two or three
        /// comma-separated with the most common first, or the most common and "+N".
        case same
        /// The value when every member that has one agrees (dimmed when some have none), else nothing:
        /// a count of distinct ids would say nothing.
        case uniform
        /// "min–max" of a number, or the single value.
        case range
        /// Nothing: a total would mislead (shared pages, peaks at different times).
        case blank
        /// The earliest date; on a category row the newest (the oldest member of a category is always
        /// something started at boot).
        case oldest
        /// Worked out from the processes some other way.
        case custom(@MainActor ([ProcInfo], Store) -> CellValue)
    }

    let id: String
    let title: String
    let tooltip: String
    let section: Section
    /// The system's own name for a cryptic quantity, when the title is a plain phrase ("resource coalition"
    /// for "Accounting group"). Leads the tooltip; menus and the column manager show "Title (term)".
    var term: String? = nil
    var minWidth: CGFloat = 50
    var width: CGFloat = 80
    var numeric = false
    var truncateMiddle = false
    let rule: GroupRule
    /// Formats a group row's sum.
    var format: (Double) -> String = { String(Int($0)) }
    /// The value as a plain number, for columns that add up: sums and sorting use it without
    /// formatting a string per process.
    var amount: (@MainActor (ProcInfo) -> Double?)? = nil
    /// Reads the snapshot makes only while this column is shown.
    var reads: ExtraReads = []
    let value: @MainActor (ProcInfo, Store) -> CellValue

    /// A column of numbers that add up: the value is `amount`, formatted.
    static func amount(id: String, title: String, tooltip: String, section: Section, term: String? = nil, minWidth: CGFloat = 50,
                       width: CGFloat = 76, rule: GroupRule = .sum, reads: ExtraReads = [],
                       format: @escaping (Double) -> String,
                       _ amount: @escaping @MainActor (ProcInfo) -> Double?) -> Column {
        Column(id: id, title: title, tooltip: tooltip, section: section, term: term, minWidth: minWidth, width: width, numeric: true,
               rule: rule, format: format, amount: amount, reads: reads) { p, _ in amount(p).map { .number($0, format($0)) } ?? .unknown }
    }

    /// The extra reads the given columns need.
    static func reads(for shown: Set<String>) -> ExtraReads {
        all.reduce(into: ExtraReads()) { if shown.contains($1.id) { $0.formUnion($1.reads) } }
    }

    /// What the row sorts by: the plain number when there is one.
    @MainActor
    func sortValue(_ p: ProcInfo, _ store: Store) -> CellValue {
        if let amount { return amount(p).map { .number($0, "") } ?? .unknown }
        return value(p, store)
    }

    // MARK: Group rows

    /// A group row's value. `value` gives a member's value (Store.sorted passes a memo, since one process
    /// is a member of every group row above it).
    @MainActor
    func groupValue(_ n: ProcNode, members: [ProcInfo], store: Store, value: (ProcInfo) -> CellValue) -> CellValue {
        switch rule {
        case .blank: return .empty
        case .sum:
            var total = 0.0, any = false
            for m in members {
                if let v = amount.map({ $0(m) }) ?? value(m).number { total += v; any = true }
            }
            guard any else { return members.isEmpty ? .empty : .unknown }
            return .number(total, format(total))
        case .same, .uniform:
            var seen: [String: (value: CellValue, count: Int)] = [:]
            var missing = false
            for m in members {
                let v = value(m)
                if v.hasValue { seen[v.display, default: (v, 0)].count += 1 } else { missing = true }
            }
            guard !seen.isEmpty else { return .empty }
            if seen.count == 1 {
                let v = seen.values.first!.value
                return missing ? v.dimmed : v
            }
            guard case .same = rule else { return .empty }
            let common = seen.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
            let s = common.count <= 3 ? common.map(\.key).joined(separator: ", ") : "\(common[0].key) +\(common.count - 1)"
            return .text(s, .secondary)
        case .range:
            var lo = Double.infinity, hi = -Double.infinity
            var shown: (lo: String, hi: String) = ("", "")
            for m in members {
                guard let v = value(m).number, v.isFinite else { continue }
                if v < lo { lo = v; shown.lo = value(m).display }
                if v > hi { hi = v; shown.hi = value(m).display }
            }
            guard lo <= hi else { return members.isEmpty ? .empty : .unknown }
            return lo == hi ? .number(lo, shown.lo) : .number(lo, "\(shown.lo)–\(shown.hi)", .secondary)
        case .oldest:
            let newest = n.kind == .category
            var best: CellValue = .empty
            for m in members {
                let v = value(m)
                if let d = v.date, best.date.map({ newest ? d > $0 : d < $0 }) ?? true { best = v }
            }
            return best
        case .custom(let f):
            return f(members, store)
        }
    }

    /// "Accounting group (resource coalition)": the title with its system term, where there is room.
    var fullTitle: String { term.map { "\(title) (\($0))" } ?? title }

    // MARK: Lookup

    static let all: [Column] = catalogue
    static let byID: [String: Column] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    static let name = byID["name"]!
    /// What a new install shows: the 13 columns the table had before the catalogue, less the coalition ids.
    static let defaultShown: [String] = ["name", "pid", "cpu", "mem", "threads", "user", "responsible", "signer", "disk", "started", "context"]

    /// Width of the header as it looks when sorted: a bold title plus the sort arrow, so sorting by
    /// the column doesn't truncate its title.
    static func sortedHeaderWidth(_ col: NSTableColumn) -> CGFloat {
        let font = NSFont.boldSystemFont(ofSize: col.headerCell.font?.pointSize ?? NSFont.smallSystemFontSize)
        return ceil((col.title as NSString).size(withAttributes: [.font: font]).width) + 30
    }
}

// MARK: - Catalogue

private func num(_ v: Double?, _ f: (Double) -> String) -> CellValue { v.map { .number($0, f($0)) } ?? .unknown }
private func text(_ s: String?) -> CellValue { s.map { .text($0) } ?? .empty }
private let bytesFormat: (Double) -> String = { Fmt.bytes(UInt64(max(0, $0))) }
private let countFormat: (Double) -> String = { Fmt.count(Int64($0)) }
private let machNote = " From lsmp, run as root by the helper (admins only) about every 30 s while a Mach ports column is shown; — for a process started since. Group rows: the sum."
private let secsFormat: (Double) -> String = { Fmt.secs(UInt64(max(0, $0))) }
/// Events per second: one decimal below 10, whole numbers above.
let perSecFormat: (Double) -> String = { $0 == 0 ? "0" : $0 < 10 ? String(format: "%.1f/s", $0) : "\(Fmt.count(Int64($0.rounded())))/s" }
let bytesPerSecFormat: (Double) -> String = { $0 < 1 ? "0" : Fmt.bytes(UInt64($0)) + "/s" }
let wattsFormat: (Double) -> String = { $0 == 0 ? "0" : $0 < 0.01 ? "<0.01 W" : String(format: "%.2f W", $0) }
/// Large counts in SI units with three significant digits: 950, 12.3 k, 4.56 G.
let siFormat: (Double) -> String = { v in
    let units = ["", " k", " M", " G", " T", " P"]
    var x = v, i = 0
    while x.magnitude >= 999.5, i < units.count - 1 { x /= 1000; i += 1 }
    if i == 0 { return String(format: "%.0f", x) }
    return String(format: x.magnitude < 9.995 ? "%.2f" : x.magnitude < 99.95 ? "%.1f" : "%.0f", x) + units[i]
}
private let rateNote = " Over the last refresh; — for a process's first refresh."

/// "all", "none" or "n of m" over the processes whose answer is known.
@MainActor private func share(_ members: [ProcInfo], _ test: (ProcInfo) -> Bool?) -> CellValue {
    let known = members.compactMap(test)
    guard !known.isEmpty else { return .empty }
    let yes = known.filter { $0 }.count
    let s = yes == known.count ? "all" : yes == 0 ? "none" : "\(yes) of \(known.count)"
    return .number(Double(yes) / Double(known.count), s, .secondary)
}

private func yesNo(_ b: Bool?) -> CellValue {
    guard let b else { return .unknown }
    return .number(b ? 1 : 0, b ? "yes" : "no")
}

/// Hardened runtime, from the code directory's flags (CS_RUNTIME). nil for Apple platform binaries,
/// which don't set it but are protected as platform code anyway, and for unsigned code.
@MainActor private func hardened(_ p: ProcInfo, _ s: Store) -> Bool? {
    guard let sign = s.signInfo(for: p), !sign.unsigned, !sign.isPlatform else { return nil }
    return sign.staticFlags & 0x0001_0000 != 0
}

/// Stopped, zombie or starting, from the kernel's process state (`p_stat`); empty for a normal live
/// process. There is no running/sleeping: `p_stat` says runnable for nearly every process (143 of 143 app
/// processes measured), and the running-thread count is a single instant that reads 0 for most processes.
private func state(_ p: ProcInfo) -> CellValue {
    if p.notResponding { return .text("not responding", .danger) }
    switch p.stat {
    case 4: return .text("stopped", .warning)
    case 5: return .text("zombie", .warning)
    case 1: return .text("starting", .secondary)
    default: return .empty
    }
}

private let catalogue: [Column] = [
    // Identity
    Column(id: "name", title: "Name",
           tooltip: "Process name, or the title of a group row. Badges: LEFT (outlived its app), ZOMBIE, ROSETTA, SBX (sandboxed), EXITED.",
           section: .identity, minWidth: 180, width: 280, rule: .blank) { p, _ in .text(p.name) },
    Column(id: "pid", title: "PID", tooltip: "Process ID. App rows: the app's own process.",
           section: .identity, minWidth: 44, width: 56, numeric: true, rule: .blank) { p, _ in .number(Double(p.pid), String(p.pid)) },
    Column(id: "kind", title: "Kind",
           tooltip: "Where the Smart tree puts it: category, then the role inside its app (\"App · XPC service\", \"Extension · Widgets\").",
           section: .identity, width: 150, rule: .same) { p, s in text(s.kind(of: p)) },
    Column(id: "path", title: "Path", tooltip: "Executable path. App rows: the app's.",
           section: .identity, width: 260, truncateMiddle: true, rule: .blank) { p, _ in text(p.path) },
    Column(id: "bundleID", title: "Bundle ID",
           tooltip: "Bundle identifier of the app or extension bundle that holds the executable. App rows: the app's.",
           section: .identity, width: 180, rule: .blank) { p, s in text(s.bundleID(of: p)) },
    Column(id: "commandLine", title: "Command line",
           tooltip: "The arguments the process was started with (argv), read once per process. Other users' processes need the helper; \"—\" means they couldn't be read. App rows: the app's.",
           section: .identity, minWidth: 120, width: 360, rule: .blank) { p, _ in
        if let c = p.commandLine { return .text(c) }
        return p.commandLineRead ? .unknown : .empty
    },
    Column(id: "arch", title: "Architecture", tooltip: "Native, or x86_64 translated by Rosetta.",
           section: .identity, width: 90, rule: .same) { p, _ in
        #if arch(arm64)
        p.isTranslated ? .text("x86_64 (Rosetta)", .warning) : .text("arm64")
        #else
        .text("x86_64")
        #endif
    },

    // Execution
    Column(id: "user", title: "User", tooltip: "User the process runs as.",
           section: .execution, width: 70, rule: .same) { p, _ in .text(p.user) },
    Column(id: "state", title: "State",
           tooltip: "Not responding (WindowServer reports the app hung, as in Activity Monitor), stopped (by a signal such as SIGSTOP), zombie (exited, waiting for its parent) or starting, from the kernel's process state. Empty for a normal live process. Group rows: how many are stopped, zombie or starting.",
           section: .execution, width: 76,
           rule: .custom { ms, _ in
               var counts: [String: Int] = [:]
               for m in ms { let v = state(m); if v.hasValue { counts[v.display, default: 0] += 1 } }
               guard !counts.isEmpty else { return .empty }
               let parts = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { "\($0.value) \($0.key)" }
               return .number(Double(counts.values.reduce(0, +)), parts.joined(separator: ", "), .warning)
           }) { p, _ in state(p) },
    Column(id: "started", title: "Started", tooltip: "Time since the process started. Group rows: the oldest; category rows: the newest.",
           section: .execution, minWidth: 50, width: 70, numeric: false, rule: .oldest) { p, _ in .date(p.start, Fmt.age(p.start)) },
    Column(id: "startTime", title: "Start time", tooltip: "When the process started. Group rows: the oldest; category rows: the newest.",
           section: .execution, width: 120, rule: .oldest) { p, _ in .date(p.start, Fmt.date.string(from: Fmt.shownStart(p.start))) },
    Column(id: "tty", title: "TTY", tooltip: "Controlling terminal.",
           section: .execution, width: 70, rule: .same) { p, _ in text(p.tty.map(SmartTree.ttyName)) },
    Column(id: "pgid", title: "Process group", tooltip: "Process group id: a shell job, such as a pipeline, shares one.",
           section: .execution, width: 90, numeric: true, rule: .uniform) { p, _ in
        .number(Double(p.pgid), String(p.pgid))
    },
    Column(id: "idleExit", title: "Idle exit",
           tooltip: "Dirty tracking (proc_get_dirty): \"can exit\" when launchd or the app lets the system stop it while idle; \"busy\" (dirty) while it has work and is kept. Empty: not tracked.",
           section: .execution, term: "dirty tracking", width: 100, rule: .same, reads: .idleExit) { p, _ in
        guard let s = p.idleExit else { return .unknown }
        return .text(s.short, s.contains(.dirty) || !s.contains(.allowsIdleExit) ? .secondary : .normal)
    },

    // Lineage
    Column(id: "parent", title: "Parent", tooltip: "Parent process (ppid). App rows: the app's parent.",
           section: .lineage, width: 130, rule: .blank) { p, s in
        guard p.ppid != p.pid else { return .empty }
        // A "parent" started after its child is a later process that reused the pid.
        guard let par = s.procs[p.ppid], par.start <= p.start else { return .text("gone (\(p.ppid))", .secondary) }
        return .text("\(par.name) (\(p.ppid))")
    },
    Column(id: "responsible", title: "Responsible",
           tooltip: "The process macOS holds responsible for this one (for privacy prompts and energy). † marks one that has exited.",
           section: .lineage, minWidth: 80, width: 130, rule: .blank) { p, s in
        if let t = p.leftBehindText { return .text("† \(t)", .warning) }
        guard let r = p.responsible else { return .empty }
        if r == p.pid { return .text("self", .secondary) }
        if let rp = s.procs[r] { return .text("\(rp.name) (\(r))") }
        return .text("† gone (\(r))", .warning)
    },
    Column(id: "label", title: "launchd label", tooltip: "Label of the launchd job this process is the main process of.",
           section: .lineage, width: 200, rule: .blank) { p, _ in text(p.launchdLabel) },
    Column(id: "domain", title: "Domain", tooltip: "launchd domain of that job: system, gui or user.",
           section: .lineage, width: 64, rule: .same) { p, _ in text(p.launchdDomain) },
    Column(id: "lsType", title: "LaunchServices type",
           tooltip: "The app's type as LaunchServices registers it (lsappinfo): Foreground (has a Dock icon), UIElement (no Dock icon) or BackgroundOnly (no UI). Empty: not registered with LaunchServices. The Smart tree's categories are derived from it.",
           section: .lineage, width: 110, rule: .same) { p, _ in text(p.lsType) },
    Column(id: "lsState", title: "LaunchServices state",
           tooltip: "LaunchServices' state tags for the app, verbatim as lsappinfo prints them (such as !signalled).",
           section: .lineage, width: 140, rule: .blank) { p, _ in
        p.lsTags.isEmpty ? .empty : .text(p.lsTags.joined(separator: " "))
    },
    Column(id: "extPoint", title: "Extension point", tooltip: "For an app extension: what it extends.",
           section: .lineage, width: 130, rule: .same) { p, _ in
        text(p.extensionPoint.map(ExtensionInfo.title))
    },
    Column(id: "containedIn", title: "Contained in", tooltip: "For an app extension: the app whose bundle holds it.",
           section: .lineage, width: 120, rule: .same) { p, _ in text(p.containingAppName) },
    Column(id: "coalition", title: "Accounting group",
           tooltip: "Resource coalition id: processes macOS accounts for together, usually an app and its helpers.",
           section: .lineage, term: "resource coalition", width: 100, numeric: true, rule: .uniform) { p, _ in
        p.coalition.map { .number(Double($0), String($0)) } ?? .empty
    },
    Column(id: "jetsam", title: "Memory-kill group",
           tooltip: "Jetsam coalition id: processes macOS frees memory from together, such as a host app and its extensions.",
           section: .lineage, term: "jetsam coalition", width: 100, numeric: true, rule: .uniform) { p, _ in
        p.jetsamCoalition.map { .number(Double($0), String($0)) } ?? .empty
    },
    Column(id: "leftBehind", title: "Left behind",
           tooltip: "The app that has exited but left this process running; macOS keeps the app 'running in background' while it lives. Empty otherwise.",
           section: .lineage, width: 110, rule: .same) { p, _ in
        p.leftBehindText.map { .text($0, .warning) } ?? .empty
    },
    Column(id: "context", title: "Context",
           tooltip: "launchd label, LaunchServices name, extension point, terminal, or the path. Group rows: process counts.",
           section: .lineage, minWidth: 120, width: 300, rule: .blank) { _, _ in .empty },   // drawn by the cell

    // CPU
    .amount(id: "cpu", title: "CPU %",
            tooltip: "CPU use over the last refresh, as a percentage of one core (can pass 100). Group rows: the sum.",
            section: .cpu, minWidth: 44, width: 52, format: { Fmt.pct($0) }) { $0.cpuPercent },
    .amount(id: "cpuTime", title: "CPU time", tooltip: "User plus system CPU time since the process started. Group rows: the sum.",
            section: .cpu, width: 80, format: secsFormat) { $0.cpuNanos.map { Double($0) } },
    .amount(id: "threads", title: "Threads", tooltip: "Number of threads. Group rows: the sum.",
            section: .cpu, minWidth: 44, width: 56, format: countFormat) { $0.threads.map { Double($0) } },
    .amount(id: "waiting", title: "Runnable wait",
            tooltip: "Runnable but waiting: time the process's threads were ready to run but no core was free, as a percentage of one core." + rateNote,
            section: .cpu, width: 70, rule: .blank, format: { String(format: "%.1f", $0) }) { $0.rates?.waitingPercent },
    .amount(id: "cswRate", title: "Context switches/s", tooltip: "Context switches per second. Group rows: the sum." + rateNote,
            section: .cpu, width: 90, format: perSecFormat) { $0.rates?.contextSwitches },
    Column(id: "priority", title: "Priority",
           tooltip: "Scheduling priority of the process's main thread (proc_taskinfo; 31 is the default, higher runs first).",
           section: .cpu, width: 56, numeric: true, rule: .range) { p, _ in
        p.priority.map { .number(Double($0), String($0)) } ?? .unknown
    },
    Column(id: "nice", title: "Nice",
           tooltip: "Nice value (proc_bsdinfo): 0 is normal, positive yields the CPU to others. Other users' processes need the helper.",
           section: .cpu, width: 48, numeric: true, rule: .range, reads: .nice) { p, _ in
        p.nice.map { .number(Double($0), String($0), $0 > 0 ? .secondary : $0 < 0 ? .warning : .normal) } ?? .unknown
    },
    Column(id: "pcore", title: "P-core share",
           tooltip: "Share of the process's CPU time spent on performance cores. Group rows: weighted by CPU time.",
           section: .cpu, width: 70, numeric: true,
           rule: .custom { ms, _ in
               var pc: UInt64 = 0, all: UInt64 = 0
               for m in ms { if let p = m.counters?.pCoreNanos, let c = m.cpuNanos { pc &+= p; all &+= c } }
               guard all > 0 else { return .empty }
               let v = Double(pc) / Double(all) * 100
               return .number(v, String(format: "%.0f %%", v))
           }) { p, _ in
        guard let pc = p.counters?.pCoreNanos, let c = p.cpuNanos, c > 0 else { return .unknown }
        let v = Double(pc) / Double(c) * 100
        return .number(v, String(format: "%.0f %%", v))
    },
    Column(id: "ipc", title: "Instr/cycle", tooltip: "Instructions retired per CPU cycle, since the process started. Group rows: all instructions over all cycles.",
           section: .cpu, width: 70, numeric: true,
           rule: .custom { ms, _ in
               var i: UInt64 = 0, c: UInt64 = 0
               for m in ms { if let mi = m.counters?.instructions, let mc = m.counters?.cycles { i &+= mi; c &+= mc } }
               guard c > 0 else { return .empty }
               let v = Double(i) / Double(c)
               return .number(v, String(format: "%.2f", v))
           }) { p, _ in
        guard let i = p.counters?.instructions, let c = p.counters?.cycles, c > 0 else { return .unknown }
        let v = Double(i) / Double(c)
        return .number(v, String(format: "%.2f", v))
    },
    .amount(id: "cycles", title: "Cycles", tooltip: "CPU cycles the process has used since it started (rusage ri_cycles). Group rows: the sum.",
            section: .cpu, width: 70, format: siFormat) { $0.counters?.cycles.map { Double($0) } },
    .amount(id: "cycleRate", title: "Cycles/s",
            tooltip: "CPU cycles per second: like CPU %, but weighted by clock speed. Group rows: the sum." + rateNote,
            section: .cpu, width: 70, format: { siFormat($0) + "/s" }) { $0.rates?.cycles },
    .amount(id: "instructions", title: "Instructions",
            tooltip: "Instructions the process has retired since it started (rusage ri_instructions). Group rows: the sum.",
            section: .cpu, width: 76, format: siFormat) { $0.counters?.instructions.map { Double($0) } },
    .amount(id: "instructionRate", title: "Instructions/s",
            tooltip: "Instructions retired per second. Group rows: the sum." + rateNote,
            section: .cpu, width: 76, format: { siFormat($0) + "/s" }) { $0.rates?.instructions },

    // GPU
    .amount(id: "gpu", title: "% GPU",
            tooltip: "GPU time over the last refresh, as a percentage of the interval (IORegistry accelerator clients). Group rows: the sum." + rateNote,
            section: .gpu, width: 56, reads: .gpu, format: { $0 < 0.05 ? "0" : String(format: "%.1f", $0) }) { $0.rates?.gpuPercent },
    .amount(id: "gpuTime", title: "GPU time",
            tooltip: "GPU time since the process started (IORegistry accelerator clients); 0 for a process that never used the GPU. Group rows: the sum.",
            section: .gpu, width: 76, reads: .gpu, format: secsFormat) { $0.gpuNanos.map { Double($0) } },

    // Memory
    .amount(id: "mem", title: "Memory",
            tooltip: "Physical footprint: the memory macOS charges to the process, as in Activity Monitor. Group rows: the sum.",
            section: .memory, minWidth: 60, width: 76, format: bytesFormat) { $0.footprint.map { Double($0) } },
    .amount(id: "peakMem", title: "Peak memory", tooltip: "Highest footprint since the process started.",
            section: .memory, width: 80, rule: .blank, format: bytesFormat) { $0.counters?.peakFootprint.map { Double($0) } },
    .amount(id: "resident", title: "Resident",
            tooltip: "Resident size. Shared pages count once per process, so group rows show nothing.",
            section: .memory, width: 76, rule: .blank, format: bytesFormat) { $0.rss.map { Double($0) } },
    .amount(id: "virtual", title: "Virtual", tooltip: "Virtual address space size.",
            section: .memory, width: 80, rule: .blank, format: bytesFormat) { $0.virt.map { Double($0) } },
    .amount(id: "compressed", title: "Compressed",
            tooltip: "Memory the system has compressed for this process (TASK_VM_INFO). Your own processes; other users' need the helper. Group rows: the sum.",
            section: .memory, width: 80, reads: .compressed, format: bytesFormat) { $0.compressed.map { Double($0) } },
    .amount(id: "neural", title: "Neural Engine", tooltip: "Memory charged to the process for the Neural Engine. Group rows: the sum.",
            section: .memory, width: 76, format: bytesFormat) { $0.counters?.neuralFootprint.map { Double($0) } },
    Column(id: "jetsamBand", title: "Memory-kill band",
           tooltip: "Jetsam band: where the kernel's memory killer (jetsam) puts the process: when memory runs short, lower bands are killed first; 0 is the idle band. Read as root, so it needs the helper.",
           section: .memory, term: "jetsam", width: 64, numeric: true, rule: .range, reads: .jetsam) { p, _ in
        p.jetsam.map { .number(Double($0.band), String($0.band), $0.band == 0 ? .secondary : .normal) } ?? .unknown
    },
    Column(id: "memLimit", title: "Memory limit",
           tooltip: "The footprint at which the kernel kills the process (jetsam), in force now. Some processes have a different limit while inactive (see the Usage tab). Needs the helper.",
           section: .memory, width: 80, numeric: true, rule: .blank, reads: .jetsam) { p, _ in
        guard let j = p.jetsam else { return .unknown }
        guard let b = j.limitBytes else { return .number(.infinity, "none", .secondary) }
        return .number(Double(b), Fmt.bytes(b))
    },
    Column(id: "memLimitUsed", title: "Limit used",
           tooltip: "Footprint as a share of the memory limit: at 100 % the kernel kills the process. Needs the helper.",
           section: .memory, width: 64, numeric: true, rule: .blank, reads: .jetsam) { p, _ in
        guard let j = p.jetsam else { return .unknown }
        guard let b = j.limitBytes, b > 0, let f = p.footprint else { return .empty }
        let v = Double(f) / Double(b) * 100
        return .number(v, String(format: "%.0f %%", v), v >= 90 ? .danger : v >= 75 ? .warning : .normal)
    },
    .amount(id: "faultRate", title: "Page faults/s", tooltip: "Page faults per second. Group rows: the sum." + rateNote,
            section: .memory, width: 80, format: perSecFormat) { $0.rates?.faults },
    .amount(id: "pageinRate", title: "Page-ins/s", tooltip: "Pages read in from disk per second. Group rows: the sum." + rateNote,
            section: .memory, width: 70, format: perSecFormat) { $0.rates?.pageins },

    // Disk
    .amount(id: "readRate", title: "Read/s", tooltip: "Bytes read from disk per second. Group rows: the sum." + rateNote,
            section: .disk, width: 80, format: bytesPerSecFormat) { $0.rates?.diskRead },
    .amount(id: "writeRate", title: "Written/s", tooltip: "Bytes written to disk per second. Group rows: the sum." + rateNote,
            section: .disk, width: 80, format: bytesPerSecFormat) { $0.rates?.diskWrite },
    .amount(id: "diskRead", title: "Disk read", tooltip: "Bytes read from disk since the process started. Group rows: the sum.",
            section: .disk, width: 76, format: bytesFormat) { $0.diskRead.map { Double($0) } },
    .amount(id: "diskWritten", title: "Disk written", tooltip: "Bytes written to disk since the process started. Group rows: the sum.",
            section: .disk, width: 76, format: bytesFormat) { $0.diskWrite.map { Double($0) } },
    .amount(id: "disk", title: "Disk I/O",
            tooltip: "Bytes read plus written since the process started. — when neither could be read. Group rows: the sum.",
            section: .disk, minWidth: 56, width: 70, format: bytesFormat) { p in
        let d = ProcNode.disk(p)
        return d < 0 ? nil : Double(d)
    },
    .amount(id: "logicalWrites", title: "Logical writes",
            tooltip: "Bytes the process asked to write, before caching and compression. Group rows: the sum.",
            section: .disk, width: 80, format: bytesFormat) { $0.counters?.logicalWrites.map { Double($0) } },

    // Network
    .amount(id: "netIn", title: "Received/s",
            tooltip: "Network bytes received per second over the last 2 s, from the kernel's per-socket counts (the ones nettop shows), read every 2 s since the app started. Includes connections that closed in that time, and loopback traffic. Group rows: the sum.",
            section: .network, width: 80, reads: .network, format: bytesPerSecFormat) { $0.netIn },
    .amount(id: "netOut", title: "Sent/s",
            tooltip: "Network bytes sent per second over the last 2 s, from the kernel's per-socket counts (the ones nettop shows), read every 2 s since the app started. Includes connections that closed in that time, and loopback traffic. Group rows: the sum.",
            section: .network, width: 80, reads: .network, format: bytesPerSecFormat) { $0.netOut },

    // IPC
    .amount(id: "syscallRate", title: "System calls/s", tooltip: "BSD plus Mach system calls per second. Group rows: the sum." + rateNote,
            section: .ipc, width: 90, format: perSecFormat) { $0.rates?.syscalls },
    .amount(id: "machMsgRate", title: "Mach messages/s", tooltip: "Mach messages sent plus received per second. Group rows: the sum." + rateNote,
            section: .ipc, width: 90, format: perSecFormat) { $0.rates?.machMsgs },
    .amount(id: "machPorts", title: "Ports",
            tooltip: "Mach port names in the process's port space: send, receive and send-once rights, port sets and dead names (lsmp's total; Activity Monitor's Ports)." + machNote,
            section: .ipc, width: 62, reads: .machPorts, format: countFormat) { $0.machPorts.map { Double($0.total) } },
    .amount(id: "machDeadNames", title: "Dead names",
            tooltip: "Rights the process still holds to ports whose receiver has died. Thousands that keep growing are a leak: the process never deallocates them." + machNote,
            section: .ipc, width: 70, reads: .machPorts, format: countFormat) { $0.machPorts.map { Double($0.deadNames) } },
    .amount(id: "machRepliesOwed", title: "Replies owed",
            tooltip: "Send-once rights: the ones the process holds: mostly replies it owes to processes that sent it a request. Thousands that keep growing are requests it never answers." + machNote,
            section: .ipc, term: "send-once", width: 76, reads: .machPorts, format: countFormat) { $0.machPorts.map { Double($0.sendOnce) } },
    .amount(id: "machFullQueues", title: "Full queues",
            tooltip: "Ports the process receives on whose message queue is full (messages waiting ≥ queue limit): senders block or time out until it receives." + machNote,
            section: .ipc, width: 70, reads: .machPorts, format: countFormat) { $0.machPorts.map { Double($0.fullQueues) } },
    .amount(id: "openFiles", title: "Open files",
            tooltip: "Open file descriptors: files, sockets, pipes (PROC_PIDLISTFDS). Other users' processes need the helper. Group rows: the sum.",
            section: .ipc, width: 66, reads: .openFiles, format: countFormat) { $0.openFiles.map { Double($0) } },

    // Energy
    .amount(id: "power", title: "Power",
            tooltip: "Energy the process's threads used on the CPU, per second, in watts (rusage ri_energy_nj). Group rows: the sum." + rateNote,
            section: .energy, width: 70, format: wattsFormat) { $0.rates?.watts },
    .amount(id: "energy", title: "Energy", tooltip: "Energy the process's threads used on the CPU since it started, in joules (rusage ri_energy_nj). Group rows: the sum.",
            section: .energy, width: 80, format: { String(format: "%.1f J", $0) }) { $0.energyNJ.map { Double($0) / 1e9 } },
    .amount(id: "wakeupRate", title: "Wakeups/s",
            tooltip: "Wakeups per second: package idle plus interrupt wakeups (rusage ri_pkg_idle_wkups + ri_interrupt_wkups). Group rows: the sum." + rateNote,
            section: .energy, width: 80, format: perSecFormat) { $0.rates?.wakeups },
    Column(id: "preventingSleep", title: "Preventing sleep",
           tooltip: "Power assertions that keep the Mac (system) or the display awake (IOPMCopyAssertionsByProcess). Group rows: how many processes hold one.",
           section: .energy, width: 90, rule: .custom { ms, _ in
               let n = ms.filter { ExtraRead.preventing($0.assertions ?? []) != nil }.count
               return n == 0 ? .empty : .number(Double(n), "\(n) process\(n == 1 ? "" : "es")", .warning)
           }, reads: .assertions) { p, _ in
        guard let a = p.assertions else { return .unknown }
        return ExtraRead.preventing(a).map { .text($0, .warning) } ?? .empty
    },

    // Security
    Column(id: "signer", title: "Signer", tooltip: "Who signed the running code: Apple, a Developer ID team, ad hoc, or unsigned.",
           section: .security, minWidth: 70, width: 110, rule: .same) { p, _ in
        guard let s = p.signer else { return .empty }
        return .text(s, s == "unsigned" ? .danger : .normal)
    },
    Column(id: "team", title: "Team ID", tooltip: "Developer team of the signature.",
           section: .security, width: 90, rule: .same) { p, s in text(s.signInfo(for: p)?.teamID) },
    Column(id: "signingID", title: "Signing ID", tooltip: "Identifier in the code signature. App rows: the app's.",
           section: .security, width: 180, rule: .blank) { p, _ in text(p.signID) },
    Column(id: "sandboxed", title: "Sandboxed", tooltip: "Whether the App Sandbox confines it. Group rows: all, none, or how many.",
           section: .security, width: 76, rule: .custom { ms, _ in share(ms) { $0.sandboxed } }) { p, _ in yesNo(p.sandboxed) },
    Column(id: "hardened", title: "Hardened runtime",
           tooltip: "Whether the signature enables the hardened runtime. \"platform\": Apple platform code, protected without it. Group rows: all, none, or how many, not counting platform code.",
           section: .security, width: 76, rule: .custom { ms, s in share(ms) { hardened($0, s) } }) { p, s in
        if p.signer == nil { return .empty }
        if s.signInfo(for: p)?.isPlatform == true { return .text("platform", .secondary) }
        return yesNo(hardened(p, s))
    },
]

// MARK: - Store lookups for columns

extension Store {
    /// "App · XPC service", "Extension · Widgets": the Smart tree's category of the process's unit, then its role.
    func kind(of p: ProcInfo) -> String? {
        if kindCache?.gen != dataGen {
            let k = SmartTree.kinds(.init(procs: procs, lsApps: lsApps, btmOwners: btmOwners))
            kindCache = (dataGen, k.kinds, k.roots)
        }
        return kindCache?.map[p.pid]
    }

    func bundleID(of p: ProcInfo) -> String? {
        if let id = lsApps.first(where: { $0.pid == p.pid })?.bundleID { return id }
        guard let path = p.path, let b = ExtensionInfo.bundle(ofExecutable: path) ?? p.bundlePath else { return nil }
        return BundleInfo.identifier(b)
    }
}

/// CFBundleIdentifier per bundle path, read once.
@MainActor
enum BundleInfo {
    private static var cache: [String: String?] = [:]
    static var versions: [String: String?] = [:]
    static func identifier(_ bundle: String) -> String? {
        if let hit = cache[bundle] { return hit }
        let plist = NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist") ?? NSDictionary(contentsOfFile: bundle + "/Info.plist")
        let id = plist?["CFBundleIdentifier"] as? String
        cache[bundle] = .some(id)
        return id
    }
}

// MARK: - Shown columns

/// Which process table columns are shown: one app-wide list, so the header menu, View ▸ Columns and
/// every window agree. Order and widths stay in AppKit's column autosave. A list of shown columns (not
/// hidden ones) so a column added in a later version starts hidden.
enum ColumnPrefs {
    static let key = "shownColumns"
    static let defaultShown = Column.defaultShown.joined(separator: ",")
    static let sizeAllToFit = Notification.Name("ProcXRay.sizeAllColumnsToFit")
    static let reset = Notification.Name("ProcXRay.resetColumns")

    static func parse(_ raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map(String.init)).union(["name"])
    }
    static var shown: Set<String> { parse(UserDefaults.standard.string(forKey: key) ?? defaultShown) }
    static func setShown(_ ids: Set<String>) {
        UserDefaults.standard.set(Column.all.map(\.id).filter(ids.contains).joined(separator: ","), forKey: key)
    }
    static func toggle(_ id: String) { set(id, shown: !shown.contains(id)) }
    static func set(_ id: String, shown on: Bool) {
        guard id != "name" else { return }
        var s = shown
        if on { s.insert(id) } else { s.remove(id) }
        setShown(s)
    }

    // MARK: Order and layouts

    /// Every column id in the table's current left-to-right order, hidden ones included. The table writes
    /// it whenever a column moves; the column manager reads it. (AppKit's autosave holds the same order,
    /// but in a private format.)
    static let orderKey = "columnOrder"
    /// Posted after `apply(_:)`: every process table takes the stored shown set and order at once.
    static let layoutChanged = Notification.Name("ProcXRay.columnLayoutChanged")

    static var order: [String] {
        let saved = (UserDefaults.standard.string(forKey: orderKey) ?? "").split(separator: ",").map(String.init)
            .filter { Column.byID[$0] != nil }
        // Columns the saved order doesn't know (new in this version) go after it, in catalogue order.
        let base = saved.isEmpty ? Column.defaultShown : saved
        return base + Column.all.map(\.id).filter { !base.contains($0) }
    }
    static func setOrder(_ ids: [String]) {
        UserDefaults.standard.set(ids.joined(separator: ","), forKey: orderKey)
    }
    /// The shown columns, left to right.
    static var shownInOrder: [String] {
        let s = shown
        return order.filter(s.contains)
    }

    /// Shows exactly `ids`, in that order (Name always among them); the hidden columns keep their
    /// relative order after them.
    static func apply(_ ids: [String]) {
        var ids = ids.filter { Column.byID[$0] != nil }
        if !ids.contains("name") { ids.insert("name", at: 0) }
        setOrder(ids + order.filter { !ids.contains($0) })
        setShown(Set(ids))
        NotificationCenter.default.post(name: layoutChanged, object: nil)
    }

    // MARK: Saved sets

    /// A named list of shown columns, in order.
    struct Layout: Codable, Hashable, Identifiable {
        var name: String
        var columns: [String]
        var id: String { name }
    }
    static let setsKey = "columnSets"
    static let defaultLayout = Layout(name: "Default", columns: Column.defaultShown)

    static func decodeSets(_ raw: String) -> [Layout] {
        (try? JSONDecoder().decode([Layout].self, from: Data(raw.utf8))) ?? []
    }
    static var sets: [Layout] { decodeSets(UserDefaults.standard.string(forKey: setsKey) ?? "") }
    static func setSets(_ sets: [Layout]) {
        let data = (try? JSONEncoder().encode(sets)) ?? Data("[]".utf8)
        UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: setsKey)
    }
    /// Saves the shown columns under `name`, replacing a set of that name.
    static func saveSet(named name: String) {
        var all = sets.filter { $0.name != name }
        all.append(Layout(name: name, columns: shownInOrder))
        setSets(all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }
    static func deleteSet(named name: String) { setSets(sets.filter { $0.name != name }) }

    /// The previous version stored hidden columns; carry that choice over once.
    static func migrate() {
        let d = UserDefaults.standard
        guard d.string(forKey: key) == nil, let old = d.string(forKey: "hiddenColumns") else { return }
        let hidden = Set(old.split(separator: ",").map(String.init))
        let before = ["name", "pid", "cpu", "mem", "threads", "user", "responsible", "coalition", "jetsam", "signer", "disk", "started", "context"]
        setShown(Set(before.filter { !hidden.contains($0) }))
        d.removeObject(forKey: "hiddenColumns")
    }
}

/// View ▸ Columns: the header menu's toggles, by section, reachable from the keyboard.
struct ColumnsCommands: Commands {
    @AppStorage(ColumnPrefs.key) private var shownRaw = ColumnPrefs.defaultShown
    @AppStorage(ColumnPrefs.setsKey) private var setsRaw = ""
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let _ = ColumnManager.openWindow = openWindow
        CommandGroup(after: .toolbar) {
            Menu("Columns") {
                Button("Manage Columns…") { ColumnManager.open() }
                    .keyboardShortcut("k", modifiers: [.command, .option])
                Menu("Column Sets") {
                    ForEach([ColumnPrefs.defaultLayout] + ColumnPrefs.decodeSets(setsRaw)) { s in
                        Button(s.name) { ColumnPrefs.apply(s.columns) }
                    }
                }
                Divider()
                let shown = ColumnPrefs.parse(shownRaw)
                ForEach(Column.Section.allCases, id: \.self) { section in
                    Menu(section.title) {
                        ForEach(Column.all.filter { $0.section == section && $0.id != "name" }) { c in
                            // Set, don't flip: a repeated or stale call must not undo the choice.
                            Toggle(c.fullTitle, isOn: Binding(get: { shown.contains(c.id) },
                                                          set: { ColumnPrefs.set(c.id, shown: $0) }))
                        }
                    }
                }
                Divider()
                Button("Size All Columns to Fit") { NotificationCenter.default.post(name: ColumnPrefs.sizeAllToFit, object: nil) }
                Button("Reset Columns") { NotificationCenter.default.post(name: ColumnPrefs.reset, object: nil) }
            }
        }
    }
}
