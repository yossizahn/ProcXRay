import Foundation

/// The five figures summed over a set of processes. A figure is nil when no member has a reading for it.
struct AmbientSums: Hashable, Sendable {
    var cpu: Double?, gpu: Double?, memory: Double?, disk: Double?, net: Double?
    /// Members, and members with readable usage (other users' processes need the helper).
    var count = 0
    var covered = 0

    init<S: Sequence>(_ procs: S) where S.Element == AmbientProc {
        func add(_ a: inout Double?, _ v: Double?) { if let v { a = (a ?? 0) + v } }
        for p in procs {
            add(&cpu, p.cpu); add(&gpu, p.gpu); add(&memory, p.footprint.map { Double($0) })
            add(&disk, p.disk); add(&net, p.net)
            if p.footprint != nil || p.cpu != nil { covered += 1 }
            count += 1
        }
    }

    func value(_ m: AmbientMetric) -> Double? {
        switch m {
        case .cpu: cpu
        case .gpu: gpu
        case .memory: memory
        case .disk: disk
        case .network: net
        }
    }

    /// Before a figure: "≥ " when members couldn't be read; "~" before memory of more than one process, which
    /// counts pages they share once per process (within 1 %, see GroupFootprint).
    func prefix(_ m: AmbientMetric) -> String { partial ? "≥ " : m == .memory && count > 1 ? "~" : "" }

    /// The sums leave out members whose usage couldn't be read.
    var partial: Bool { covered < count }
    var coverageNote: String? { partial ? "Sums cover \(covered) of \(count) processes" : nil }
}

/// A set of members inside a group, sorted out by `AmbientGroups.subgroups`.
struct AmbientSubgroup: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// Members another process than the group's leader is responsible for.
        case responsible(pid_t)
        /// Members sharing a controlling terminal.
        case terminal(Int32)
        /// Members running from `.xpc` bundles.
        case xpc
        /// Members with the same name.
        case name(String)
    }
    var id: Kind
    var title: String
    /// The process this sub-group is named after (the responsible one), for its row's icon and actions.
    var lead: AmbientProc?
    var members: [AmbientProc]
    var sums: AmbientSums
}

/// The processes the kernel accounts together: one resource coalition, plus the extensions and helpers that
/// run from inside its leader's app bundle. Named after its leader.
struct AmbientGroup: Identifiable, Hashable, Sendable {
    /// The coalition id; for a process whose coalition can't be read, `AmbientGroups.syntheticID(pid)`.
    var id: UInt64
    var leader: AmbientProc
    var subgroups: [AmbientSubgroup]
    /// Members in no sub-group, the leader first.
    var plain: [AmbientProc]
    var sums: AmbientSums
    var name: String { leader.name }
    var count: Int { sums.count }
    var single: Bool { sums.count == 1 }
    var members: [AmbientProc] { plain + subgroups.flatMap(\.members) }
}

/// Grouping for the menu bar dropdown and Triage, as pure functions over the monitor's processes. Only rules
/// the system applies to every process: coalitions, the responsible pid, the controlling terminal, bundle layout.
enum AmbientGroups {
    static func syntheticID(_ pid: pid_t) -> UInt64 { (1 << 63) | UInt64(UInt32(bitPattern: pid)) }

    /// Groups the processes, and sets `groupName` on each member that isn't its group's leader. Works on indices
    /// into `procs`: copying the structs through the buckets cost more than the rules themselves.
    static func group(_ procs: inout [AmbientProc]) -> [AmbientGroup] {
        // 1. Bucket by resource coalition.
        var buckets: [UInt64: [Int]] = [:]
        buckets.reserveCapacity(procs.count)
        for i in procs.indices { buckets[procs[i].coalition ?? syntheticID(procs[i].pid), default: []].append(i) }
        var leaders: [UInt64: Int] = [:]
        leaders.reserveCapacity(buckets.count)
        for (id, ix) in buckets { leaders[id] = leader(ix, procs) }

        // 2. Bundle containment: a group whose leader runs from inside another group's leader's app bundle joins it.
        // Targets are leaders that are their bundle's main executable; one level only.
        var bundles: [UInt64: (bundle: String, main: Bool)] = [:]
        var targets: [String: UInt64] = [:]
        for (id, l) in leaders {
            guard let path = procs[l].path, let b = outerBundle(path) else { continue }
            let main = isMainExecutable(path, of: b)
            bundles[id] = (b, main)
            guard main else { continue }
            if let other = targets[b], let o = leaders[other], procs[o].start <= procs[l].start { continue }   // two copies: the older
            targets[b] = id
        }
        // A bundle's own executable never merges (a second copy of an app stays its own group).
        for (id, b) in bundles where !b.main {
            guard let t = targets[b.bundle], t != id, let ix = buckets[id] else { continue }
            buckets[t, default: []].append(contentsOf: ix)
            buckets[id] = nil
            leaders[id] = nil
        }

        // 3. Names, then each group's sub-groups.
        for (id, ix) in buckets where ix.count > 1 {
            let l = leaders[id]!, name = procs[l].name
            for i in ix where i != l { procs[i].groupName = name }
        }
        let ps = procs
        return buckets.map { id, ix in
            let l = leaders[id]!
            let (subs, plain) = subgroups(ix, leader: l, ps)
            let sums = subs.isEmpty ? AmbientSums(plain) : AmbientSums(ix.lazy.map { ps[$0] })
            return AmbientGroup(id: id, leader: ps[l], subgroups: subs, plain: plain, sums: sums)
        }
    }

    /// Convenience for callers without a mutable list.
    static func group(_ procs: [AmbientProc]) -> [AmbientGroup] { var p = procs; return group(&p) }

