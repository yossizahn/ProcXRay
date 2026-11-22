import AppKit
import SwiftUI

/// `heap`'s class table: what the malloc heap holds, by type.
struct HeapView: View {
    let r: HeapReport
    let filter: String
    enum Kind: String, CaseIterable {
        case all = "All", objc = "Objective-C", swift = "Swift", cf = "Core Foundation", c = "C / C++", untyped = "Untyped"
        func contains(_ c: HeapClass) -> Bool {
            switch self {
            case .all: true
            case .objc: c.type == "ObjC"
            case .swift: c.type == "Swift"
            case .cf: c.type == "CFType"
            case .c: c.type == "C" || c.type == "C++"
            case .untyped: c.type.isEmpty
            }
        }
    }
    @State private var kind = Kind.all

    var body: some View {
        let total = r.totalBytes ?? r.classes.reduce(0) { $0 + $1.bytes }
        let untyped = r.classes.filter(\.isUntyped).reduce(UInt64(0)) { $0 + $1.bytes }
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    StatTile(title: "Physical footprint", value: Fmt.bytes(r.footprint),
                             sub: r.footprintPeak.map { "peak \(Fmt.bytes($0))" }, color: .accentColor)
                    StatTile(title: "Live malloc blocks", value: Fmt.bytes(total),
                             sub: (r.totalNodes ?? r.classes.reduce(0) { $0 + $1.count }).formatted() + " blocks"
                                + (r.zoneCount.map { " · \($0) zone\($0 == 1 ? "" : "s")" } ?? ""))
                    StatTile(title: "Types", value: r.classes.filter { !$0.isUntyped }.count.formatted(),
                             sub: r.found.isEmpty ? nil : r.found.map { "\($0.1) \(Self.foundName($0.0))" }.joined(separator: " · "))
                    if total > 0 {
                        StatTile(title: "Untyped", value: String(format: "%.0f%%", 100 * Double(untyped) / Double(total)),
                                 sub: "\(Fmt.bytes(untyped)) heap couldn't name", color: .secondary)
                    }
                }
                .padding(.horizontal, 10)
            }
            if !r.sizes.isEmpty { SizeHistogram(sizes: r.sizes).padding(.horizontal, 10) }
            ForEach(Array(r.notes.enumerated()), id: \.offset) { _, n in
                Text(n).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.horizontal, 10)
            }
            let rows = r.classes.filter { c in
                kind.contains(c) && (filter.isEmpty || c.name.localizedCaseInsensitiveContains(filter)
                                     || c.binary.localizedCaseInsensitiveContains(filter))
            }
            HStack(spacing: 8) {
                Picker("Kind", selection: $kind) { ForEach(Kind.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.menu).fixedSize()
                Spacer()
                Text(verbatim: "\(rows.filter { !$0.isUntyped }.count.formatted()) types · \(rows.reduce(0) { $0 + $1.count }.formatted()) blocks · \(Fmt.bytes(rows.reduce(0) { $0 + $1.bytes }))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            .padding(.horizontal, 10)
            FastTable(rows: rows, columns: Self.columns(total: total), initialSort: ("bytes", false), menu: { picked in
                guard let c = picked.first else { return [] }
                return [FastMenuItem(title: "Copy Name") { ProcessCommands.copy(c.name) },
                        FastMenuItem(title: "Copy Binary", enabled: !c.binary.isEmpty) { ProcessCommands.copy(c.binary) }]
            })
            .id(kind)
        }
        .padding(.top, 8)
    }

    /// "ObjC classes" → "Objective-C classes", "CFTypes" → "CF types".
    static func foundName(_ s: String) -> String {
        s.replacingOccurrences(of: "ObjC", with: "Objective-C").replacingOccurrences(of: "CFTypes", with: "CF types")
    }

    static func columns(total: UInt64) -> [FastColumn<HeapClass>] {
        let secondary = NSColor.secondaryLabelColor
        return [
            FastColumn(id: "name", title: "Type", width: 300, text: \.displayName, tooltip: \.displayName,
                       less: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }),
            FastColumn(id: "kind", title: "Kind", width: 120, text: \.kindName, color: { _ in secondary },
                       tooltip: { $0.type.isEmpty ? nil : "heap TYPE: \($0.type)" },
                       less: { $0.kindName < $1.kindName }),
            FastColumn(id: "count", title: "Count", width: 70, numeric: true, help: "Live blocks of this type (COUNT)",
                       text: { $0.count.formatted() }, less: { $0.count < $1.count }),
            FastColumn(id: "bytes", title: "Bytes", width: 80, numeric: true, help: "Their malloc sizes, summed (BYTES)",
                       text: { Fmt.bytes($0.bytes) }, less: { $0.bytes < $1.bytes }),
            FastColumn(id: "share", title: "% of Heap", width: 70, numeric: true,
                       text: { total > 0 ? String(format: "%.1f%%", 100 * Double($0.bytes) / Double(total)) : "—" },
                       color: { _ in secondary }, less: { $0.bytes < $1.bytes }),
            FastColumn(id: "avg", title: "Average", width: 75, numeric: true, help: "Bytes per block (AVG)",
                       text: { Fmt.bytes(UInt64($0.average.rounded())) }, less: { $0.average < $1.average }),
            FastColumn(id: "binary", title: "Binary", width: 200, help: "The image that defines the type (BINARY)",
                       text: \.binary, color: { _ in secondary }, less: { $0.binary < $1.binary }),
        ]
    }
}

