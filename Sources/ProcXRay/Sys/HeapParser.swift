import Foundation

// MARK: - heap

/// One row of heap's class table: every live malloc block heap matched to one type, summed.
struct HeapClass: Identifiable, Hashable, Sendable {
    let id: Int
    var name: String
    /// heap's TYPE column: ObjC, Swift, CFType, C, C++; empty for untyped blocks ("non-object").
    var type: String
    var binary: String
    var count: Int
    var bytes: UInt64
    var average: Double

    var isUntyped: Bool { type.isEmpty && name == "non-object" }

    /// The TYPE column in words (phrase, then heap's own term where it differs).
    var kindName: String {
        switch type {
        case "ObjC": "Objective-C"
        case "Swift": "Swift"
        case "CFType": "CF type"
        case "C": "C struct"
        case "C++": "C++"
        case "": isUntyped ? "Untyped" : "Raw buffer (malloc)"
        default: type
        }
    }
    var displayName: String { isUntyped ? "Untyped malloc blocks (non-object)" : name }
}

struct HeapReport: Sendable {
    var header: [(String, String)] = []
    var footprint: UInt64?
    var footprintPeak: UInt64?
    /// "Process 6529: 2 zones".
    var zoneCount: Int?
    /// "All zones: 950 nodes (107056 bytes)": every live malloc block.
    var totalNodes: Int?
    var totalBytes: UInt64?
    /// "Sizes: 10KB[1] 5KB[1] … 16[221]": how many blocks of each malloc size, largest size first.
    var sizes: [(size: UInt64, count: Int)] = []
    /// "Found:  165 ObjC classes  43 Swift classes  66 CFTypes" → [("ObjC classes", 165), …].
    var found: [(String, Int)] = []
    var classes: [HeapClass] = []
    /// Lines heap printed about its own limits, such as the hint to use MallocStackLogging.
    var notes: [String] = []
    var isEmpty: Bool { classes.isEmpty }
}

/// Reads `heap <pid>` (the aggregated report, not --zones or --addresses).
enum HeapParser {
    private static let rowRE = try! NSRegularExpression(pattern: #"^\s*(\d+)\s+(\d+)\s+(\d+(?:\.\d+)?)\s+(\S.*?)\s*$"#)
    /// The rest of a row after AVG: CLASS_NAME, TYPE and BINARY, the columns two or more spaces apart. A name that
    /// overflows its column is still followed by two spaces. A raw buffer named by the field that points to it
    /// ("__DataStorage._bytes (malloc)") has a BINARY but no TYPE; "non-object" has neither.
    private static let restRE = try! NSRegularExpression(pattern: #"^(.*?\S)\s{2,}(\S+)\s{2,}(\S.*)$"#)
    private static let nameBinaryRE = try! NSRegularExpression(pattern: #"^(.*?\S)\s{2,}(\S.*)$"#)
    private static let totalRE = try! NSRegularExpression(pattern: #"^All zones:\s+(\d+) nodes \((\d+) bytes\)"#)
    private static let sizeRE = try! NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)(KB|MB|GB)?\[(\d+)\]"#)
    private static let foundRE = try! NSRegularExpression(pattern: #"(\d+) ([A-Za-z+]+(?: classes)?)"#)

    static func parse(_ text: String) -> HeapReport {
        var r = HeapReport()
        enum Section { case header, body, table }
        var sec = Section.header
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let t = line.trimmingCharacters(in: .whitespaces)
            switch sec {
            case .header:
                if t == "----" { sec = .body; continue }
                guard let c = t.range(of: ":") else { continue }
                let k = String(t[..<c.lowerBound]), v = t[c.upperBound...].trimmingCharacters(in: .whitespaces)
                if k == "Physical footprint" { r.footprint = SizeText.bytes(v) }
                else if k == "Physical footprint (peak)" { r.footprintPeak = SizeText.bytes(v) }
                else if !k.isEmpty { r.header.append((k, v)) }
            case .body:
                if t.hasPrefix("=====") { sec = .table; continue }
                if t.isEmpty || t.hasPrefix("-----") || t.hasPrefix("COUNT") { continue }
                if t.hasPrefix("Process "), let z = t.range(of: #"(\d+) zones?$"#, options: .regularExpression) {
                    r.zoneCount = Int(t[z].prefix { $0.isNumber })
                } else if t.hasPrefix("All zones:"), t.contains("Sizes:") {
                    r.sizes = matches(sizeRE, String(t[t.range(of: "Sizes:")!.upperBound...])).compactMap { g in
                        guard let n = Double(g[0]), let c = Int(g[2]) else { return nil }
                        let mult: Double = g[1] == "KB" ? 0x1p10 : g[1] == "MB" ? 0x1p20 : g[1] == "GB" ? 0x1p30 : 1
                        return (UInt64((n * mult).rounded()), c)
                    }
                } else if let g = groups(totalRE, t) {
                    r.totalNodes = Int(g[0]); r.totalBytes = UInt64(g[1])
                } else if t.hasPrefix("Found:") {
                    r.found = matches(foundRE, String(t.dropFirst(6))).compactMap { g in Int(g[0]).map { (g[1], $0) } }
                } else if !t.hasPrefix("All zones:") && !t.hasPrefix("Zone ") {
                    r.notes.append(t)
                }
            case .table:
                guard let g = groups(rowRE, line), let count = Int(g[0]), let bytes = UInt64(g[1]) else {
                    if !t.isEmpty { sec = .body }
                    continue
                }
                let rest = g[3]
                let name: String, type: String, binary: String
                if let p = groups(restRE, rest) { (name, type, binary) = (p[0], p[1], p[2]) }
                else if let p = groups(nameBinaryRE, rest) { (name, type, binary) = (p[0], "", p[1]) }
                else { (name, type, binary) = (rest, "", "") }
                r.classes.append(HeapClass(id: r.classes.count, name: name, type: type, binary: binary, count: count,
                                           bytes: bytes, average: Double(g[2]) ?? 0))
            }
        }
        return r
    }

    /// Capture groups of every match.
    private static func matches(_ re: NSRegularExpression, _ s: String) -> [[String]] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
    }
}
