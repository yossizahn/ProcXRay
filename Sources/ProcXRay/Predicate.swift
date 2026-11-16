import Foundation

// A small filter language for the process list, compiled once into a closure:
//
//     cpu > 5 and not apple and not sandboxed
//     mem > 500MB or name ~ chrome
//     team in (UBF8T346G9, EQHXZ8M8AV) and started < 5m
//     path == "/Applications/*" and not (hardened or sandboxed)
//
// Grammar, loosest first: `or`/`||`, `and`/`&&`, `not`/`!`, then a field alone (true when it has a non-zero,
// non-empty value) or a comparison: `== != < <= > >=`, `~` (contains), `!~`, `matches` (regex), `in (…)`, each
// of the last three also after `not`. Text compares ignore case; `*` and `?` in an `==` string are wildcards.
// Values: numbers with units (500MB, 1.5GiB, 10s, 5m, 2h, 1k, 3M; KB/MB/GB are 1024-based, as the columns show
// them), "quoted" or bare strings, and true/false/yes/no. This file knows nothing about processes: fields come
// from the caller (see PredicateFields), so it builds and tests on its own.

struct PredicateError: Error, Equatable {
    var message: String
    /// Character offset in the source where the problem starts.
    var offset: Int
}

/// What a field holds for one row.
enum PredicateValue {
    /// Couldn't be read: every comparison is false (`—` in the column).
    case unknown
    /// Nothing to show (a blank cell): "" for text comparisons, false alone.
    case empty
    case number(Double)
    case text(String)
    /// Seconds since a time (the Started column): `started < 5m` is "started in the last 5 minutes".
    case age(Double)
}

/// The unit a field's numbers are in, which decides what a literal with a unit means against it.
enum PredicateUnit: Sendable { case plain, bytes, nanos, age }

struct PredicateField<Row> {
    var unit: PredicateUnit = .plain
    var value: (Row, Date) -> PredicateValue
    /// The value as shown, for a string against a number field (`hardened == platform`, `memLimit == none`).
    var display: (Row) -> String? = { _ in nil }
}

struct Predicate<Row> {
    let source: String
    /// The canonical names of the fields it reads.
    let fields: Set<String>
    let test: (Row, Date) -> Bool
}

enum PredicateCompiler {
    /// `resolve` maps a name as typed to the field's canonical name and accessors; `names` are offered as
    /// suggestions for a name it doesn't know. Returns nil for a blank source.
    static func compile<Row>(_ source: String, resolve: @escaping (String) -> (name: String, field: PredicateField<Row>)?,
                             names: [String] = []) throws -> Predicate<Row>? {
        let tokens = try lex(source)
        guard tokens.first?.kind != .end else { return nil }
        let p = Parser(tokens: tokens, resolve: resolve, names: names)
        let test = try p.parseOr()
        if p.peek.kind != .end {
            throw PredicateError(message: "expected “and”, “or” or the end, found “\(p.peek.text)”", offset: p.peek.offset)
        }
        return Predicate(source: source, fields: p.used, test: test)
    }

    // MARK: Tokens

    struct Token {
        enum Kind: Equatable { case word, number, string, op, lparen, rparen, comma, end }
        var kind: Kind
        var text: String
        var offset: Int
    }

    private static let ops = ["==", "!=", "<>", "<=", ">=", "&&", "||", "!~", "<", ">", "=", "~", "!"]

