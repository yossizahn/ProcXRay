import Darwin
import Foundation

/// Per-stage CPU time of the refresh pipeline, for holding it to its budgets (tools/perf.swift measures the whole
/// process). Off unless PROCXRAY_PERF=<file> is set; then every 30 s it appends each stage's calls, CPU time of
/// the thread that ran it (so waiting on the helper or a lock doesn't count) and share of one core to the file.
/// Stages marked main run on the main thread, whose per-tick time is budgeted on its own.
enum PerfStages {
    enum Stage: String, CaseIterable, Sendable {
        case registries = "registries (launchd, LaunchServices)"
        case snapshot = "snapshot (refresh reads)"
        case helperCall = "helper allMetrics: call"
        case helperDecode = "helper allMetrics: decode"
        case treeBuildBackground = "tree build (background)"
        case fillSignatures = "fills: signatures"
        case fillArgv = "fills: command lines"
        case fillDomains = "fills: pid domains"
        case fillJobParents = "fills: job parents"
        case publish = "main: refresh publish"
        case fillMerge = "main: fill merges"
        case treeBuild = "main: tree build (view changed)"
        case tableApply = "main: table apply (incl. build)"
        case ambientSample = "menu bar: sample"
        case ambientPublish = "main: menu bar publish"
    }

    static let path = ProcessInfo.processInfo.environment["PROCXRAY_PERF"]
    static var enabled: Bool { path != nil }

    private struct Total { var calls = 0; var cpu: UInt64 = 0; var maxCPU: UInt64 = 0 }
    nonisolated(unsafe) private static var totals: [Stage: Total] = [:]
    nonisolated(unsafe) private static var since: UInt64 = 0
    private static let lock = NSLock()
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?

    /// Runs `body`, adding the CPU time of this thread it took to `stage`.
    @inline(__always)
    static func measure<T>(_ stage: Stage, _ body: () throws -> T) rethrows -> T {
        guard path != nil else { return try body() }
        let t0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        defer { add(stage, clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- t0) }
        return try body()
    }

    /// For stages that span an await: `let t = PerfStages.begin()` … `PerfStages.end(.stage, t)`, on one thread.
    @inline(__always)
    static func begin() -> UInt64 { path == nil ? 0 : clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
    @inline(__always)
    static func end(_ stage: Stage, _ t0: UInt64) {
        guard path != nil else { return }
        add(stage, clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- t0)
    }

    private static func add(_ stage: Stage, _ cpu: UInt64) {
        lock.lock()
        if timer == nil { start() }
        var t = totals[stage] ?? Total()
        t.calls += 1; t.cpu &+= cpu; t.maxCPU = max(t.maxCPU, cpu)
        totals[stage] = t
        lock.unlock()
    }

    private static func start() {
        since = DispatchTime.now().uptimeNanoseconds
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(1))
        t.setEventHandler { write() }
        t.resume()
        timer = t
    }

    private static func write() {
        guard let path else { return }
        lock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        let secs = Double(now &- since) / 1e9
        let snap = totals
        totals = [:]
        since = now
        lock.unlock()
        var text = String(format: "%@  %.0f s\n", ISO8601DateFormatter().string(from: Date()), secs)
        for s in Stage.allCases {
            guard let t = snap[s] else { continue }
            text += "  " + s.rawValue.padding(toLength: 34, withPad: " ", startingAt: 0)
                + String(format: "%5d calls  %7.2f ms avg  %7.2f ms max  %5.2f %% of a core\n",
                         t.calls, Double(t.cpu) / Double(t.calls) / 1e6, Double(t.maxCPU) / 1e6, Double(t.cpu) / 1e9 / secs * 100)
        }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
        }
    }
}
