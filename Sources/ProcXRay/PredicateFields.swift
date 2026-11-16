import Foundation

/// The process list's filter fields: every column, by id or title, plus a few process facts no column shows.
@MainActor
enum PredicateFields {
    typealias Field = PredicateField<ProcInfo>
    typealias Compiled = Predicate<ProcInfo>

    /// Columns whose numbers carry a unit, so `500MB` or `10s` means what the column shows.
    private static let units: [String: PredicateUnit] = {
        var u: [String: PredicateUnit] = [:]
        for id in ["mem", "peakMem", "resident", "virtual", "neural", "compressed", "memLimit", "diskRead", "diskWritten",
                   "disk", "logicalWrites", "readRate", "writeRate", "netIn", "netOut"] { u[id] = .bytes }
        for id in ["cpuTime", "gpuTime"] { u[id] = .nanos }
        for id in ["started", "startTime"] { u[id] = .age }
        return u
    }()

    struct Extra {
        let name: String
        let help: String
        let field: Field
    }

    /// Facts without a column of their own.
    static let extras: [Extra] = [
        Extra(name: "ppid", help: "Parent process id", field: Field { p, _ in .number(Double(p.ppid)) }),
        Extra(name: "uid", help: "User id (0: root)", field: Field { p, _ in .number(Double(p.uid)) }),
        Extra(name: "comm", help: "Short name the kernel keeps (p_comm)", field: Field { p, _ in .text(p.comm) }),
        Extra(name: "apple", help: "Apple code: by signature once read, by path until then",
              field: Field { p, _ in .number(SmartTree.isApple(p) ? 1 : 0) }),
        Extra(name: "rosetta", help: "Intel code translated by Rosetta", field: Field { p, _ in .number(p.isTranslated ? 1 : 0) }),
        Extra(name: "hung", help: "Not responding, as WindowServer reports it", field: Field { p, _ in .number(p.notResponding ? 1 : 0) }),
    ]

    static func unit(_ id: String) -> PredicateUnit { units[id] ?? .plain }

    /// Lowercased letters and digits only: "Disk read" and "diskRead" are the same name.
    private static func key(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter || $0.isNumber }) }

    private static let lookup: [String: String] = {
        var m: [String: String] = [:]
        // Titles first, so an id wins where a title and another column's id collide.
        for c in Column.all where c.id != "context" { m[key(c.title)] = m[key(c.title)] ?? c.id }
        for c in Column.all where c.id != "context" { m[key(c.id)] = c.id }
        for e in extras { m[key(e.name)] = e.name }
        m["age"] = "started"
        m["memory"] = "mem"
        return m
    }()

    /// Every name the filter takes, for suggestions.
    static let names: [String] = Column.all.filter { $0.id != "context" }.map(\.id) + extras.map(\.name)

    static func resolve(_ typed: String, store: Store) -> (name: String, field: Field)? {
        guard let id = lookup[key(typed)] else { return nil }
        if let e = extras.first(where: { $0.name == id }) { return (id, e.field) }
        guard let col = Column.byID[id] else { return nil }
        let field = Field(unit: unit(id), value: { [weak store] p, now in
            guard let store else { return .unknown }
            return switch col.sortValue(p, store) {
            case .empty: .empty
            case .unknown: .unknown
            case .text(let s, _): .text(s)
            case .number(let v, _, _): .number(v)
            case .date(let d, _): .age(now.timeIntervalSince(d))
            }
        }, display: { [weak store] p in store.map { col.value(p, $0).display } })
        return (id, field)
    }

    static func compile(_ source: String, store: Store) throws -> Compiled? {
        try PredicateCompiler.compile(source, resolve: { resolve($0, store: store) }, names: names)
    }

    /// The extra reads the fields a filter uses need, as if their columns were shown.
    static func reads(_ p: Compiled?) -> ExtraReads {
        guard let p else { return [] }
        return Column.reads(for: p.fields)
    }
}

extension Store {
    /// `source` compiled, cached; nil when it's blank or doesn't parse. For counting (the chips): it doesn't
    /// change what refreshes read.
    func compiledPredicate(_ source: String) -> PredicateFields.Compiled? {
        let src = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if let c = compiledPredicates[src] { return c }
        if compiledPredicates.count > 100 { compiledPredicates.removeAll() }
        let compiled = try? PredicateFields.compile(src, store: self)
        compiledPredicates[src] = compiled
        return compiled
    }

    /// The process filter in force, compiled from `source`; nil when it's blank or doesn't parse. Keeps
    /// `predicateReads` in step, so refreshes read what its fields need.
    func predicate(_ source: String) -> PredicateFields.Compiled? {
        let compiled = compiledPredicate(source)
        let reads = PredicateFields.reads(compiled)
        if reads != predicateReads {
            predicateReads = reads
            // Read the new fields now rather than at the next tick, so the filter doesn't sit on blanks.
            // (Not from inside a view update, which is where nodes() runs.)
            if !reads.isSubset(of: extraReads) { DispatchQueue.main.async { [weak self] in self?.refresh() } }
        }
        return compiled
    }
}