    static func lex(_ source: String) throws -> [Token] {
        let s = Array(source)
        var out: [Token] = []
        var i = 0
        func isWordStart(_ c: Character) -> Bool { c.isLetter || c == "_" || c == "/" || c == "*" || c == "." }
        func isWordChar(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || "_./*?-:+@".contains(c)
        }
        while i < s.count {
            let c = s[i]
            if c.isWhitespace { i += 1; continue }
            let start = i
            if c == "(" { out.append(Token(kind: .lparen, text: "(", offset: i)); i += 1; continue }
            if c == ")" { out.append(Token(kind: .rparen, text: ")", offset: i)); i += 1; continue }
            if c == "," { out.append(Token(kind: .comma, text: ",", offset: i)); i += 1; continue }
            if c == "\"" || c == "'" || c == "“" || c == "‘" {
                let close: Character = c == "“" ? "”" : c == "‘" ? "’" : c
                var text = ""
                i += 1
                while i < s.count, s[i] != close {
                    if s[i] == "\\", i + 1 < s.count { i += 1 }
                    text.append(s[i]); i += 1
                }
                guard i < s.count else { throw PredicateError(message: "this string has no closing quote", offset: start) }
                i += 1
                out.append(Token(kind: .string, text: text, offset: start))
                continue
            }
            if c.isNumber || (c == "-" && i + 1 < s.count && s[i + 1].isNumber) {
                i += 1
                while i < s.count, s[i].isNumber || s[i] == "." || s[i] == "_" { i += 1 }
                // The unit, glued on: 500MB, 10s, 5%, 2.5MB/s.
                while i < s.count, s[i].isLetter || s[i] == "%" || s[i] == "µ" { i += 1 }
                if i + 1 < s.count, s[i] == "/", s[i + 1] == "s" { i += 2 }
                // A bare word that starts with a digit ("3rdparty", a team ID): a word, not a number.
                if i < s.count, isWordChar(s[i]) {
                    while i < s.count, isWordChar(s[i]) { i += 1 }
                    out.append(Token(kind: .word, text: String(s[start..<i]), offset: start))
                } else {
                    out.append(Token(kind: .number, text: String(s[start..<i]), offset: start))
                }
                continue
            }
            if isWordStart(c) {
                while i < s.count, isWordChar(s[i]) { i += 1 }
                out.append(Token(kind: .word, text: String(s[start..<i]), offset: start))
                continue
            }
            if let op = ops.first(where: { op in
                op.count <= s.count - i && String(s[i..<(i + op.count)]) == op
            }) {
                out.append(Token(kind: .op, text: op, offset: i))
                i += op.count
                continue
            }
            throw PredicateError(message: "unexpected “\(c)”", offset: i)
        }
        out.append(Token(kind: .end, text: "the end", offset: s.count))
        return out
    }

    // MARK: Literals

    enum Literal {
        /// `scale`: a bare k/M/G/T (×1000ⁿ, or ×1024ⁿ against a size). `kind` is what the unit says it is.
        case number(Double, Kind, raw: String)
        case string(String)
        case bool(Bool)

        enum Kind { case plain, bytes, duration, scaled(base: Double, power: Int) }
    }

    private static let byteUnits: [String: Double] = [
        "b": 1, "kb": 1024, "kib": 1024, "mb": pow(1024, 2), "mib": pow(1024, 2), "gb": pow(1024, 3), "gib": pow(1024, 3),
        "tb": pow(1024, 4), "tib": pow(1024, 4),
    ]
    // Case-sensitive: "m" is minutes, "M" is mega.
    private static let durationUnits: [String: Double] = [
        "ns": 1e-9, "us": 1e-6, "µs": 1e-6, "ms": 1e-3, "s": 1, "sec": 1, "m": 60, "min": 60, "h": 3600, "hr": 3600, "d": 86400,
    ]
    private static let scaleUnits: [String: Int] = ["k": 1, "K": 1, "M": 2, "G": 3, "g": 3, "T": 4]
    /// Shown by the columns, no conversion: 5%, 0.5W, 10J.
    private static let plainUnits: Set<String> = ["", "%", "w", "W", "J", "j"]

    /// A number token; nil when its unit isn't one (then it's taken as a string).
    static func number(_ raw: String) -> Literal? {
        var unit = Substring(raw)
        if unit.hasSuffix("/s") { unit = unit.dropLast(2) }
        let digits = unit.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
        unit = unit.dropFirst(digits.count)
        guard let v = Double(digits.replacingOccurrences(of: "_", with: "")) else { return nil }
        let u = String(unit)
        if plainUnits.contains(u) { return .number(v, .plain, raw: raw) }
        if let m = durationUnits[u] { return .number(v * m, .duration, raw: raw) }
        if let p = scaleUnits[u] { return .number(v, .scaled(base: v, power: p), raw: raw) }
        if let m = byteUnits[u.lowercased()] { return .number(v * m, .bytes, raw: raw) }
        return nil
    }

    // MARK: Parser

    final class Parser<Row> {
        typealias Test = (Row, Date) -> Bool
        let tokens: [Token]
        var pos = 0
        let resolve: (String) -> (name: String, field: PredicateField<Row>)?
        let names: [String]
        var used: Set<String> = []

        init(tokens: [Token], resolve: @escaping (String) -> (name: String, field: PredicateField<Row>)?, names: [String]) {
            self.tokens = tokens; self.resolve = resolve; self.names = names
        }

