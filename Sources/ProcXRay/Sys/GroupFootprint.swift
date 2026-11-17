import Foundation
import SwiftUI

/// A group's memory with shared pages counted once, measured on request and shown in a bubble, never stored.
///
/// A process's footprint (`ri_phys_footprint`) includes anonymous memory it shares with other processes: the
/// kernel charges such a page to every process that maps it, so a group's footprints added up count it once per
/// member. Which shared pages are charged to which process is per-page pmap state, readable only through a task
/// port, which with SIP on not even root gets; Apple's `footprint` has the entitlement for it. Measured on macOS
/// 27.2: run on a set of pids, `footprint`'s "Summary Footprint" counts each shared page once. Region info
/// (`PROC_PIDREGIONINFO`, no task port) can't stand in: Firefox's shared anonymous objects came to 162 MB against
/// a real overlap of 14 MB.
///
/// The plain sum is within 1 % (measured: 0.2–0.4 % over for an app's group, 1 % over all processes), so groups
/// show it, and the bubble runs `footprint` on exactly one group's members (through the helper when it runs, so
/// other users' processes are included): 0.06–0.3 s for an app, ~8 s for 600 processes. Measuring every shown group
/// in the background kept `footprint` busy ~23 % of a core.
enum GroupFootprint {
    /// SF Symbol of the button that opens the bubble.
    static let symbol = "shoeprints.fill"
    static let help = "Memory with pages these processes share counted once (measures with footprint)"

    /// One measurement of a group.
    struct Result: Sendable {
        /// The members' footprints, as the process list shows them, with pages they share counted once.
        var total: Double
        /// What adding up their footprints counts more than once.
        var shared: Double
        /// Processes `footprint` analyzed, and asked about.
        var analyzed: Int
        var asked: Int
        var seconds: Double
    }

    /// Runs `footprint` on the processes. `shared` is its per-process figures added up less its summary; the total
    /// is the kernel's `ri_phys_footprint` (what the rows show) less that. `footprint`'s own per-process figure
    /// can be a few MB lower than the kernel's (measured: 20 of 574 processes, ~2.8 MB each, even alone), which
    /// isn't sharing: taking its summary as the total would put a group below its rows with nothing shared.
    static func measure(_ pids: [Int32], helper: Bool) -> Result? {
        let t0 = Date()
        guard let run = run(pids, helper: helper) else { return nil }
        let own = run.footprints.values.reduce(0.0) { $0 + Double($1) }
        let shared = max(0, own - run.total)
        let kernel = run.footprints.reduce(0.0) { sum, e in sum + Double(Native.rusage(e.key)?.ri_phys_footprint ?? e.value) }
        return Result(total: max(0, kernel - shared), shared: shared, analyzed: run.footprints.count, asked: Set(pids).count,
                      seconds: Date().timeIntervalSince(t0))
    }

    // MARK: Running footprint

    struct Run: Equatable, Sendable {
        /// Each analyzed process's footprint, bytes.
        var footprints: [Int32: UInt64]
        /// The total with shared memory counted once, bytes.
        var total: Double
    }

    static let tool = "/usr/bin/footprint"
    static func argv(_ pids: [Int32]) -> [String] { ["-f", "bytes", "--noCategories"] + pids.flatMap { ["-p", "\($0)"] } }
    /// Seconds before `footprint` is stopped: ~8 s measured for 600 processes.
    static let timeout: Double = 60
    /// The most processes one run takes (the helper refuses more).
    static let maxPids = 8192

    /// `footprint` on these processes, through the helper or in this process. nil when it couldn't run.
    static func run(_ pids: [Int32], helper: Bool) -> Run? {
        let text: String?
        if helper {
            text = HelperClient.shared.groupFootprint(pids)
        } else {
            let r = Shell.exec(tool, argv(pids), mergeStderr: false, timeout: timeout)
            text = r.timedOut || r.status == -1 ? nil : r.output
        }
        return text.flatMap(parse)
    }

    /// Reads `footprint -f bytes --noCategories` output: a "name [pid]: 64-bit    Footprint: N B" line per process,
    /// then "Summary Footprint: N B" when there was more than one. nil when no process was analyzed.
    static func parse(_ text: String) -> Run? {
        var fps: [Int32: UInt64] = [:]
        var summary: UInt64?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("Summary Footprint:") {
                summary = number(after: "Summary Footprint:", in: line)
                continue
            }
            // The name can hold brackets: take the last "[pid]:" before "Footprint:".
            guard let f = line.range(of: "Footprint:"), let close = line[..<f.lowerBound].range(of: "]:", options: .backwards),
                  let open = line[..<close.lowerBound].range(of: "[", options: .backwards),
                  let pid = Int32(line[open.upperBound..<close.lowerBound]),
                  let v = number(after: "Footprint:", in: line) else { continue }
            fps[pid] = v
        }
        guard !fps.isEmpty else { return nil }
        if fps.count == 1 { return Run(footprints: fps, total: Double(fps.first!.value)) }
        guard let summary else { return nil }
        return Run(footprints: fps, total: Double(summary))
    }

    private static func number(after key: String, in line: Substring) -> UInt64? {
        guard let r = line.range(of: key) else { return nil }
        let digits = line[r.upperBound...].drop { $0 == " " }.prefix { $0.isNumber }
        return UInt64(digits)
    }
}

/// The bubble: measures the group when it opens and shows the total with shared pages counted once, and how much
/// is shared. Nothing is kept: open it again to measure again.
struct GroupFootprintBubble: View {
    let pids: [Int32]
    /// What the process list shows: the footprints added up.
    let listed: Double?
    let helper: Bool
    @State private var result: GroupFootprint.Result??

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Shared memory counted once", systemImage: GroupFootprint.symbol)
                .font(.headline)
            switch result {
            case nil:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Measuring \(pids.count) processes with footprint…").foregroundStyle(.secondary)
                }
            case .some(nil):
                Text("footprint couldn't measure these processes.").foregroundStyle(.secondary)
            case .some(let r?):
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Total")
                        Text(Fmt.bytes(UInt64(r.total))).monospacedDigit().fontWeight(.semibold).gridColumnAlignment(.trailing)
                    }
                    GridRow {
                        Text("Shared between them")
                        Text(Fmt.bytes(UInt64(r.shared))).monospacedDigit().gridColumnAlignment(.trailing)
                    }
                }
                Text(caption(r)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .task {
            let pids = pids, helper = helper
            let r = await Task.detached(priority: .userInitiated) { GroupFootprint.measure(pids, helper: helper) }.value
            result = .some(r)
        }
    }

    private func caption(_ r: GroupFootprint.Result) -> String {
        var s = "Measured now with footprint in \(String(format: "%.1f", r.seconds)) s."
        if let listed { s += " The list adds up footprints (\(Fmt.bytes(UInt64(listed)))), counting shared pages once per process." }
        if r.analyzed < r.asked {
            s += " footprint couldn't read \(r.asked - r.analyzed) of the \(r.asked) processes" + (helper ? "" : " (the helper reads other users' processes)") + ": they're left out."
        }
        return s
    }
}
