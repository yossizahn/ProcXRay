import Foundation
import Observation

/// Rows pinned to the top of the main window's process list and the menu bar list. A pinned row sorts above
/// its siblings whatever the sort, pinned rows in the order they were pinned, so they hold their place as the
/// rest reorder. A group holding a pinned row floats with it, so the row stays at the top of a nested list too.
///
/// Keys: `p<pid>@<start µs>` a process; `u<pid>@<start µs>` a group by its lead process: an app's row in the
/// Smart tree, an accounting group in the menu bar list (so pinning an app in one pins it in the other);
/// `r<id>` any other group row of the main window (its ProcNode id). Kept in the defaults; process and group
/// pins go when their process exits.
@MainActor
@Observable
final class Pins {
    static let shared = Pins()
    private static let defaultsKey = "pins"

    /// Pinned keys, oldest first.
    private(set) var keys: [String]
    /// Bumped on every change, for caches keyed on it.
    @ObservationIgnored private(set) var version = 0
    @ObservationIgnored private var rankOf: [String: Int] = [:]

    private init() {
        keys = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        reindex()
        prune()
    }

    var isEmpty: Bool { keys.isEmpty }
    /// Where a pinned key sorts among pinned rows (lower first); nil when it isn't pinned.
    func rank(_ key: String?) -> Int? { key.flatMap { rankOf[$0] } }
    func isPinned(_ key: String?) -> Bool { rank(key) != nil }
    /// The pins as a value, for building a tree off the main thread (TreeBuilder).
    var ranks: PinRanks { PinRanks(version: version, rankOf: rankOf) }

    func toggle(_ key: String) {
        if rankOf[key] != nil { set(keys.filter { $0 != key }) } else { set(keys + [key]) }
    }

    /// Drops pins whose process (or group's lead process) has exited.
    func prune() {
        guard !keys.isEmpty else { return }
        let kept = keys.filter { k in k.first == "p" || k.first == "u" ? Self.alive(k) : true }
        if kept != keys { set(kept) }
    }

    private func set(_ new: [String]) {
        keys = new
        reindex()
        version &+= 1
        UserDefaults.standard.set(new, forKey: Self.defaultsKey)
    }

    private func reindex() {
        rankOf = Dictionary(keys.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Keys

    nonisolated private static func micros(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1e6).rounded()) }
    nonisolated static func process(pid: pid_t, start: Date) -> String { "p\(pid)@\(micros(start))" }
    nonisolated static func process(_ p: ProcInfo) -> String { process(pid: p.pid, start: p.start) }
    static func process(_ p: AmbientProc) -> String { process(pid: p.pid, start: p.start) }
    static func group(leader p: AmbientProc) -> String { "u\(p.pid)@\(micros(p.start))" }

    /// A main-window row's key: a process row's process, an app row's main process, else the row's id.
    nonisolated static func row(_ n: ProcNode, procs: [pid_t: ProcInfo]) -> String {
        if let p = n.proc { return process(p) }
        if n.kind == .unit, let r = n.rootPid.flatMap({ procs[$0] }) { return "u\(r.pid)@\(micros(r.start))" }
        return "r\(n.id)"
    }

    /// The process a `p` or `u` key names is still the one running under its pid.
    private static func alive(_ k: String) -> Bool {
        let parts = k.dropFirst().split(separator: "@")
        guard parts.count == 2, let pid = pid_t(parts[0]), let us = Int64(parts[1]),
              let start = Native.process(pid)?.start else { return false }
        return micros(start) == us
    }
}