        var peek: Token { tokens[pos] }
        func next() -> Token { defer { pos += 1 }; return tokens[pos] }
        func isWord(_ t: Token, _ w: String...) -> Bool { t.kind == .word && w.contains(t.text.lowercased()) }
        func isOp(_ t: Token, _ o: String...) -> Bool { t.kind == .op && o.contains(t.text) }

        func parseOr() throws -> Test {
            var l = try parseAnd()
            while isWord(peek, "or") || isOp(peek, "||") {
                _ = next()
                let a = l, b = try parseAnd()
                l = { a($0, $1) || b($0, $1) }
            }
            return l
        }

        func parseAnd() throws -> Test {
            var l = try parseNot()
            while isWord(peek, "and") || isOp(peek, "&&") {
                _ = next()
                let a = l, b = try parseNot()
                l = { a($0, $1) && b($0, $1) }
            }
            return l
        }

        func parseNot() throws -> Test {
            if isWord(peek, "not") || isOp(peek, "!") {
                _ = next()
                let a = try parseNot()
                return { !a($0, $1) }
            }
            return try parsePrimary()
        }

        func parsePrimary() throws -> Test {
            let t = next()
            switch t.kind {
            case .lparen:
                let e = try parseOr()
                guard peek.kind == .rparen else { throw PredicateError(message: "expected “)”", offset: peek.offset) }
                _ = next()
                return e
            case .word where !isWord(t, "and", "or", "in", "matches", "contains"):
                guard let (name, field) = resolve(t.text) else {
                    throw PredicateError(message: "no field called “\(t.text)”" + suggestion(t.text), offset: t.offset)
                }
                used.insert(name)
                return try parseComparison(name: name, field: field)
            case .end:
                throw PredicateError(message: "expected a field name, found the end", offset: t.offset)
            default:
                throw PredicateError(message: "expected a field name, found “\(t.text)”", offset: t.offset)
            }
        }

        private func suggestion(_ typed: String) -> String {
            let t = typed.lowercased()
            let hits = names.filter { $0.lowercased().hasPrefix(t) || $0.lowercased().contains(t) || t.contains($0.lowercased()) }
            guard !hits.isEmpty else { return "" }
            return " (did you mean " + hits.prefix(3).map { "“\($0)”" }.joined(separator: ", ") + "?)"
        }

        enum Op { case eq, ne, lt, le, gt, ge, contains, matches, isIn }

        func parseComparison(name: String, field: PredicateField<Row>) throws -> Test {
            var negate = false
            let opTok = peek
            let op: Op
            if opTok.kind == .op {
                switch opTok.text {
                case "==", "=": op = .eq
                case "!=", "<>": op = .ne
                case "<": op = .lt
                case "<=": op = .le
                case ">": op = .gt
                case ">=": op = .ge
                case "~": op = .contains
                case "!~": op = .contains; negate = true
                default: return truthy(field)
                }
                _ = next()
            } else if isWord(opTok, "in", "matches", "contains", "not") {
                if isWord(opTok, "not") {
                    // `not` right after a field negates the comparison that follows (`team not in (…)`).
                    let after = tokens[pos + 1]
                    guard isWord(after, "in", "matches", "contains") || isOp(after, "~") else { return truthy(field) }
                    _ = next()
                    negate = true
                }
                let w = next()
                op = isOp(w, "~") || isWord(w, "contains") ? .contains : isWord(w, "matches") ? .matches : .isIn
            } else {
                return truthy(field)
            }
            let test: Test
            if op == .isIn {
                guard peek.kind == .lparen else { throw PredicateError(message: "expected “(” and a list after “in”", offset: peek.offset) }
                _ = next()
                var tests: [Test] = []
                repeat {
                    let lt = peek
                    let lit = try literal()
                    tests.append(try compare(name, field, .eq, lit, at: lt)!)
                    if peek.kind == .comma { _ = next() } else { break }
                } while true
                guard peek.kind == .rparen else { throw PredicateError(message: "expected “,” or “)”", offset: peek.offset) }
                _ = next()
                test = { r, now in tests.contains { $0(r, now) } }
            } else {
                let lt = peek
                let lit = try literal()
                test = try compare(name, field, op, lit, at: lt)!
            }
            guard negate else { return test }
            // `!~` and `not in` are false for an unreadable value, as `!=` is.
            return { r, now in
                if case .unknown = field.value(r, now) { return false }
                return !test(r, now)
            }
        }

