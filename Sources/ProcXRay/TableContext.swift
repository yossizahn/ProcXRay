import Foundation

/// One refresh's picture of the system, as the columns and the tree read it. It never changes once made, so a
/// tree can be built from it on any thread while the store moves on: the refresh builds the table's tree in the
/// background, next to the snapshot, and the main thread only swaps the result in.
final class TableContext: @unchecked Sendable {
    let procs: [pid_t: ProcInfo]
    let lsApps: [LSApp]
    /// BTM.ownerIndex of the Background Items records, for the Smart tree.
    let btmOwners: [String: [String]]
    private let signs: [String: SignInfo]

    private let lock = NSLock()
    private var kinds: (map: [pid_t: String], roots: [pid_t: pid_t])?

    init(procs: [pid_t: ProcInfo], lsApps: [LSApp], btmOwners: [String: [String]], signs: [String: SignInfo]) {
        self.procs = procs
        self.lsApps = lsApps
        self.btmOwners = btmOwners
        self.signs = signs
    }

    static let empty = TableContext(procs: [:], lsApps: [], btmOwners: [:], signs: [:])

    var smartInput: SmartTree.Input { .init(procs: procs, lsApps: lsApps, btmOwners: btmOwners) }

    func signInfo(for p: ProcInfo) -> SignInfo? { signs[p.codeKey] }

    /// "App · XPC service", "Extension · Widgets": the Smart tree's category of the process's unit, then its role.
    /// Worked out for every process the first time one is asked for.
    func kind(of p: ProcInfo) -> String? { kindTable.map[p.pid] }

    /// The main process of the Smart tree unit each process belongs to.
    var unitRoots: [pid_t: pid_t] { kindTable.roots }

    private var kindTable: (map: [pid_t: String], roots: [pid_t: pid_t]) {
        lock.lock(); defer { lock.unlock() }
        if let kinds { return kinds }
        let k = SmartTree.kinds(smartInput)
        kinds = (k.kinds, k.roots)
        return kinds!
    }
}

/// What the process table asks for: everything besides the data that decides its tree.
struct TreeSpec: Equatable, Sendable {
    var grouping: Grouping
    var filter = ""
    /// The filter predicate's source (PredicateCompiler); one that doesn't parse filters nothing.
    var predicate = ""
    var sort: ColumnSort
    /// The shown columns, whose group-row values are worked out (the others cost nothing).
    var columns: Set<String> = []
}

/// The pinned rows as of one moment (Pins), for building a tree off the main thread.
struct PinRanks: Sendable {
    var version = 0
    var rankOf: [String: Int] = [:]
    var isEmpty: Bool { rankOf.isEmpty }
    func rank(_ key: String?) -> Int? { key.flatMap { rankOf[$0] } }
}

/// Builds the process table's rows: grouping, filter, each group row's values, and the sort. No state of its
/// own and nothing from the main thread, so the same code runs in the refresh's background task and, when the
/// user changes the view, at once on the main thread.
enum TreeBuilder {
    static func build(_ spec: TreeSpec, _ ctx: TableContext, pins: PinRanks) -> [ProcNode] {
        let procs = ctx.procs
        let all = Array(procs.values)
        var roots: [ProcNode]
        switch spec.grouping {
        case .smart:
            roots = SmartTree.build(ctx.smartInput)
        case .flat:
            roots = all.map { ProcNode(id: Int($0.pid), proc: $0, title: $0.name) }
        case .responsible:
            roots = responsibleTree(all, ctx)
        case .bySigner, .byUser, .bySession, .byDomain, .bySandbox, .byArch:
            roots = TreeExtras.pivot(spec.grouping, all)
        }
        if spec.grouping != .flat { TreeExtras.collapseIdentical(&roots) }
        // Every pass works on the tree in place: each copy of it copied every node's ProcInfo.
        let predicate = try? PredicateFields.compile(spec.predicate.trimmingCharacters(in: .whitespacesAndNewlines), context: ctx)
        let pruning = !spec.filter.isEmpty || predicate != nil
        if pruning {
            count(&roots)
            let now = Date()
            roots = TreeExtras.prune(roots, text: spec.filter, keep: predicate.map { p in { p.test($0, now) } })
        }
        let shown = Column.all.filter { spec.columns.contains($0.id) && $0.id != "name" && $0.id != "context" }
        // Unpruned, the totals are the shown counts, which the sort pass works out anyway.
        var pass = SortPass(ctx: ctx, pins: pins, sort: spec.sort, shown: shown, sortColumn: Column.byID[spec.sort.id],
                            totals: !pruning)
        _ = pass.sort(&roots)
        return roots
    }

