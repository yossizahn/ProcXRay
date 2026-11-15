import AppKit
import SwiftUI

/// Syntax coloring for SBPL: the `.sb` sources a profile was built from and the rules decoded from its compiled form.
///
/// Lexical classes (comments, strings, `#"regex"`, numbers, keywords) plus one bit of structure: `allow` and
/// `deny` are colored by verdict, bare symbols directly inside them are operations, and the head of any other
/// list is a filter or function call (`subpath`, `global-name`, a profile's own `define`s).
enum SandboxSyntax {
    enum Token: CaseIterable {
        case allow, deny, keyword, operation, head, string, regex, number, comment, paren
    }

    static let keywords: Set<String> = [
        "version", "import", "define", "default", "with", "with-filter", "param", "if", "when", "unless", "let",
        "let*", "lambda", "begin", "cond", "else", "and", "or", "not", "quote",
        "require-all", "require-any", "require-not",
    ]

    /// Dark mode uses the system colors; light mode uses darker shades, because systemGreen and systemOrange
    /// measure about 2.2:1 against a white text background, under the 4.5:1 that text needs.
    static func color(_ t: Token) -> NSColor { palette[t]! }

    private static let palette: [Token: NSColor] = [
        .allow: dynamic(light: 0x1A7F37, dark: .systemGreen),
        .deny: dynamic(light: 0xB42318, dark: .systemRed),
        .keyword: dynamic(light: 0x8250DF, dark: .systemPurple),
        .operation: .labelColor,
        .head: dynamic(light: 0x0550AE, dark: .systemBlue),
        .string: dynamic(light: 0xA04900, dark: .systemOrange),
        .regex: dynamic(light: 0xA8326E, dark: .systemPink),
        .number: dynamic(light: 0x7A5520, dark: .systemBrown),
        .comment: dynamic(light: 0x6E7781, dark: .secondaryLabelColor),
        .paren: .tertiaryLabelColor,      // deliberately faint
    ]

    private static func dynamic(light: UInt32, dark: NSColor) -> NSColor {
        let l = NSColor(srgbRed: CGFloat(light >> 16 & 0xFF) / 255, green: CGFloat(light >> 8 & 0xFF) / 255,
                        blue: CGFloat(light & 0xFF) / 255, alpha: 1)
        return NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : l }
    }

    /// Colored copy of `source` in an 11-pt (or `size`) monospaced font. Colors are dynamic, so they follow
    /// light/dark mode without re-highlighting.
    static func highlight(_ source: String, size: CGFloat = 11) -> NSAttributedString {
        let regular = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
        let out = NSMutableAttributedString(string: source, attributes: [.font: regular, .foregroundColor: NSColor.labelColor])
        for (range, t) in tokens(source) {
            out.addAttribute(.foregroundColor, value: color(t), range: range)
            if t == .allow || t == .deny || t == .operation { out.addAttribute(.font, value: bold, range: range) }
        }
        return out
    }

    /// The same coloring for a SwiftUI `Text` (which ignores AppKit attributes): colors only, the font is the Text's.
    static func attributed(_ source: String) -> AttributedString {
        var out = AttributedString(source)
        for (range, t) in tokens(source) where t != .operation {
            guard let r = Range(range, in: source),
                  let lo = AttributedString.Index(r.lowerBound, within: out),
                  let hi = AttributedString.Index(r.upperBound, within: out) else { continue }
            out[lo..<hi].foregroundColor = Color(nsColor: color(t))
            if t == .allow || t == .deny { out[lo..<hi].inlinePresentationIntent = .stronglyEmphasized }
        }
        return out
    }

    /// The colored spans of `source`, as UTF-16 ranges. Identifiers that aren't operations or heads are left out
    /// (they keep the default color).
    static func tokens(_ s: String) -> [(NSRange, Token)] {
        let u = Array(s.utf16)
        var out: [(NSRange, Token)] = []
        // One entry per open list: its head symbol (nil until seen, "" if the head isn't a symbol).
        var lists: [String?] = []
        var i = 0
        let n = u.count
        func isDelimiter(_ c: UInt16) -> Bool {
            c == 0x28 || c == 0x29 || c == 0x22 || c == 0x3B || c == 0x27 || c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
        }
        /// Marks the current list's head as taken by something that isn't a symbol.
        func nonSymbolElement() { if let last = lists.indices.last, lists[last] == nil { lists[last] = "" } }
        /// Index just past a string body starting at `j` (just after its opening quote).
        func stringEnd(_ j: Int) -> Int {
            var j = j
            while j < n {
                if u[j] == 0x5C { j += 2; continue }      // backslash escape
                if u[j] == 0x22 { return j + 1 }
                j += 1
            }
            return n
        }

        while i < n {
            let c = u[i]
            switch c {
            case 0x20, 0x09, 0x0A, 0x0D:
                i += 1
            case 0x3B:      // ; comment to end of line
                let start = i
                while i < n && u[i] != 0x0A { i += 1 }
                out.append((NSRange(location: start, length: i - start), .comment))
            case 0x22:      // "string"
                let start = i
                i = stringEnd(i + 1)
                out.append((NSRange(location: start, length: i - start), .string))
                nonSymbolElement()
            case 0x23 where i + 1 < n && u[i + 1] == 0x22:     // #"regex"
                let start = i
                i = stringEnd(i + 2)
                out.append((NSRange(location: start, length: i - start), .regex))
                nonSymbolElement()
            case 0x28:      // (
                nonSymbolElement()
                lists.append(nil)
                out.append((NSRange(location: i, length: 1), .paren))
                i += 1
            case 0x29:      // )
                if !lists.isEmpty { lists.removeLast() }
                out.append((NSRange(location: i, length: 1), .paren))
                i += 1
            case 0x27:      // ' quote
                out.append((NSRange(location: i, length: 1), .keyword))
                i += 1
            default:
                let start = i
                while i < n && !isDelimiter(u[i]) { i += 1 }
                let range = NSRange(location: start, length: i - start)
                let word = String(utf16CodeUnits: Array(u[start..<i]), count: i - start)
                let isHead = lists.last.map { $0 == nil } ?? false
                let parent = lists.last ?? nil
                if isHead { lists[lists.count - 1] = word }
                if let t = classify(word, isHead: isHead, parent: parent) { out.append((range, t)) }
            }
        }
        return out
    }

    private static func classify(_ w: String, isHead: Bool, parent: String?) -> Token? {
        if w == "allow" { return .allow }
        if w == "deny" { return .deny }
        if keywords.contains(w) { return .keyword }
        if w == "#t" || w == "#f" || isNumber(w) { return .number }
        if isHead { return .head }
        if parent == "allow" || parent == "deny" { return .operation }
        return nil
    }

    private static func isNumber(_ w: String) -> Bool {
        var s = Substring(w)
        if s.hasPrefix("#x") { s = s.dropFirst(2); return !s.isEmpty && s.allSatisfy(\.isHexDigit) }
        if s.hasPrefix("-") { s = s.dropFirst() }
        return !s.isEmpty && s.allSatisfy(\.isASCII) && s.allSatisfy(\.isNumber)
    }
}