        func literal() throws -> Literal {
            let t = next()
            switch t.kind {
            case .string: return .string(t.text)
            case .number: return PredicateCompiler.number(t.text) ?? .string(t.text)
            case .word:
                switch t.text.lowercased() {
                case "true", "yes": return .bool(true)
                case "false", "no": return .bool(false)
                default: return .string(t.text)
                }
            case .end: throw PredicateError(message: "expected a value, found the end", offset: t.offset)
            default: throw PredicateError(message: "expected a value, found “\(t.text)”", offset: t.offset)
            }
        }

        func truthy(_ field: PredicateField<Row>) -> Test {
            { r, now in Self.truth(field.value(r, now)) ?? false }
        }

        static func truth(_ v: PredicateValue) -> Bool? {
            switch v {
            case .unknown: nil
            case .empty: false
            case .number(let x): x != 0
            case .text(let s): !s.isEmpty
            case .age: true
            }
        }

        /// The literal as a number in the field's unit; nil when it isn't a number. Throws on a unit that
        /// doesn't fit the field (a size against a time).
        func amount(_ name: String, _ unit: PredicateUnit, _ lit: Literal, at t: Token) throws -> Double? {
            guard case .number(let v, let kind, let raw) = lit else { return nil }
            func wrong(_ what: String) -> PredicateError {
                PredicateError(message: "“\(raw)” is \(what), but \(name) isn't", offset: t.offset)
            }
            switch (unit, kind) {
            case (_, .plain): return unit == .nanos ? v * 1e9 : v
            case (.bytes, .bytes): return v
            case (.bytes, .scaled(let b, let p)): return b * pow(1024, Double(p))
            case (.plain, .scaled(let b, let p)): return b * pow(1000, Double(p))
            case (.nanos, .duration): return v * 1e9
            case (.age, .duration): return v
            case (_, .bytes): throw wrong("a size")
            case (.bytes, .duration):
                throw PredicateError(message: "“\(raw)” is a time, but \(name) is a size (sizes take KB, MB, GB)", offset: t.offset)
            case (_, .duration): throw wrong("a time")
            case (_, .scaled): throw wrong("a count")
            }
        }

        func compare(_ name: String, _ field: PredicateField<Row>, _ op: Op, _ lit: Literal, at t: Token) throws -> Test? {
            let value = field.value, display = field.display
            /// The value as text: what a string is compared with.
            func text(_ r: Row, _ now: Date) -> String? {
                switch value(r, now) {
                case .unknown: nil
                case .empty: ""
                case .text(let s): s
                case .number, .age: display(r) ?? ""
                }
            }
            switch op {
            case .lt, .le, .gt, .ge:
                guard let n = try amount(name, field.unit, lit, at: t) else {
                    throw PredicateError(message: "\(op == .lt ? "<" : op == .le ? "<=" : op == .gt ? ">" : ">=") needs a number", offset: t.offset)
                }
                let cmp: (Double) -> Bool = switch op {
                case .lt: { $0 < n }
                case .le: { $0 <= n }
                case .gt: { $0 > n }
                default: { $0 >= n }
                }
                return { r, now in
                    switch value(r, now) {
                    case .number(let x), .age(let x): cmp(x)
                    default: false
                    }
                }
            case .eq, .ne:
                let eq: (Row, Date) -> Bool?
                if case .bool(let b) = lit {
                    eq = { r, now in Self.truth(value(r, now)).map { $0 == b } }
                } else if let n = try amount(name, field.unit, lit, at: t) {
                    let raw: String = if case .number(_, _, let raw) = lit { raw } else { "" }
                    eq = { r, now in
                        switch value(r, now) {
                        case .unknown: nil
                        case .number(let x), .age(let x): x == n
                        case .empty: false
                        // A text cell holding a number ("1234" in a text column) or the literal as typed.
                        case .text(let s): Double(s) == n || s.caseInsensitiveCompare(raw) == .orderedSame
                        }
                    }
                } else {
                    guard case .string(let s) = lit else { return nil }
                    let match = Self.textMatcher(s)
                    eq = { r, now in text(r, now).map(match) }
                }
                return op == .eq ? { eq($0, $1) ?? false } : { eq($0, $1).map(!) ?? false }
            case .contains:
                let s = Self.string(lit)
                return { r, now in text(r, now).map { $0.range(of: s, options: .caseInsensitive) != nil } ?? false }
            case .matches:
                let s = Self.string(lit)
                let re: NSRegularExpression
                do { re = try NSRegularExpression(pattern: s, options: [.caseInsensitive]) } catch {
                    throw PredicateError(message: "“\(s)” isn't a valid regular expression", offset: t.offset)
                }
                return { r, now in
                    guard let v = text(r, now) else { return false }
                    return re.firstMatch(in: v, range: NSRange(v.startIndex..., in: v)) != nil
                }
            case .isIn:
                return nil
            }
        }