    private static func responsibleTree(_ all: [ProcInfo], _ ctx: TableContext) -> [ProcNode] {
        let procs = ctx.procs
        let lsByPid = Dictionary(ctx.lsApps.compactMap { a in a.pid.map { ($0, a) } }, uniquingKeysWith: { a, _ in a })
        var ghostIDs: [pid_t: Int] = [:]
        var leftGroups: [Int: String] = [:]   // Left Behind group id -> title
        var up: [pid_t: Int] = [:]
        for p in all {
            if let g = p.leftBehindGroup, let t = p.leftBehindText {
                leftGroups[g] = t
                up[p.pid] = g
            } else if let r = p.responsible, r != p.pid {
                if procs[r] != nil { up[p.pid] = Int(r) } else {
                    ghostIDs[r] = -Int(r) - 1
                    up[p.pid] = -Int(r) - 1
                }
            } else if p.ppid > 1, p.ppid != p.pid, procs[p.ppid] != nil {
                // No responsible process of its own (or it's its own): its parent, as the Parent tree had
                // it. launchd (1) and kernel_task (0) parent nearly everything, so their children stay roots.
                up[p.pid] = Int(p.ppid)
            }
        }
        // Mixing the two links can close a loop (A responsible for B, B the parent of A), and a process
        // on a loop would never be reached from a root. Cut each loop at the process where it's found.
        for p in all {
            var seen: Set<pid_t> = [p.pid]
            var cur = p.pid
            while let u = up[cur], u > 0 {
                let next = pid_t(u)
                if !seen.insert(next).inserted { up[cur] = nil; break }
                cur = next
            }
        }
        var roots = tree(all) { up[$0.pid] }
        // tree() put orphans-of-ghosts under synthetic ids; materialize those groups.
        var extra: [ProcNode] = []
        let byParent = Dictionary(grouping: roots.filter { $0.id < 0 }, by: \.id)
        roots.removeAll { $0.id < 0 }
        for (dead, gid) in ghostIDs where leftGroups[gid] == nil {
            let kids = byParent[gid]?.flatMap { $0.children ?? [] } ?? []
            let name = lsByPid[dead]?.name ?? "?"
            extra.append(ProcNode(id: gid, proc: nil, title: "\(name) (exited, pid \(dead))",
                                  subtitle: "responsible process is gone", isGhost: true, children: kids))
        }
        for (gid, text) in leftGroups {
            let kids = byParent[gid]?.flatMap { $0.children ?? [] } ?? []
            extra.append(ProcNode(id: gid, proc: nil, title: "\(text) (exited)",
                                  subtitle: "app is gone; these outlived it", isGhost: true, children: kids))
        }
        return roots + extra
    }

    /// Sets totalCount (processes in the subtree) before the search filter prunes anything.
    private static func count(_ nodes: inout [ProcNode]) {
        for i in nodes.indices {
            var total = nodes[i].proc == nil ? 0 : 1
            if nodes[i].children != nil {
                count(&nodes[i].children!)
                total += nodes[i].children!.reduce(0) { $0 + $1.totalCount }
            }
            nodes[i].totalCount = total
        }
    }

    /// Build a forest using `parentOf`; unknown parents (negative ids) become temporary placeholder roots.
    private static func tree(_ all: [ProcInfo], parentOf: (ProcInfo) -> Int?) -> [ProcNode] {
        var kids: [Int: [ProcInfo]] = [:]
        var roots: [ProcInfo] = []
        var placeholders: [Int: [ProcInfo]] = [:]
        for p in all {
            if let par = parentOf(p) {
                if par < 0 { placeholders[par, default: []].append(p) } else { kids[par, default: []].append(p) }
            } else { roots.append(p) }
        }
        func build(_ p: ProcInfo, depth: Int) -> ProcNode {
            let c = depth < 64 ? (kids[Int(p.pid)] ?? []).map { build($0, depth: depth + 1) } : []
            return ProcNode(id: Int(p.pid), proc: p, title: p.name, children: c.isEmpty ? nil : c)
        }
        var out = roots.map { build($0, depth: 0) }
        for (gid, ps) in placeholders {
            out.append(ProcNode(id: gid, proc: nil, title: "", children: ps.map { build($0, depth: 1) }))
        }
        return out
    }

