import Foundation

/// A compiled sandbox profile (the bytes `sandbox_compile_*` produce and secinitd caches), parsed.
///
/// Layout, worked out on macOS 27.2 by compiling known SBPL with libsandbox and diffing the output, and checked
/// by decoding every cached profile on a Mac (347 compiled by this libsandbox, all decode) and recompiling the
/// decoded rules (see `SandboxRules.verify`):
///
///     u16 flags            0 for App Sandbox profiles; 0x4000/0x2000 when message filters are used
///     u16 node count
///     u8  operation count  (204 here)
///     u8  variable count   names used as ${…} inside patterns, e.g. any_uuid
///     u8  state-flag count
///     u8  0, u16 0, u16 0
///     u16 regex count
///     u16 message-filter count
///     u16 regex[], variable[], state-flag[], message-filter[], operation[]   (the last two are node indices,
///                                                                            the others data offsets)
///     padding to 8
///     node[count]          8 bytes each
///     data                 offsets into it are in units of 8 bytes
///
/// A node is either a test, `00 filter u16 argument u16 if-matched u16 if-not`, where bit 7 of `filter` means the
/// argument is a regex index; or a decision, `01 u16 flags u8 (bit 7: has a modifier) u8 modifier u8 op u16 arg`.
/// Bit 0 of a decision's flags is deny; the other bits belong to flag modifiers (report = 4, …), per libsandbox's
/// modifier table. A data item is `u16 length` then the bytes, except network addresses (4 bytes, no length).
struct CompiledSandboxProfile {
    enum Node {
        case test(filter: Int, regex: Bool, arg: Int, match: Int, unmatch: Int)
        case decision(flags: UInt16, modifier: Int?, modifierOp: Int, modifierArg: Int)
    }
    struct ParseError: Error, CustomStringConvertible { let description: String }

    let bytes: [UInt8]
    let flags: UInt16
    let operationCount: Int
    let regexOffsets: [Int]
    let variableOffsets: [Int]
    let stateOffsets: [Int]
    let messageFilterRoots: [Int]
    let operationRoots: [Int]
    let nodes: [Node]
    let dataStart: Int

    init(_ data: Data) throws {
        let b = [UInt8](data)
        bytes = b
        func u16(_ o: Int) throws -> Int {
            guard o + 2 <= b.count else { throw ParseError(description: "truncated at \(o)") }
            return Int(b[o]) | Int(b[o + 1]) << 8
        }
        guard b.count >= 16 else { throw ParseError(description: "too short (\(b.count) bytes)") }
        flags = UInt16(try u16(0))
        let nodeCount = try u16(2)
        operationCount = Int(b[4])
        let varCount = Int(b[5]), stateCount = Int(b[6])
        let regexCount = try u16(12), msgCount = try u16(14)
        guard b[7] == 0, try u16(8) == 0, try u16(10) == 0 else {
            throw ParseError(description: "header fields this decoder doesn't know are set (older or newer format)")
        }
        var o = 16
        func table(_ n: Int) throws -> [Int] {
            var r: [Int] = []; r.reserveCapacity(n)
            for i in 0..<n { r.append(try u16(o + 2 * i)) }
            o += 2 * n
            return r
        }
        regexOffsets = try table(regexCount)
        variableOffsets = try table(varCount)
        stateOffsets = try table(stateCount)
        messageFilterRoots = try table(msgCount)
        operationRoots = try table(operationCount)
        let nodesStart = (o + 7) & ~7
        dataStart = nodesStart + 8 * nodeCount
        guard dataStart <= b.count else { throw ParseError(description: "\(nodeCount) nodes don't fit in \(b.count) bytes") }
        var ns: [Node] = []; ns.reserveCapacity(nodeCount)
        for i in 0..<nodeCount {
            let p = nodesStart + 8 * i
            switch b[p] {
            case 0:
                let m = try u16(p + 4), u = try u16(p + 6)
                guard m < nodeCount, u < nodeCount else { throw ParseError(description: "node \(i) points past the end") }
                ns.append(.test(filter: Int(b[p + 1] & 0x7f), regex: b[p + 1] & 0x80 != 0, arg: try u16(p + 2), match: m, unmatch: u))
            case 1:
                let hasMod = b[p + 3] & 0x80 != 0
                ns.append(.decision(flags: UInt16(b[p + 1]) | UInt16(b[p + 2]) << 8, modifier: hasMod ? Int(b[p + 4]) : nil,
                                    modifierOp: Int(b[p + 5]), modifierArg: try u16(p + 6)))
            default:
                throw ParseError(description: "node \(i) has unknown kind \(b[p])")
            }
        }
        nodes = ns
        for r in operationRoots + messageFilterRoots where r >= nodeCount {
            throw ParseError(description: "an operation points past the last node")
        }
    }

