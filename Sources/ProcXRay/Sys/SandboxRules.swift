import Foundation

/// Turns a compiled sandbox profile back into readable SBPL rules.
///
/// Each operation's root is the entry to a decision DAG of test/decision nodes. For every operation, and every
/// distinct non-default decision it can reach, this builds the graph of inputs that reach that decision and
/// reduces it series-parallel — parallel branches become `require-any`, sequential chains become `require-all` —
/// then prints one rule. This is the method SandBlaster uses (operation_node.py); it never enumerates paths, so
/// the graphs that would blow up as a disjunction of millions of paths (file-issue-extension and the like)
/// reduce in place instead.
///
/// What the rules describe is each operation's *effective* policy — the merged result the kernel enforces, which
/// is exactly what's useful to show. They are not meant to recompile byte-for-byte: SBPL's compiler expands
/// wildcard operations (`file-read*`) and derived operations into their concrete children and stores only the
/// merged per-operation graph, and that merge can't be factored back into separate source rules. Decoding is
/// faithful (checked on 347 cached profiles); re-deriving the original *source* is not always possible, and isn't
/// the goal here.
enum SandboxRules {
    struct Ruleset {
        /// e.g. `(deny default)`.
        let defaultRule: String
        /// One group per operation that has rules of its own, in table order.
        let operations: [OperationRules]
    }
    struct OperationRules: Identifiable {
        let name: String
        let rules: [String]
        var id: String { name }
    }

    /// Build the rules for a parsed profile. `tables` is libsandbox's name tables (operations, filters, modifiers).
    static func build(_ profile: CompiledSandboxProfile, tables: SandboxTables) -> Ruleset {
        let b = Builder(profile, tables)
        return b.generate()
    }

    /// Convenience: parse raw profile bytes and build. Returns nil if the tables aren't available.
    static func build(data: Data) throws -> Ruleset? {
        guard let tables = SandboxTables.shared else { return nil }
        let profile = try CompiledSandboxProfile(data)
        return build(profile, tables: tables)
    }
}

// MARK: - Builder

private final class Builder {
    let p: CompiledSandboxProfile
    let t: SandboxTables

    init(_ p: CompiledSandboxProfile, _ t: SandboxTables) { self.p = p; self.t = t }

    // ---- small accessors over the parsed nodes ----

    func isLeaf(_ ci: Int) -> Bool { if case .decision = p.nodes[ci] { return true }; return false }

    /// match and unmatch targets of a test node.
    func branches(_ ci: Int) -> (Int, Int) {
        if case let .test(_, _, _, m, u) = p.nodes[ci] { return (m, u) }
        return (0, 0)
    }

    func filter(_ fid: Int) -> SandboxTables.Filter? { fid < t.filters.count ? t.filters[fid] : nil }
    func filterName(_ fid: Int) -> String { filter(fid)?.name ?? "filter-\(fid)" }
    func filterArgType(_ fid: Int) -> UInt8 { filter(fid)?.argType ?? 0 }

    // ---- decisions ----

    /// An identity for a leaf decision: two leaves with the same key are "the same decision".
    struct DecisionKey: Hashable {
        let deny: Bool
        let otherFlags: UInt16
        let modifier: String?       // rendered modifier value, nil if none
    }

    func decisionKey(_ ci: Int) -> DecisionKey {
        guard case let .decision(flags, modifier, modifierOp, modifierArg) = p.nodes[ci] else {
            return DecisionKey(deny: false, otherFlags: 0, modifier: nil)
        }
        let deny = flags & 1 != 0
        var modval: String? = nil
        if let mi = modifier {
            let mname = mi < t.modifiers.count ? (t.modifiers[mi]?.name ?? "mod\(mi)") : "mod\(mi)"
            switch mname {
            case "message", "default-sandbox", "enable-state-flag", "user-approval", "assign-storage-class":
                modval = "str:\(mname):\(p.string(modifierArg) ?? "")"
            case "message-filter":
                let op = modifierOp < t.allOperations.count ? t.allOperations[modifierOp] : "\(modifierOp)"
                modval = "mf:\(op):\(modifierArg)"
            default:
                modval = "int:\(mname):\(modifierArg)"
            }
        }
        return DecisionKey(deny: deny, otherFlags: flags & ~0x1, modifier: modval)
    }