/// Bytes held by blocks of each size, from heap's "Sizes: 10KB[1] … 16[221]" line, in power-of-two bins (a big app
/// has ~200 distinct sizes): the bar for 64 holds blocks of 33–64 bytes.
private struct SizeHistogram: View {
    let bins: [(upTo: UInt64, count: Int, bytes: UInt64)]
    init(sizes: [(size: UInt64, count: Int)]) {
        var by: [Int: (Int, UInt64)] = [:]
        for s in sizes where s.size > 0 {
            let k = 64 - (s.size - 1).leadingZeroBitCount   // ceil(log2(size))
            let old = by[k] ?? (0, 0)
            by[k] = (old.0 + s.count, old.1 + s.size * UInt64(s.count))
        }
        guard let lo = by.keys.min(), let hi = by.keys.max() else { bins = []; return }
        bins = (lo...hi).map { k in (UInt64(1) << k, by[k]?.0 ?? 0, by[k]?.1 ?? 0) }
    }

    var body: some View {
        let maxBytes = Double(bins.map(\.bytes).max() ?? 1)
        VStack(alignment: .leading, spacing: 2) {
            Text("Bytes by block size").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(bins.enumerated()), id: \.offset) { i, b in
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor.opacity(b.bytes > 0 ? 0.8 : 0))
                            .frame(width: 22, height: max(b.bytes > 0 ? 2 : 0, 36 * Double(b.bytes) / max(maxBytes, 1)))
                            .frame(height: 36, alignment: .bottom)
                        // Every other label, so they fit under 22-point bars.
                        Text(i % 2 == 0 ? Self.label(b.upTo) : " ").font(.system(size: 9)).foregroundStyle(.secondary)
                            .fixedSize()
                            .frame(width: 22)
                    }
                    .contentShape(Rectangle())
                    .help(b.count == 0 ? "No blocks of \(Self.range(b.upTo))"
                          : "\(b.count.formatted()) blocks of \(Self.range(b.upTo)), \(Fmt.bytes(b.bytes))")
                }
            }
        }
    }

    static func label(_ n: UInt64) -> String {
        n >= 1 << 20 ? "\(n >> 20)M" : n >= 1 << 10 ? "\(n >> 10)K" : "\(n)"
    }
    static func range(_ upTo: UInt64) -> String {
        upTo <= 16 ? "up to 16 bytes" : "\(Fmt.bytes(upTo / 2 + 1))–\(Fmt.bytes(upTo))"
    }
}