    /// The data item at `offset` (in 8-byte units): its length-prefixed bytes.
    func item(_ offset: Int) -> ArraySlice<UInt8>? {
        let o = dataStart + 8 * offset
        guard o + 2 <= bytes.count else { return nil }
        let n = Int(bytes[o]) | Int(bytes[o + 1]) << 8
        guard o + 2 + n <= bytes.count else { return nil }
        return bytes[(o + 2)..<(o + 2 + n)]
    }

    /// A NUL-terminated string item.
    func string(_ offset: Int) -> String? {
        guard let s = item(offset) else { return nil }
        return String(decoding: s.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// The fixed 4 bytes of a network-address argument (no length prefix).
    func raw(_ offset: Int, count: Int) -> ArraySlice<UInt8>? {
        let o = dataStart + 8 * offset
        guard o + count <= bytes.count else { return nil }
        return bytes[o..<(o + count)]
    }

    var variables: [String] { variableOffsets.map { string($0) ?? "?" } }
}

// MARK: - Pattern programs

/// The matcher libsandbox compiles string and path filters into (literals, prefixes, subpaths and simple regexes,
/// several filters of one kind merged into one program).
///
/// A program is a run of (atom, terminator) pairs. Atoms: `0x40|n` a literal of n+1 bytes, `04 n` a literal of
/// n+65 bytes, `00` end of string, `02 c` "[^c]*c", `03 c` ".*c", `0b f ranges…` a byte class (f & 0x7f + 1
/// ranges; with f & 0x80 it's a "class*" loop fused to the next atom), `0x10+k` the k-th ${variable}.
/// Terminators: `0f` go on; `0x80|n` go on, and if the atom fails jump n+1 bytes past the terminator; `08 u16`
/// the same with a distance of u16+129. Other instructions: `0a` accept (whatever follows), `06` save the input
/// position, `05` restore it.
enum SandboxPattern {
    enum Atom: Equatable {
        case literal([UInt8])
        case end
        case regex(String)          // a piece that's only expressible as a regex
        case variable(String)
    }
    struct Alternative: Equatable {
        var atoms: [Atom]
        /// The program accepts anything after these atoms (no end-of-string test).
        var open: Bool
    }
    struct DecodeError: Error, CustomStringConvertible { let description: String }

    static func decode(_ code: ArraySlice<UInt8>, variables: [String], limit: Int = 20000) throws -> [Alternative] {
        let c = Array(code)
        var out: [Alternative] = []
        func atom(_ i: Int) throws -> (Atom, Int) {
            guard i < c.count else { throw DecodeError(description: "ran off the end") }
            let op = c[i]
            switch op {
            case 0x40...0x7f:
                let n = Int(op & 0x3f) + 1
                guard i + 1 + n <= c.count else { throw DecodeError(description: "literal past the end") }
                return (.literal(Array(c[(i + 1)..<(i + 1 + n)])), i + 1 + n)
            case 0x04:
                guard i + 1 < c.count else { throw DecodeError(description: "literal past the end") }
                let n = Int(c[i + 1]) + 65
                guard i + 2 + n <= c.count else { throw DecodeError(description: "literal past the end") }
                return (.literal(Array(c[(i + 2)..<(i + 2 + n)])), i + 2 + n)
            case 0x00: return (.end, i + 1)
            case 0x02:
                guard i + 1 < c.count else { throw DecodeError(description: "ran off the end") }
                let ch = c[i + 1]
                return (.regex("[^\(RegexText.escape(ch, inClass: true))]*\(RegexText.escape(ch))"), i + 2)
            case 0x03:
                guard i + 1 < c.count else { throw DecodeError(description: "ran off the end") }
                return (.regex(".*" + RegexText.escape(c[i + 1])), i + 2)
            case 0x10...0x1f:
                let k = Int(op - 0x10)
                return (.variable(k < variables.count ? variables[k] : "var\(k)"), i + 1)
            case 0x0b:
                guard i + 1 < c.count else { throw DecodeError(description: "ran off the end") }
                let f = c[i + 1], n = Int(f & 0x7f) + 1
                guard i + 2 + 2 * n <= c.count else { throw DecodeError(description: "class past the end") }
                var set = [Bool](repeating: false, count: 256)
                for k in 0..<n {
                    let lo = Int(c[i + 2 + 2 * k]), hi = Int(c[i + 3 + 2 * k])
                    if lo <= hi { for x in lo...hi { set[x] = true } }
                }
                let cls = RegexText.charClass(set)
                let j = i + 2 + 2 * n
                if f & 0x80 != 0 {
                    let (next, k) = try atom(j)
                    return (.regex(cls + "*" + RegexText.text(of: next)), k)
                }
                return (.regex(cls), j)
            default:
                throw DecodeError(description: String(format: "unknown pattern instruction %02x at %d", op, i))
            }
        }
        func walk(_ start: Int, _ startPath: [Atom], _ startMarks: [[Atom]], depth: Int) throws {
            guard depth < 2000 else { throw DecodeError(description: "too deep") }
            var i = start, path = startPath, marks = startMarks
            while true {
                guard out.count <= limit else { throw DecodeError(description: "more than \(limit) alternatives") }
                guard i < c.count else { throw DecodeError(description: "ran off the end") }
                switch c[i] {
                case 0x0a: out.append(Alternative(atoms: path, open: true)); return
                case 0x06: marks.append(path); i += 1; continue
                case 0x05:
                    guard let m = marks.last else { throw DecodeError(description: "restore without a saved position") }
                    path = m; i += 1; continue
                default: break
                }
                let (a, j) = try atom(i)
                guard j < c.count else { throw DecodeError(description: "ran off the end") }
                let t = c[j]
                i = j + 1
                if t == 0x0f {
                } else if t & 0x80 != 0 {
                    try walk(i + Int(t & 0x7f) + 1, path, marks, depth: depth + 1)
                } else if t == 0x08 {
                    guard i + 2 <= c.count else { throw DecodeError(description: "ran off the end") }
                    let d = Int(c[i]) | Int(c[i + 1]) << 8
                    i += 2
                    try walk(i + d + 129, path, marks, depth: depth + 1)
                } else {
                    throw DecodeError(description: String(format: "unknown terminator %02x at %d", t, j))
                }
                if case .end = a, i < c.count, c[i] == 0x0a { out.append(Alternative(atoms: path, open: false)); return }
                path.append(a)
            }
        }
        try walk(0, [], [], depth: 0)
        return out
    }
}

/// Regex text helpers shared by both matchers.
enum RegexText {
    static func escape(_ c: UInt8, inClass: Bool = false) -> String {
        if c < 0x20 || c >= 0x7f { return String(format: "\\x%02x", c) }
        let s = String(UnicodeScalar(c))
        if inClass { return "]\\^-".contains(s) ? "\\" + s : s }
        return ".^$|()[]{}*+?\\".contains(s) ? "\\" + s : s
    }
    static func literal(_ b: [UInt8]) -> String { b.map { escape($0) }.joined() }

    /// The shortest of `.`, a single character, `[…]` or `[^…]` for a set of bytes.
    static func charClass(_ set: [Bool]) -> String {
        func runs(_ want: Bool) -> [(Int, Int)] {
            var r: [(Int, Int)] = []; var c = 0
            while c < 256 {
                if set[c] == want {
                    let s = c
                    while c + 1 < 256 && set[c + 1] == want { c += 1 }
                    r.append((s, c))
                }
                c += 1
            }
            return r
        }
        let pos = runs(true), neg = runs(false)
        if neg.isEmpty { return "." }
        if pos.count == 1 && pos[0].0 == pos[0].1 { return escape(UInt8(pos[0].0)) }
        func body(_ rr: [(Int, Int)]) -> String {
            rr.map { a, b in
                a == b ? escape(UInt8(a), inClass: true)
                    : escape(UInt8(a), inClass: true) + (b == a + 1 ? "" : "-") + escape(UInt8(b), inClass: true)
            }.joined()
        }
        return neg.count < pos.count ? "[^" + body(neg) + "]" : "[" + body(pos) + "]"
    }

    static func text(of a: SandboxPattern.Atom) -> String {
        switch a {
        case .literal(let b): literal(b)
        case .end: "$"
        case .regex(let r): r
        case .variable(let v): "${" + v + "}"
        }
    }
}

// MARK: - AppleMatch regexes

/// The NFA form libsandbox falls back to for regexes its pattern matcher can't express (AppleMatch, version 3).
///
/// Item: `00 00 00 03`, u16 code length, code. Instructions: `02 c` a byte, `09` any byte, `19` ^, `29` $,
/// `n<<4|0b` a class of n (lo, hi) ranges (lo > hi+1 wraps around: everything but hi+1…lo-1; lo == hi+1 is
/// empty), `2f u16` split (go on, or jump), `0a u16` jump, `15 00` match. Jump targets are code offsets.
/// The compiler lays loops and alternations out in a fixed (Thompson) shape, which `decompile` recognises.
/// Measured: all 699 distinct regexes in this Mac's cached profiles decompile to text that recompiles to the
/// same bytes.
enum AppleMatch {
    struct DecodeError: Error, CustomStringConvertible { let description: String }

    private enum Ins { case atom(String), split(Int), jump(Int), match, nop }

    static func decode(item: ArraySlice<UInt8>) throws -> String {
        let b = Array(item)
        guard b.count >= 6, b[0] == 0, b[1] == 0, b[2] == 0, b[3] == 3 else {
            throw DecodeError(description: "unknown regex header")
        }
        let n = Int(b[4]) | Int(b[5]) << 8
        guard 6 + n <= b.count else { throw DecodeError(description: "regex past the end") }
        return try decompile(Array(b[6..<(6 + n)]))
    }

    static func decompile(_ code: [UInt8]) throws -> String {
        var ins: [Int: (Ins, Int)] = [:]
        var pc = 0
        while pc < code.count {
            let op = code[pc]
            func need(_ k: Int) throws { if pc + k > code.count { throw DecodeError(description: "instruction past the end") } }
            switch op {
            case 0x02: try need(2); ins[pc] = (.atom(RegexText.escape(code[pc + 1])), pc + 2)
            case 0x09: ins[pc] = (.atom("."), pc + 1)
            case 0x19: ins[pc] = (.atom("^"), pc + 1)
            case 0x29: ins[pc] = (.atom("$"), pc + 1)
            case 0x2f: try need(3); ins[pc] = (.split(Int(code[pc + 1]) | Int(code[pc + 2]) << 8), pc + 3)
            case 0x0a: try need(3); ins[pc] = (.jump(Int(code[pc + 1]) | Int(code[pc + 2]) << 8), pc + 3)
            case 0x15: ins[pc] = (.match, pc + 2)
            case 0x00: ins[pc] = (.nop, pc + 1)
            default:
                guard op & 0x0f == 0x0b else { throw DecodeError(description: String(format: "unknown regex instruction %02x", op)) }
                let k = Int(op >> 4)
                try need(1 + 2 * k)
                var set = [Bool](repeating: false, count: 256)
                for r in 0..<k {
                    let lo = Int(code[pc + 1 + 2 * r]), hi = Int(code[pc + 2 + 2 * r])
                    if lo <= hi { for x in lo...hi { set[x] = true } }
                    else if lo > hi + 1 { for x in lo..<256 { set[x] = true }; for x in 0...hi { set[x] = true } }
                }
                ins[pc] = (.atom(RegexText.charClass(set)), pc + 1 + 2 * k)
            }
            pc = ins[pc]!.1
        }

        enum End { case stop, match, join(Int) }
        var budget = 200_000
        func seq(_ start: Int, stop: Int?, window: (Int, Int)?, depth: Int) throws -> ([String], End) {
            guard depth < 300 else { throw DecodeError(description: "too deep") }
            var parts: [String] = [], starts: [Int] = []
            var pc = start
            func wrapPlus(_ back: Int) -> Bool {
                guard let i0 = starts.firstIndex(where: { $0 >= back }), starts[i0] == back else { return false }
                let body = Array(parts[i0...])
                parts.removeSubrange(i0...); starts.removeSubrange(i0...)
                parts.append(group(body) + "+"); starts.append(back)
                return true
            }
            while true {
                budget -= 1
                guard budget > 0 else { throw DecodeError(description: "too complex") }
                if pc == stop { return (parts, .stop) }
                guard let (i, next) = ins[pc] else { throw DecodeError(description: "jump to \(pc), not an instruction") }
                switch i {
                case .nop: pc = next
                case .match: return (parts, .match)
                case .atom(let a): starts.append(pc); parts.append(a); pc = next
                case .jump(let t):
                    if t == stop { return (parts, .stop) }
                    if let w = window, w.0 < t, t < w.1 { return (parts, .join(t)) }
                    guard t > pc else { throw DecodeError(description: "unexpected backward jump at \(pc)") }
                    pc = t
                case .split(let t):
                    let f = next
                    // x+: the fall-through jumps back to code already emitted (or the split itself does)
                    if case .jump(let back)? = ins[f]?.0, back < pc, wrapPlus(back) { pc = t; continue }
                    if t < pc, wrapPlus(t) { pc = f; continue }
                    // x*: one branch loops back to this split
                    var star = false
                    for (body, cont) in [(f, t), (t, f)] {
                        if let (bp, end) = try? seq(body, stop: pc, window: nil, depth: depth + 1), case .stop = end {
                            starts.append(pc); parts.append(group(bp) + "*"); pc = cont; star = true; break
                        }
                    }
                    if star { continue }
                    // x?: the fall-through rejoins at the target
                    if let (bp, end) = try? seq(f, stop: t, window: nil, depth: depth + 1), case .stop = end {
                        starts.append(pc); parts.append(group(bp) + "?"); pc = t; continue
                    }
                    // a|b: the out-of-line branch jumps back to where the inline one ends
                    let (bpB, endB) = try seq(t, stop: nil, window: (pc, t), depth: depth + 1)
                    switch endB {
                    case .join(let x):
                        let (bpA, endA) = try seq(f, stop: x, window: nil, depth: depth + 1)
                        guard case .stop = endA else { throw DecodeError(description: "alternation doesn't rejoin at \(pc)") }
                        starts.append(pc); parts.append("(" + (alternatives(bpA) + alternatives(bpB)).joined(separator: "|") + ")")
                        pc = x
                    case .match:
                        let (bpA, endA) = try seq(f, stop: nil, window: nil, depth: depth + 1)
                        guard case .match = endA else { throw DecodeError(description: "alternation ends differently at \(pc)") }
                        starts.append(pc); parts.append("(" + (alternatives(bpA) + alternatives(bpB)).joined(separator: "|") + ")")
                        return (parts, .match)
                    case .stop:
                        throw DecodeError(description: "unrecognised split at \(pc)")
                    }
                }
            }
        }
        var s = try seq(0, stop: nil, window: nil, depth: 0).0.joined()
        // An unanchored regex starts with the compiler's own .* loop; it's implied.
        if s.hasPrefix(".*") { s.removeFirst(2) }
        return s
    }

    private static func isAtomic(_ s: String) -> Bool {
        let c = Array(s)
        if c.count == 1 || (c.count == 2 && c[0] == "\\") { return true }
        if c.count == 4 && s.hasPrefix("\\x") { return true }
        if c.first == "[" && c.last == "]" {
            // one bracket expression, not "[a][b]"
            var i = 1
            while i < c.count - 1 { if c[i] == "\\" { i += 2; continue }; if c[i] == "]" { return false }; i += 1 }
            return true
        }
        if c.first == "(" && c.last == ")" { return closesAtEnd(c) }
        return false
    }
    private static func closesAtEnd(_ c: [Character]) -> Bool {
        var d = 0, i = 0
        while i < c.count {
            if c[i] == "\\" { i += 2; continue }
            if c[i] == "(" { d += 1 } else if c[i] == ")" { d -= 1; if d == 0 && i != c.count - 1 { return false } }
            i += 1
        }
        return d == 0
    }
    private static func group(_ parts: [String]) -> String {
        let s = parts.joined()
        return isAtomic(s) ? s : "(" + s + ")"
    }
    private static func splitTop(_ s: String) -> [String] {
        var out: [String] = [], cur = "", d = 0
        let c = Array(s); var i = 0
        while i < c.count {
            if c[i] == "\\", i + 1 < c.count { cur.append(c[i]); cur.append(c[i + 1]); i += 2; continue }
            if c[i] == "(" { d += 1 } else if c[i] == ")" { d -= 1 }
            if c[i] == "|" && d == 0 { out.append(cur); cur = "" } else { cur.append(c[i]) }
            i += 1
        }
        out.append(cur)
        return out
    }
    /// The branches of one side of an alternation, flattening a nested (a|b).
    private static func alternatives(_ parts: [String]) -> [String] {
        let s = parts.joined()
        if parts.count == 1, s.hasPrefix("("), s.hasSuffix(")"), closesAtEnd(Array(s)) {
            let inner = splitTop(String(s.dropFirst().dropLast()))
            if inner.count > 1 { return inner }
        }
        return [s]
    }
}