    /// (verb, modifier clauses) for a leaf, relative to the action defaults (allow keeps nothing, deny keeps report).
    func decisionSBPL(_ ci: Int) -> (verb: String, mods: [String]) {
        guard case let .decision(flags, modifier, modifierOp, modifierArg) = p.nodes[ci] else {
            return ("allow", [])
        }
        let deny = flags & 1 != 0
        var mods: [String] = []
        if deny {
            if flags & 0x4 == 0 { mods.append("no-report") }
        } else {
            if flags & 0x4 != 0 { mods.append("report") }
        }
        if flags & 0x80 != 0 { mods.append("telemetry") }
        let other = flags & ~0x85
        if other != 0 { mods.append(String(format: "flags#x%x", other)) }
        if let mi = modifier {
            let mname = mi < t.modifiers.count ? (t.modifiers[mi]?.name ?? "mod\(mi)") : "mod\(mi)"
            switch mname {
            case "message", "default-sandbox", "enable-state-flag", "user-approval", "assign-storage-class":
                mods.append("\(mname) \"\(quote(p.string(modifierArg) ?? ""))\"")
            case "message-filter":
                let op = modifierOp < t.allOperations.count ? t.allOperations[modifierOp] : "\(modifierOp)"
                mods.append("message-filter \(op)")
            default:
                mods.append("\(mname) \(modifierArg)")
            }
        }
        return (deny ? "deny" : "allow", mods)
    }

    // ---- filter rendering ----

    func quote(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }

    enum PathKind: String { case literal, prefix, subpath, regex }

    enum Classified {
        case simple(PathKind, [[UInt8]])        // one keyword, several values
        case regex([String])                    // alternatives, already regex text
        case mixed([(PathKind, [UInt8])])       // require-any of differing kinds
    }

    /// Classify a pattern program into literal / prefix / subpath / regex / mixed, mirroring sbrules.classify_pattern.
    func classify(_ code: ArraySlice<UInt8>) throws -> Classified {
        let alts = try SandboxPattern.decode(code, variables: p.variables)

        func litText(_ atoms: [SandboxPattern.Atom]) -> [UInt8]? {
            var out: [UInt8] = []
            for a in atoms { if case let .literal(bytes) = a { out += bytes } else { return nil } }
            return out
        }

        var closedLits: [[UInt8]] = [], openLits: [[UInt8]] = []
        var hasRegexy = false
        for alt in alts {
            if let lt = litText(alt.atoms) {
                if alt.open { openLits.append(lt) } else { closedLits.append(lt) }
            } else {
                hasRegexy = true
            }
        }

        if !hasRegexy {
            let exact = Set(closedLits.map { Data($0) })
            var subs: [[UInt8]] = [], matched: [[UInt8]] = []
            for ol in openLits where ol.last == UInt8(ascii: "/") {
                let base = Array(ol.dropLast())
                if exact.contains(Data(base)) { subs.append(base); matched.append(ol) }
            }
            if !subs.isEmpty && matched.count == openLits.count {
                let bases = Set(subs.map { Data($0) })
                let extraClosed = closedLits.filter { !bases.contains(Data($0)) }
                var frags: [(PathKind, [UInt8])] = subs.map { (.subpath, $0) } + extraClosed.map { (.literal, $0) }
                if frags.count == 1 { return .simple(frags[0].0, [frags[0].1]) }
                frags.sort { lexLess($0, $1) }
                return .mixed(frags)
            }
            if openLits.isEmpty { return .simple(.literal, closedLits) }
            if closedLits.isEmpty { return .simple(.prefix, openLits) }
            var frags: [(PathKind, [UInt8])] = closedLits.map { (.literal, $0) } + openLits.map { (.prefix, $0) }
            frags.sort { lexLess($0, $1) }
            return .mixed(frags)
        }

        // Has pieces only a regex can express: render every alternative as a regex.
        var res: [String] = []
        for alt in alts {
            var s = alt.atoms.compactMap { atom -> String? in
                if case .end = atom { return nil }
                return RegexText.text(of: atom)
            }.joined()
            if !alt.open && !s.hasSuffix("$") { s += "$" }
            res.append(s)
        }
        return .regex(res)
    }

    private func lexLess(_ a: (PathKind, [UInt8]), _ b: (PathKind, [UInt8])) -> Bool {
        if a.0.rawValue != b.0.rawValue { return a.0.rawValue < b.0.rawValue }
        return Data(a.1).lexicographicallyPrecedes(Data(b.1))
    }