        static func string(_ lit: Literal) -> String {
            switch lit {
            case .string(let s): s
            case .number(_, _, let raw): raw
            case .bool(let b): b ? "true" : "false"
            }
        }

        /// Case-insensitive equality, or a wildcard match when the string has `*` or `?`.
        static func textMatcher(_ pattern: String) -> (String) -> Bool {
            guard pattern.contains("*") || pattern.contains("?") else {
                return { $0.caseInsensitiveCompare(pattern) == .orderedSame }
            }
            return { s in fnmatch(pattern, s, FNM_CASEFOLD) == 0 }
        }
    }
}

// MARK: - Clauses: chips add and remove parts of a predicate

extension PredicateCompiler {
    /// The predicate split at its top-level `and`s, each part as typed. A predicate with a top-level `or` is one
    /// part. nil when it doesn't lex.
    static func clauses(_ source: String) -> [String]? {
        guard let tokens = try? lex(source) else { return nil }
        let chars = Array(source)
        if hasTopLevelOr(tokens) {
            let s = source.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? [] : [s]
        }
        var parts: [String] = []
        var depth = 0, start = 0
        for t in tokens {
            switch t.kind {
            case .lparen: depth += 1
            case .rparen: depth -= 1
            case .end:
                parts.append(String(chars[start..<t.offset]))
            default:
                if depth == 0, (t.kind == .word && t.text.lowercased() == "and") || (t.kind == .op && t.text == "&&") {
                    parts.append(String(chars[start..<t.offset]))
                    start = t.offset + t.text.count
                }
            }
        }
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func hasTopLevelOr(_ tokens: [Token]) -> Bool {
        var depth = 0
        for t in tokens {
            if t.kind == .lparen { depth += 1 } else if t.kind == .rparen { depth -= 1 }
            if depth == 0, (t.kind == .word && t.text.lowercased() == "or") || (t.kind == .op && t.text == "||") { return true }
        }
        return false
    }

    /// A clause in a form that ignores spacing, case and parentheses around the whole: "started<5m" and
    /// "(Started < 5m)" are the same clause.
    static func normalized(_ clause: String) -> String {
        guard var tokens = try? lex(clause) else { return clause.lowercased() }
        tokens.removeLast()   // .end
        while tokens.first?.kind == .lparen, tokens.last?.kind == .rparen {
            // Only when the first "(" closes at the very end: not "(a) or (b)".
            var depth = 0, closesAtEnd = true
            for (i, t) in tokens.enumerated() {
                if t.kind == .lparen { depth += 1 } else if t.kind == .rparen { depth -= 1 }
                if depth == 0, i < tokens.count - 1 { closesAtEnd = false; break }
            }
            guard closesAtEnd else { break }
            tokens = Array(tokens.dropFirst().dropLast())
        }
        return tokens.map { ($0.kind == .string ? "\"\($0.text)\"" : $0.text).lowercased() }.joined(separator: " ")
    }

    /// Whether every top-level clause of `chip` is one of `source`'s: the chip "uid == 0 and not apple" is on
    /// in "cpu > 5 and not apple and uid == 0".
    static func contains(_ source: String, clause chip: String) -> Bool {
        let have = Set((clauses(source) ?? []).map(normalized))
        let want = (clauses(chip) ?? [chip]).map(normalized)
        return !want.isEmpty && want.allSatisfy(have.contains)
    }

    /// `source` with `chip`'s clauses taken out if it has them all, else with the missing ones added with `and`.
    static func toggling(_ chip: String, in source: String) -> String {
        var parts = clauses(source) ?? [source.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
        let mine = clauses(chip) ?? [chip]
        let keys = Set(mine.map(normalized))
        if contains(source, clause: chip) {
            parts.removeAll { keys.contains(normalized($0)) }
        } else {
            let have = Set(parts.map(normalized))
            parts += mine.filter { !have.contains(normalized($0)) }
        }
        // A part with an `or` of its own needs parentheses once it's joined with `and`.
        return parts.map { p in
            parts.count > 1 && (try? lex(p)).map(hasTopLevelOr) == true ? "(\(p))" : p
        }.joined(separator: " and ")
    }
}
