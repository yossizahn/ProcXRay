import Foundation

/// Quick filters above the process tree: presets that add a clause to the filter predicate (PredicateBar).
enum FilterChip: String, CaseIterable, Identifiable, Sendable {
    case recent, nonAppleRoot, unsigned, notSandboxed, rosetta, busy, notResponding

    var id: String { rawValue }
    var title: String {
        switch self {
        case .recent: "Started < 5 min"
        case .nonAppleRoot: "Non-Apple as root"
        case .unsigned: "Unsigned or ad hoc"
        case .notSandboxed: "Not sandboxed"
        case .rosetta: "Rosetta"
        case .busy: "CPU > 5 %"
        case .notResponding: "Not responding"
        }
    }
    var help: String {
        switch self {
        case .recent: "Processes started in the last 5 minutes."
        case .nonAppleRoot: "Running as root (uid 0) and not Apple code: by signature once read, by path until then."
        case .unsigned: "No code signature, or an ad-hoc one that names no developer."
        case .notSandboxed: "Not in the App Sandbox (processes whose sandbox state can't be read are left out)."
        case .rosetta: "Intel code translated by Rosetta."
        case .busy: "Using more than 5 % of one core over the last refresh."
        case .notResponding: "Apps WindowServer reports as hung (Activity Monitor's \"Not Responding\")."
        }
    }

    /// What the chip adds to the predicate. Clicking the chip adds this clause with `and`, or takes it out.
    var source: String {
        switch self {
        case .recent: "started < 5m"
        case .nonAppleRoot: "uid == 0 and not apple"
        case .unsigned: "signer in (unsigned, ad-hoc)"
        case .notSandboxed: "sandboxed == no"
        case .rosetta: "rosetta"
        case .busy: "cpu > 5"
        case .notResponding: "hung"
        }
    }

    /// The chips an older version saved as a set ("recent,busy"), as a predicate.
    static func migrate(_ s: String) -> String {
        allCases.filter { s.split(separator: ",").map(String.init).contains($0.rawValue) }.map(\.source).joined(separator: " and ")
    }
}

enum TreeExtras {
    // Row ids, below every other synthetic range (SmartTree's role rows reach about -(2^43 + 2^41)).
    private static let pivotBase = -(1 << 46)
    private static let sameBinaryBase = -(1 << 47)

    // MARK: Pivots: the flat list grouped by one field

    static func pivotKey(_ g: Grouping, _ p: ProcInfo) -> String? {
        switch g {
        case .bySigner: p.signer.map { $0 == "unsigned" ? "Unsigned" : $0 == "ad-hoc" ? "Ad hoc" : $0 } ?? "Signature not read yet"
        case .byUser: p.user
        case .byDomain: p.launchdDomain.map { "launchd \($0) domain" } ?? "No launchd job of its own"
        case .bySandbox: p.sandboxed.map { $0 ? "Sandboxed" : "Not sandboxed" } ?? "Unknown"
        case .byArch: p.isTranslated ? "Intel (Rosetta)" : "Native"
        default: nil
        }
    }

    static func pivot(_ g: Grouping, _ all: [ProcInfo]) -> [ProcNode] {
        Dictionary(grouping: all) { pivotKey(g, $0) ?? "?" }.map { key, members in
            var n = ProcNode(id: pivotBase - Int(SmartTree.fnv("\(g.rawValue)|\(key)")), proc: nil, title: key,
                             children: members.map { ProcNode(id: Int($0.pid), proc: $0, title: $0.name) })
            n.kind = .group
            return n
        }
    }

    // MARK: Identical siblings

    /// Three or more sibling rows running the same executable, with nothing under them, become one
    /// collapsed row ("plugin-container ×14"). Rows with children are units of their own and stay apart.
    static func collapseIdentical(_ nodes: [ProcNode], parent: Int = 0) -> [ProcNode] {
        let mapped = nodes.map { n -> ProcNode in
            guard let c = n.children else { return n }
            var m = n
            m.children = collapseIdentical(c, parent: n.id)
            return m
        }
        var byBinary: [String: [Int]] = [:]
        for (i, n) in mapped.enumerated() {
            guard let p = n.proc, n.children?.isEmpty ?? true else { continue }
            byBinary[p.path ?? "comm:" + p.comm, default: []].append(i)
        }
        let sets = byBinary.filter { $0.value.count >= 3 }
        guard !sets.isEmpty else { return mapped }
        var drop: Set<Int> = []
        var out: [ProcNode] = []
        for (binary, idx) in sets {
            drop.formUnion(idx)
            let kids = idx.map { mapped[$0] }
            var g = ProcNode(id: sameBinaryBase - Int(SmartTree.fnv("\(parent)|\(binary)")), proc: nil,
                             title: "\(kids[0].proc!.name) ×\(kids.count)", children: kids)
            g.kind = .group
            g.startsCollapsed = true
            g.extensionPointShownAbove = kids[0].extensionPointShownAbove
            out.append(g)
        }
        return out + mapped.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }

    // MARK: Pruning by search text, chips and the filter predicate

    /// Without `keep` (no predicate), as before: a row matching the text keeps its whole subtree.
    /// With it, a process row must also pass `keep`, and groups keep only the rows under them that do.
    static func prune(_ nodes: [ProcNode], text: String, keep: ((ProcInfo) -> Bool)?) -> [ProcNode] {
        nodes.compactMap { n in
            if keep == nil, !text.isEmpty, n.matches(text) { return n }
            let kept = n.children.map { prune($0, text: text, keep: keep) } ?? []
            let selfPasses: Bool = {
                guard let keep, let p = n.proc else { return false }
                return (text.isEmpty || n.matches(text)) && keep(p)
            }()
            if kept.isEmpty && !selfPasses { return nil }
            var m = n
            m.children = n.children == nil ? nil : kept
            return m
        }
    }
}