    /// The pass that fills in each row's values and orders the rows.
    ///
    /// Ties are broken by row id. Without that, rows that tie (every group row has the same pidKey)
    /// kept Dictionary iteration order, which reshuffles whenever a process comes or goes; the table then
    /// saw hundreds of moved rows per refresh and spent seconds rebuilding and re-measuring row views.
    /// Children are sorted first so each node's cpuKey/memKey (subtree totals) is set before it is compared.
    /// Also fills each group row's value for every shown column (by the column's group rule) and each
    /// row's value in the sort column.
    private struct SortPass {
        let ctx: TableContext
        let pins: PinRanks
        let sort: ColumnSort
        let shown: [Column]
        let sortColumn: Column?
        /// Also set totalCount (nothing was pruned, so it equals shownCount).
        let totals: Bool
        /// Each process's value per shown column, worked out once: a process is a member of every group row
        /// above it.
        var memo: [[pid_t: CellValue]] = []

        /// Returns the processes under `nodes`, for the parent's group values.
        mutating func sort(_ nodes: inout [ProcNode]) -> [ProcBox] {
            var allMembers: [ProcBox] = []
            for i in nodes.indices {
                var members: [ProcBox] = []
                if nodes[i].children != nil { members = sort(&nodes[i].children!) }
                let proc = nodes[i].box
                if let p = proc { members.append(p) }
                allMembers += members
                if proc == nil {
                    for (c, col) in shown.enumerated() {
                        // The memo is taken out for the call: the closure can't capture `self` while it mutates.
                        var m = memo
                        memo = []
                        let ctx = self.ctx
                        let v = col.groupValue(nodes[i], members: members, store: ctx) { p in
                            while m.count <= c { m.append([:]) }
                            if let v = m[c][p.pid] { return v }
                            let v = col.value(p, ctx)
                            m[c][p.pid] = v
                            return v
                        }
                        memo = m
                        nodes[i].groupValues[col.id] = v
                    }
                }
                if sort.id == "name" {
                    nodes[i].sortValue = .text(nodes[i].title)
                } else if let col = sortColumn {
                    let v = proc.map { col.sortValue($0.info, ctx) } ?? nodes[i].groupValues[col.id]
                        ?? col.groupValue(nodes[i], members: members, store: ctx) { col.value($0, ctx) }
                    nodes[i].sortValue = v
                }
                let kids = nodes[i].children ?? []
                if let p = proc {
                    nodes[i].cpuKey = p.info.cpuPercent ?? 0
                    nodes[i].memKey = p.info.footprint ?? 0
                    nodes[i].diskKey = ProcNode.disk(p.info)
                } else {
                    nodes[i].cpuKey = kids.reduce(0) { $0 + $1.cpuKey }
                    nodes[i].memKey = kids.reduce(0) { $0 + $1.memKey }
                    let known = kids.map(\.diskKey).filter { $0 >= 0 }
                    nodes[i].diskKey = known.isEmpty ? -1 : known.reduce(0, &+)
                }
                nodes[i].shownCount = (proc == nil ? 0 : 1) + kids.reduce(0) { $0 + $1.shownCount }
                if totals { nodes[i].totalCount = nodes[i].shownCount }
                nodes[i].unitCount = kids.reduce(0) { $0 + ($1.kind == .group ? $1.unitCount : 1) }
                if !pins.isEmpty {
                    let own = pins.rank(Pins.row(nodes[i], procs: ctx.procs))
                    nodes[i].pinned = own != nil
                    nodes[i].pinRank = ([own] + kids.map(\.pinRank)).compactMap { $0 }.min()
                }
            }
            // Sorts positions by small keys, then places each node once: sorting the nodes themselves moved whole
            // ProcNodes (a ProcInfo each) at every comparison step, which was most of a rebuild.
            struct Key { var pin: Int?; var fixed: Int?; var value: CellValue; var has: Bool; var id: Int }
            let keys = nodes.map { Key(pin: $0.pinRank, fixed: $0.fixedOrder, value: $0.sortValue, has: $0.sortValue.hasValue, id: $0.id) }
            let ascending = sort.ascending
            let order = keys.withUnsafeBufferPointer { k in
                k.indices.sorted { i, j in
                    let a = k[i], b = k[j]
                    // Pinned rows (and groups holding one) first, in the order they were pinned.
                    if a.pin != b.pin { return (a.pin ?? .max) < (b.pin ?? .max) }
                    if a.fixed != nil || b.fixed != nil, a.fixed != b.fixed {
                        return (a.fixed ?? .max) < (b.fixed ?? .max)
                    }
                    // Rows without a value go last, whichever way the column is sorted.
                    if a.has != b.has { return a.has }
                    if a.has {
                        switch CellValue.compare(a.value, b.value) {
                        case .orderedAscending: return ascending
                        case .orderedDescending: return !ascending
                        case .orderedSame: break
                        }
                    }
                    return a.id < b.id
                }
            }
            if !order.elementsEqual(order.indices) { nodes = order.map { nodes[$0] } }
            return allMembers
        }
    }
}