    /// The SBPL for a test node's filter, e.g. `(subpath "/tmp")` or `(require-any …)`.
    func filterSBPL(_ ci: Int) -> String {
        guard case let .test(fid, isRegex, arg, _, _) = p.nodes[ci] else { return "(?)" }
        let name = filterName(fid)
        let at = filterArgType(fid)

        if isRegex {
            let rx = (arg < p.regexOffsets.count ? (try? AppleMatch.decode(item: p.item(p.regexOffsets[arg]) ?? [])) : nil) ?? "?"
            if at == 7 || name == "path" { return "(regex #\"\(quote(rx))\")" }
            return "(\(name)-regex #\"\(quote(rx))\")"
        }

        if at == 5 || at == 6 || at == 7 || at == 1 {
            guard let code = p.item(arg), let cls = try? classify(code) else {
                return "(\(name) ??)"
            }
            let isPath = (name == "path" || name == "mount-relative-path" || name == "process-path" || at == 7 || at == 1)
            func one(_ kind: PathKind, _ v: [UInt8]) -> String {
                let txt = quote(String(decoding: v, as: UTF8.self))
                if isPath { return "(\(kind.rawValue) \"\(txt)\")" }
                switch kind {
                case .literal: return "(\(name) \"\(txt)\")"
                case .prefix, .subpath: return "(\(name)-prefix \"\(txt)\")"
                case .regex: return "(\(name)-regex #\"\(txt)\")"
                }
            }
            switch cls {
            case .mixed(let frags):
                return "(require-any \(frags.map { one($0.0, $0.1) }.joined(separator: " ")))"
            case .regex(let vals):
                let disj = vals.map { isPath ? "(regex #\"\(quote($0))\")" : "(\(name)-regex #\"\(quote($0))\")" }
                return disj.count == 1 ? disj[0] : "(require-any \(disj.joined(separator: " ")))"
            case .simple(let variant, let vals):
                let quoted = vals.map { "\"\(quote(String(decoding: $0, as: UTF8.self)))\"" }.joined(separator: " ")
                if isPath { return "(\(variant.rawValue) \(quoted))" }
                let suffix = variant == .literal ? "" : "-prefix"
                return "(\(name)\(suffix) \(quoted))"
            }
        }

        if at == 4 { return "(\(name) \"\(quote(p.string(arg) ?? ""))\")" }

        if at == 3 {
            if let f = filter(fid), let v = f.values.first(where: { UInt16($0.value & 0xffff) == UInt16(arg & 0xffff) }) {
                return "(\(name) \(v.name))"
            }
            return "(\(name) \(arg))"
        }

        if at == 8, let raw = p.raw(arg, count: 4) {
            let bytes = Array(raw)
            let proto = [3: "ip", 7: "tcp", 0x0b: "udp"][Int(bytes[0])] ?? "ip"
            let host = [0: "*", 1: "localhost"][Int(bytes[1])] ?? "*"
            let port = Int(bytes[2]) | Int(bytes[3]) << 8
            return "(\(name) \(proto) \"\(host):\(port == 0 ? "*" : "\(port)")\")"
        }

        return "(\(name) #raw\(arg))"
    }

    // MARK: - Graph build (sandblaster build_operation_node_graph)

    final class Graph {
        var succ: [Int: Set<Int>] = [:]
        var start: Set<Int> = []
        var final: Set<Int> = []
        var neg: [Int: Bool] = [:]
        var eff: [Int: (Int, Int)] = [:]      // effective (match, unmatch) after any negation
    }

