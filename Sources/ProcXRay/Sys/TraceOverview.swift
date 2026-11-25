import Foundation

/// A trace at a glance, over every view of it: how many calls of each kind over time, and one line of counts.
/// Only what the calls themselves say: nothing here guesses what the process did between them.
struct TraceOverview: Sendable, Equatable {
    /// Columns across the graph, whatever the trace's length.
    static let bins = 240
    /// The kinds the graph draws, bottom to top. Waits are left out: they'd bury the rest.
    static let drawn: [TraceKind] = [.files, .network, .messages, .other]

    /// The stretch the graph covers, in ns since the trace started.
    var lo: UInt64 = 0
    var hi: UInt64 = 0
    /// Calls started in each column, by `drawn` kind.
    var bars: [[Int]] = []
    /// CPUs' worth of the process's threads on a CPU in each column (1: one core busy throughout), from the
    /// trace's context switches; empty when that wasn't measured.
    var cpu: [Double] = []
    /// Calls of each kind (by TraceKind.rawValue) in the scope's threads, errors and stretch, whichever kinds it shows.
    var counts = [Int](repeating: 0, count: TraceKind.allCases.count)
    /// "5.0 s · 19 threads · on CPU 312.40 ms · 790 lookups · …"
    var sentence = ""

    var isEmpty: Bool { hi <= lo }

    /// `groups`: the scope's activities, unfiltered by text. `fromStart`: no early calls were let go, so the
    /// graph starts where the trace did.
    static func build(_ records: [SyscallRecord], scope: TraceScope, context: SyscallActivity.Context,
                      groups: [SyscallActivity], fromStart: Bool, cpu: TraceCPU = TraceCPU()) -> Self {
        var o = Self()
        guard !records.isEmpty else { return o }
        var first = UInt64.max
        for i in records.indices {
            first = min(first, records[i].time)
            o.hi = max(o.hi, records[i].end ?? records[i].time)
        }
        o.lo = fromStart ? 0 : first
        guard o.hi > o.lo else { return o }
        let span = Double(o.hi - o.lo)
        func bin(_ t: UInt64) -> Int { min(bins - 1, Int(Double(max(t, o.lo) - o.lo) / span * Double(bins))) }

        o.bars = [[Int]](repeating: [Int](repeating: 0, count: bins), count: drawn.count)
        var threads = Set<UInt64>()
        let some = TraceScope(errorsOnly: scope.errorsOnly, threads: scope.threads)
        for i in records.indices where some.admits(records[i], context) {
            let kind = SyscallActivity.kind(records[i], context)
            if let k = drawn.firstIndex(of: kind) { o.bars[k][bin(records[i].time)] += 1 }
            guard scope.range?.contains(records[i].time) ?? true else { continue }
            o.counts[kind.rawValue] += 1
            if scope.kinds.isEmpty || scope.kinds.contains(kind) { threads.insert(records[i].thread) }
        }

        let shown = scope.range ?? o.lo...o.hi
        if cpu.measured {
            o.cpu = [Double](repeating: 0, count: bins)
            let width = span / Double(bins)
            cpu.each(in: max(o.lo, cpu.from)...o.hi, threads: scope.threads) { a, b in
                for k in bin(a)...bin(b) {
                    let left = Double(o.lo) + Double(k) * width
                    let covered = min(Double(b), left + width) - max(Double(a), left)
                    if covered > 0 { o.cpu[k] += covered / width }
                }
            }
        }
        o.sentence = sentence(groups, length: shown.upperBound - shown.lowerBound, selected: scope.range != nil,
                              threads: threads.count, cpu: cpu.time(in: shown, threads: scope.threads))
        return o
    }

    private static func sentence(_ groups: [SyscallActivity], length: UInt64, selected: Bool, threads: Int, cpu: UInt64?) -> String {
        func size(_ n: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file) }
        func count(_ n: Int, _ one: String, _ many: String) -> String { n.formatted() + " " + (n == 1 ? one : many) }
        var parts = [SyscallActivity.interval(length) + (selected ? " selected" : "")]
        parts.append(count(threads, "thread", "threads"))
        if let cpu { parts.append("on CPU " + SyscallTraceView.duration(cpu)) }

        var lookups = 0, read: UInt64 = 0, written: UInt64 = 0
        var connections = 0, sent: UInt64 = 0, received: UInt64 = 0
        var messages = 0, destinations = Set<String>(), kernelCalls = 0, launches = 0, failures = 0
        for g in groups where g.operation != .waits {
            failures += g.failures
            switch g.operation {
            case .lookup: lookups += g.calls.count
            case .read, .write, .readWrite: read += g.bytesIn; written += g.bytesOut
            case .connection, .connect, .accept, .listen, .send, .receive:
                connections += 1; sent += g.bytesOut; received += g.bytesIn
            case .message: messages += g.calls.count; destinations.insert(g.target)
            case .kernelCall: kernelCalls += g.calls.count
            case .api:
                // Its messages and kernel calls, counted as their own rows would be.
                for r in g.calls where r.name == "mach_msg2_trap" {
                    if r.kernelRoutine != nil { kernelCalls += 1 } else if let a = r.args, a.count > 1, a[1] & UInt64(MACH_SEND_MSG) != 0 { messages += 1 }
                }
                for t in g.reached where !t.hasSuffix(" (kernel)") { destinations.insert(t) }
            case .launch: launches += g.calls.count
            default: break
            }
        }
        if lookups > 0 {
            parts.append(count(lookups, "lookup", "lookups"))
        }
        let io = (read > 0 ? ["read " + size(read)] : []) + (written > 0 ? ["wrote " + size(written)] : [])
        if !io.isEmpty { parts.append("files: " + io.joined(separator: ", ")) }
        if connections > 0 {
            parts.append(([count(connections, "connection", "connections")] + (sent > 0 ? ["sent " + size(sent)] : [])
                          + (received > 0 ? ["received " + size(received)] : [])).joined(separator: ", "))
        }
        if messages > 0 {
            parts.append(count(messages, "message", "messages") + " to " + count(destinations.count, "destination", "destinations"))
        }
        if kernelCalls > 0 { parts.append(count(kernelCalls, "kernel call", "kernel calls")) }
        if launches > 0 { parts.append(count(launches, "launch", "launches")) }
        if failures > 0 { parts.append(count(failures, "call failed", "calls failed")) }
        return parts.joined(separator: " · ")
    }
}