    /// The member most members name as their responsible process; failing that (none readable, or a tie), the
    /// oldest member outside an `.xpc` bundle.
    static func leader(_ ix: [Int], _ procs: [AmbientProc]) -> Int {
        if ix.count == 1 { return ix[0] }
        var votes: [pid_t: Int] = [:]
        for i in ix { if let r = procs[i].responsible { votes[r, default: 0] += 1 } }
        // Only votes for a member count.
        var best: (pid: pid_t, n: Int, tie: Bool)?
        for i in ix {
            guard let n = votes[procs[i].pid] else { continue }
            if let b = best, n < b.n { continue }
            best = (procs[i].pid, n, best.map { $0.n == n } ?? false)
        }
        if let b = best, !b.tie, let l = ix.first(where: { procs[$0].pid == b.pid }) { return l }
        let pool = ix.filter { !isXPCService(procs[$0].path) }
        return (pool.isEmpty ? ix : pool).min { (procs[$0].start, procs[$0].pid) < (procs[$1].start, procs[$1].pid) }!
    }

    /// Sub-groups by the first rule that gives two or more members: responsible process (not the leader), terminal,
    /// XPC services, same name. A member that a rule matched alone falls through to the next. Returns the
    /// sub-groups and the members in none, the leader first.
    static func subgroups(_ ix: [Int], leader l: Int, _ procs: [AmbientProc]) -> ([AmbientSubgroup], [AmbientProc]) {
        var rest = ix.filter { $0 != l }
        guard rest.count >= 2 else { return ([], [procs[l]] + rest.map { procs[$0] }) }
        let leaderPid = procs[l].pid
        var out: [AmbientSubgroup] = []
        func take<K: Hashable>(_ key: (AmbientProc) -> K?, _ make: (K, [AmbientProc]) -> AmbientSubgroup) {
            guard rest.count >= 2 else { return }
            var sets: [K: [Int]] = [:]
            for i in rest { if let k = key(procs[i]) { sets[k, default: []].append(i) } }
            var taken: Set<Int> = []
            for (k, set) in sets where set.count >= 2 {
                out.append(make(k, set.map { procs[$0] }))
                taken.formUnion(set)
            }
            if !taken.isEmpty { rest.removeAll { taken.contains($0) } }
        }
        take({ m in m.responsible.flatMap { $0 == leaderPid ? nil : $0 } }) { r, set in
            let lead = ix.first { procs[$0].pid == r }.map { procs[$0] }
            return AmbientSubgroup(id: .responsible(r), title: lead?.name ?? "pid \(r)", lead: lead, members: set, sums: AmbientSums(set))
        }
        take({ $0.tty }) { t, set in
            var names: [String] = []
            for m in set.sorted(by: { $0.start < $1.start }) where !names.contains(m.name) { names.append(m.name) }
            return AmbientSubgroup(id: .terminal(t), title: SmartTree.ttyName(t) + " · " + names.joined(separator: ", "),
                                   lead: nil, members: set, sums: AmbientSums(set))
        }
        take({ isXPCService($0.path) ? true : nil }) { _, set in
            AmbientSubgroup(id: .xpc, title: "XPC services", lead: nil, members: set, sums: AmbientSums(set))
        }
        take({ $0.name }) { n, set in
            AmbientSubgroup(id: .name(n), title: "\(n) ×\(set.count)", lead: nil, members: set, sums: AmbientSums(set))
        }
        return (out, [procs[l]] + rest.map { procs[$0] })
    }

    /// The outermost `.app` bundle a path lies in ("/Applications/Foo.app"), nil outside any.
    static func outerBundle(_ path: String) -> String? {
        find(".app/", in: path).map { String(decoding: path.utf8[..<$0].dropLast(1), as: UTF8.self) }
    }

    /// Whether `path` is the bundle's own executable (`<bundle>/Contents/MacOS/<name>`), not a nested helper's.
    static func isMainExecutable(_ path: String, of bundle: String) -> Bool {
        let prefix = bundle + "/Contents/MacOS/"
        return path.hasPrefix(prefix) && !path.dropFirst(prefix.count).contains("/")
    }

    static func isXPCService(_ path: String?) -> Bool {
        guard let path, let r = find("/XPCServices/", in: path) else { return false }
        return find(".xpc/Contents/MacOS/", in: path, from: r) != nil
    }

    /// The index just past the first occurrence of `needle` in `path`'s UTF-8 bytes. Foundation's `range(of:)` costs
    /// microseconds per call, which over every group's leader each tick came to ~3 ms.
    static func find(_ needle: StaticString, in path: String, from start: String.UTF8View.Index? = nil) -> String.UTF8View.Index? {
        let u = path.utf8
        return needle.withUTF8Buffer { n -> String.UTF8View.Index? in
            guard let first = n.first else { return nil }
            var i = start ?? u.startIndex
            while let f = u[i...].firstIndex(of: first) {
                var a = f, j = 0
                while j < n.count, a < u.endIndex, u[a] == n[j] { a = u.index(after: a); j += 1 }
                if j == n.count { return a }
                i = u.index(after: f)
            }
            return nil
        }
    }

    /// The best `count` groups by a metric, in one pass.
    static func top(_ groups: [AmbientGroup], _ m: AmbientMetric, count: Int) -> [AmbientGroup] {
        var best: [(Double, Int)] = []
        for (i, g) in groups.enumerated() {
            guard let v = g.sums.value(m), v > 0, best.count < count || v > best[best.count - 1].0 else { continue }
            best.insert((v, i), at: best.firstIndex { $0.0 < v } ?? best.count)
            if best.count > count { best.removeLast() }
        }
        return best.map { groups[$0.1] }
    }
}