    func buildGraph(root: Int, decision D: DecisionKey) -> Graph {
        let g = Graph()

        func klass(_ ci: Int) -> Character {
            if isLeaf(ci) { return decisionKey(ci) == D ? "D" : "X" }
            return "n"      // non-terminal
        }
        func ensure(_ ci: Int) {
            if g.succ[ci] == nil {
                g.succ[ci] = []
                g.neg[ci] = false
                let (m, u) = branches(ci)
                g.eff[ci] = (m, u)
            }
        }
        func markNot(_ ci: Int) {
            g.neg[ci] = !(g.neg[ci] ?? false)
            let (m, u) = g.eff[ci]!
            g.eff[ci] = (u, m)
        }

        var todo: [(Int?, Int)] = [(nil, root)]
        var seenPairs = Set<String>()
        while let (parent, cur) = todo.popLast() {
            if isLeaf(cur) { continue }
            ensure(cur)
            if parent == nil { g.start.insert(cur) }
            let key = "\(parent.map(String.init) ?? "_")>\(cur)"
            if seenPairs.contains(key) { continue }
            seenPairs.insert(key)
            let (m, u) = g.eff[cur]!
            let mk = klass(m), uk = klass(u)

            func addPath(_ nxt: Int) { if !isLeaf(nxt) { g.succ[cur, default: []].insert(nxt); todo.append((cur, nxt)) } }
            func addParent(_ nxt: Int) {
                if !isLeaf(nxt) {
                    if let par = parent { g.succ[par, default: []].insert(nxt) }
                    todo.append((parent, nxt))
                }
            }
            func endPath() { g.final.insert(cur) }

            switch (mk, uk) {
            case ("n", "X"): addPath(m)
            case ("n", "D"): markNot(cur); endPath(); addParent(m)
            case ("n", "n"): addPath(m); addParent(u)
            case ("D", "n"): endPath(); addParent(u)
            case ("X", "n"): markNot(cur); addPath(u)
            case ("X", "D"): markNot(cur); endPath()
            case ("D", "X"): endPath()
            case ("D", "D"): endPath()
            default: break      // ("X","X"): never reaches D
            }
        }

        // Drop dead ends: non-final nodes with no successors don't reach D (sandblaster clean_nodes).
        var changed = true
        while changed {
            changed = false
            for ni in Array(g.succ.keys) where !g.final.contains(ni) && (g.succ[ni]?.isEmpty ?? true) {
                g.succ[ni] = nil
                g.start.remove(ni); g.neg[ni] = nil; g.eff[ni] = nil
                for k in g.succ.keys { g.succ[k]?.remove(ni) }
                changed = true
            }
        }
        return g
    }

    // MARK: - Series-parallel reduction (sandblaster ReducedGraph)

    final class V {
        enum Kind { case single, all, any }
        let kind: Kind
        var node: Int = 0           // single: original node index
        var children: [V] = []      // all / any
        var neg: Bool = false
        init(single node: Int, neg: Bool) { kind = .single; self.node = node; self.neg = neg }
        init(_ kind: Kind, _ children: [V]) { self.kind = kind; self.children = children }
    }

    final class RG {
        var vertices: [V] = []
        var edges: [(V, V)] = []
        var starts: [V] = []
        var finals: [V] = []

        func nextOf(_ v: V) -> [V] { edges.filter { $0.0 === v }.map { $0.1 } }
        func prevOf(_ v: V) -> [V] { edges.filter { $0.1 === v }.map { $0.0 } }
        func addEdge(_ a: V, _ b: V) { if !edges.contains(where: { $0.0 === a && $0.1 === b }) { edges.append((a, b)) } }
        func rmEdge(_ a: V, _ b: V) { edges.removeAll { $0.0 === a && $0.1 === b } }

        func replaceList(_ old: [V], with new: V) {
            let oset = Set(old.map { ObjectIdentifier($0) })
            var ne: [(V, V)] = []
            for (a, b) in edges {
                let a2 = oset.contains(ObjectIdentifier(a)) ? new : a
                let b2 = oset.contains(ObjectIdentifier(b)) ? new : b
                if a2 === b2 { continue }
                if !ne.contains(where: { $0.0 === a2 && $0.1 === b2 }) { ne.append((a2, b2)) }
            }
            edges = ne
            starts = dedup(starts.map { oset.contains(ObjectIdentifier($0)) ? new : $0 })
            finals = dedup(finals.map { oset.contains(ObjectIdentifier($0)) ? new : $0 })
        }
    }

    static func dedup(_ lst: [V]) -> [V] {
        var out: [V] = []
        for x in lst where !out.contains(where: { $0 === x }) { out.append(x) }
        return out
    }
    private func dedup(_ lst: [V]) -> [V] { Builder.dedup(lst) }

    /// Reduce the graph series-parallel and emit SBPL, or nil if a non-series-parallel core remains.
    func reduceGraph(_ g: Graph) -> String? {
        let rg = RG()
        var vmap: [Int: V] = [:]
        for ni in g.succ.keys {
            let v = V(single: ni, neg: g.neg[ni] ?? false)
            vmap[ni] = v; rg.vertices.append(v)
        }
        for (ni, ss) in g.succ {
            for s in ss { if let a = vmap[ni], let b = vmap[s] { rg.addEdge(a, b) } }
        }
        rg.starts = dedup(g.start.compactMap { vmap[$0] })
        rg.finals = dedup(g.final.compactMap { vmap[$0] })

        var guardCount = 0
        loop: while true {
            guardCount += 1
            if guardCount > 200_000 { return nil }

            // fan-out: a vertex with >1 successors -> require-any of them
            for v in rg.vertices {
                let nxt = rg.nextOf(v)
                if nxt.count > 1 {
                    let meta = V(.any, nxt)
                    rg.vertices.append(meta)
                    rg.replaceList(nxt, with: meta)
                    rg.addEdge(v, meta)
                    rg.vertices.removeAll { vv in nxt.contains { $0 === vv } }
                    continue loop
                }
            }
            // fan-in: a vertex with >1 predecessors -> require-any of them
            for v in rg.vertices {
                let prv = rg.prevOf(v)
                if prv.count > 1 {
                    let meta = V(.any, prv)
                    rg.vertices.append(meta)
                    rg.replaceList(prv, with: meta)
                    rg.addEdge(meta, v)
                    rg.vertices.removeAll { vv in prv.contains { $0 === vv } }
                    continue loop
                }
            }
            // series: p -> v, p has one successor and v one predecessor -> require-all
            for v in rg.vertices {
                let prv = rg.prevOf(v)
                if prv.count == 1 {
                    let pp = prv[0]
                    if rg.nextOf(pp).count == 1 {
                        let lst = (pp.kind == .all ? pp.children : [pp]) + (v.kind == .all ? v.children : [v])
                        let meta = V(.all, lst)
                        rg.vertices.append(meta)
                        rg.rmEdge(pp, v)
                        rg.replaceList([pp, v], with: meta)
                        rg.vertices.removeAll { $0 === pp || $0 === v }
                        continue loop
                    }
                }
            }
            break
        }

        if rg.vertices.count == 1 && rg.edges.isEmpty { return emit(rg.vertices[0]) }
        if rg.edges.isEmpty && !rg.vertices.isEmpty && rg.vertices.allSatisfy({ v in rg.finals.contains { $0 === v } }) {
            if rg.vertices.count == 1 { return emit(rg.vertices[0]) }
            return "(require-any \(rg.vertices.map { emit($0) }.joined(separator: " ")))"
        }
        return nil
    }

    func emit(_ v: V) -> String {
        switch v.kind {
        case .single:
            let s = filterSBPL(v.node)
            return v.neg ? "(require-not \(s))" : s
        case .all, .any:
            // require-all/require-any are commutative; sort children for stable, searchable output.
            let inner = v.children.map { emit($0) }.sorted().joined(separator: " ")
            return "(\(v.kind == .all ? "require-all" : "require-any") \(inner))"
        }
    }

    // MARK: - Generate

    func generate() -> SandboxRules.Ruleset {
        let defaultRoot = p.operationRoots[0]
        let (dverb, dmods) = decisionSBPL(defaultRoot)
        let defaultDec = decisionKey(defaultRoot)
        let defaultRule = "(\(dverb) default\(dmods.map { " (with \($0))" }.joined()))"

        var groups: [SandboxRules.OperationRules] = []

        for oi in 1..<p.operationCount {
            let opname = oi < t.operations.count ? t.operations[oi] : "op\(oi)"
            // Wildcard operations expand into their children at compile time; show the children, not the wildcard.
            if opname.hasSuffix("*") { continue }
            let root = p.operationRoots[oi]
            if isLeaf(root) && decisionKey(root) == defaultDec { continue }

            // Distinct non-default decisions this operation can reach.
            var decs: [DecisionKey: Int] = [:]
            var stack = [root]; var seen = Set<Int>()
            while let ci = stack.popLast() {
                if seen.contains(ci) { continue }
                seen.insert(ci)
                if isLeaf(ci) {
                    let dk = decisionKey(ci)
                    if dk != defaultDec { decs[dk] = ci }
                } else {
                    let (m, u) = branches(ci)
                    stack.append(m); stack.append(u)
                }
            }

            var rules: [String] = []
            for (D, leafci) in decs {
                let (verb, mods) = decisionSBPL(leafci)
                let ms = mods.map { " (with \($0))" }.joined()
                if isLeaf(root) {
                    rules.append("(\(verb) \(opname)\(ms))")
                    continue
                }
                let g = buildGraph(root: root, decision: D)
                if let cond = reduceGraph(g) {
                    rules.append("(\(verb) \(opname) \(cond)\(ms))")
                } else {
                    // The note goes after the rule: inside it, the comment would swallow the closing parens.
                    rules.append("(\(verb) \(opname)\(ms)) ;; condition too complex to show as one rule")
                }
            }
            if !rules.isEmpty {
                rules.sort()
                groups.append(SandboxRules.OperationRules(name: opname, rules: rules))
            }
        }

        return SandboxRules.Ruleset(defaultRule: defaultRule, operations: groups)
    }
}
