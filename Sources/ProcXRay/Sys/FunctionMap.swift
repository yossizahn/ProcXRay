import Foundation

/// Names for the functions of a binary with no symbols for them (a stripped app), from what stripping leaves:
///   - Objective-C method lists, which the runtime needs and so survive: a method's implementation is named
///     exactly, "-[Class selector]" ("+[…]" for a class method), Swift @objc methods included.
///   - LC_FUNCTION_STARTS: where each function begins, so every place in one function gets one name ("fn_a2900c"):
///     the property reads BetterDisplay makes from five places in one function are one function's, not five.
///   - What the function's code refers to, as a hint after that name. ADRP + ADD (or LDR) pairs are followed into
///     the string sections, and through one pointer in constant data:
///       · a Rust panic location (the file as a pointer and length, then line and column), which nearly every
///         Rust function that can panic refers to: "tauri-2.1.0/src/window.rs:142";
///       · a log message or other string, the first that reads like a sentence: BetterDisplay's fn_cf604
///         refers to " Sample console availability", C++ assertions to their whole function's name;
///       · an Objective-C selector the code sends ("setFrame:display:").
///     Swift's long string literals point 32 bytes before their text. Pointers in data are in the binary's
///     chained-fixup form: the target is read from the low bits, as an address or an offset from __TEXT.
/// arm64 only (the slice that runs here); a Rosetta process's x86_64 code gets no names from it.
final class FunctionMap: @unchecked Sendable {
    private let file: MappedFile
    private let slice: Int
    /// Function starts, as offsets from __TEXT's start (what a frame's offset into its image is).
    private let starts: [UInt64]
    private let textVM: UInt64
    private let code: MachOSection
    private let strings: [MachOSection]
    private let selectorNames: MachOSection?
    /// Sections holding data a pointer can be read from (not the code, not zero-filled).
    private let data: [MachOSection]
    /// Objective-C method implementations (offset from __TEXT's start) → "-[Class selector]".
    private var methods: [UInt64: String] = [:]
    private let lock = NSLock()
    private var names: [UInt64: String] = [:]

    init?(path: String) {
        let f = MachOParser.load(path: path)
        guard let mapped = f.mapped, f.slices.indices.contains(f.defaultSlice) else { return nil }
        let s = f.slices[f.defaultSlice]
        guard let img = s.image, img.is64, !img.swapped, img.cputype == 0x0100_000C,
              let text = img.segments.first(where: { $0.name == "__TEXT" }),
              let code = img.section("__TEXT", "__text"),
              let lc = img.commands.first(where: { $0.cmd == 0x26 }) else { return nil }   // LC_FUNCTION_STARTS
        file = mapped
        slice = s.offset
        textVM = text.vmaddr
        self.code = code
        strings = ["__cstring", "__oslogstring", "__objc_methname", "__objc_classname"].compactMap { img.section("__TEXT", $0) }
        selectorNames = img.section("__TEXT", "__objc_methname")
        data = img.allSections.filter { !$0.isZerofill && $0.offset != 0 && !($0.segment == "__TEXT" && $0.name == "__text") }
        // linkedit_data_command: cmd, cmdsize, dataoff, datasize. ULEB128 deltas from __TEXT's start, 0 ends.
        guard let dataoff = Self.u32(mapped, s.offset + lc.offset + 8), let datasize = Self.u32(mapped, s.offset + lc.offset + 12)
        else { return nil }
        var out: [UInt64] = []
        var at = s.offset + Int(dataoff)
        let end = min(at + Int(datasize), mapped.size)
        var addr: UInt64 = 0
        while at < end, let base = mapped.base {
            var delta: UInt64 = 0, shift: UInt64 = 0
            while at < end {
                let byte = base.load(fromByteOffset: at, as: UInt8.self)
                at += 1
                delta |= UInt64(byte & 0x7f) << shift
                shift += 7
                if byte & 0x80 == 0 || shift > 63 { break }
            }
            if delta == 0 { break }
            addr += delta
            out.append(addr)
        }
        guard !out.isEmpty else { return nil }
        starts = out
        readObjCMethods(img)
    }

    /// The function `offset` (from __TEXT's start) is in: its start, and its name.
    func function(at offset: UInt64) -> (start: UInt64, name: String)? {
        let codeStart = code.addr - textVM, codeEnd = codeStart + code.size
        guard offset >= codeStart, offset < codeEnd else { return nil }
        var lo = 0, hi = starts.count
        while lo < hi { let m = (lo + hi) / 2; if starts[m] <= offset { lo = m + 1 } else { hi = m } }
        guard lo > 0 else { return nil }
        let start = starts[lo - 1]
        let end = lo < starts.count ? min(starts[lo], codeEnd) : codeEnd
        if let m = methods[start] { return (start, m) }
        lock.lock()
        if let n = names[start] { lock.unlock(); return (start, n) }
        lock.unlock()
        let name = "fn_" + String(start, radix: 16) + (hint(start, end).map { " “\($0)”" } ?? "")
        lock.lock(); names[start] = name; lock.unlock()
        return (start, name)
    }

    // MARK: Hints

    private enum Found { case location(String), text(String), selector(String) }

    /// What the function's code refers to, best first: a Rust panic location, a sentence, a selector, a string.
    private func hint(_ start: UInt64, _ end: UInt64) -> String? {
        var found: [Found] = []
        var pages = [UInt64?](repeating: nil, count: 32)
        // Long functions: their first part is enough, and a huge one isn't read whole.
        let last = min(end, start + 16_384)
        var pc = textVM + start
        while pc + 4 <= textVM + last, found.count < 12 {
            guard let insn = Self.u32(file, slice + Int(code.offset) + Int(pc - code.addr)) else { break }
            let rd = Int(insn & 31), rn = Int((insn >> 5) & 31)
            if insn & 0x9F00_0000 == 0x9000_0000 {   // ADRP
                // immhi:immlo, 21 bits, sign-extended and shifted left 12 (a page count).
                let raw = Int64(((insn >> 5) & 0x7FFFF) << 2 | (insn >> 29) & 3)
                let imm = (raw << 43) >> 31
                pages[rd] = UInt64(bitPattern: Int64(bitPattern: pc & ~0xFFF) &+ imm)
            } else if insn & 0xFF80_0000 == 0x9100_0000 || insn & 0xFF80_0000 == 0x9140_0000 {   // ADD Xd, Xn, #imm
                if let page = pages[rn] {
                    let a = page &+ UInt64((insn >> 10) & 0xFFF) << ((insn >> 22) & 1 == 1 ? 12 : 0)
                    if let f = refer(a) { found.append(f) }
                    pages[rd] = a
                } else if rd < 31 { pages[rd] = nil }
            } else if insn & 0xFFC0_0000 == 0xF940_0000 {   // LDR Xt, [Xn, #imm]: a pointer slot (a selector reference)
                if let page = pages[rn], let p = pointer(at: page &+ UInt64((insn >> 10) & 0xFFF) * 8),
                   let sel = selectorNames, p >= sel.addr, p < sel.addr + sel.size, let s = string(at: p) {
                    found.append(.selector(s))
                }
                if rd < 31 { pages[rd] = nil }
            }
            // Other instructions that write a register are not followed: a page left over can only name a string
            // when the next ADD from it lands exactly on the start of one.
            pc += 4
        }
        for case .location(let l) in found { return l }
        func tidy(_ s: String) -> String? {
            var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasSuffix(":") { t.removeLast() }
            guard t.count >= 4 else { return nil }
            return t.count > 48 ? String(t.prefix(47)) + "…" : t
        }
        let texts = found.compactMap { f -> String? in
            guard case .text(let t) = f, !Self.meaningless.contains(t) else { return nil }
            return tidy(t)
        }
        let sentence = texts.first { s in s.split(separator: " ").filter { $0.count > 1 && $0.allSatisfy(\.isLetter) }.count >= 2 }
        if let sentence { return sentence }
        for case .selector(let s) in found { return s }
        return texts.first
    }

    /// Strings used in so many places that they say nothing about one: os_log's stand-in for a private value.
    static let meaningless: Set<String> = ["<redacted>", "<private>", "(null)", "%@", "%s", "%d"]

    /// What an address the code computes refers to: a string, a Swift literal 32 bytes before one, a Rust panic
    /// location, or a pointer to a string.
    private func refer(_ a: UInt64) -> Found? {
        if let s = string(at: a) ?? string(at: a &+ 0x20) { return .text(s) }
        guard let p = pointer(at: a), let s = string(at: p) else { return nil }
        // core::panic::Location: the file (pointer, length), then line and column, both u32. Newer compilers keep
        // the file NUL-terminated and may count the NUL in its length.
        let n = UInt64(s.utf8.count)
        if s.hasSuffix(".rs"), let len = u64(at: a &+ 8), len == n || len == n + 1,
           let line = u32(at: a &+ 16), line > 0, line < 1_000_000, let col = u32(at: a &+ 20), col < 10_000 {
            return .location(Self.shortPath(s) + ":\(line)")
        }
        return .text(s)
    }

    /// The end of a source path that says the most: "/Users/x/.cargo/registry/src/index…/tauri-2.1.0/src/app.rs"
    /// is "tauri-2.1.0/src/app.rs"; "/rustc/<hash>/library/core/src/option.rs" is "core/src/option.rs".
    static func shortPath(_ p: String) -> String {
        let parts = p.split(separator: "/")
        if let i = parts.lastIndex(of: "src"), i > 0 { return parts[(i - 1)...].joined(separator: "/") }
        return parts.suffix(2).joined(separator: "/")
    }

    // MARK: Objective-C

    private func readObjCMethods(_ img: MachOImage) {
        func list(_ seg: String, _ sect: String) -> [UInt64] {
            guard let s = img.section(seg, sect) else { return [] }
            return stride(from: s.addr, to: s.addr + s.size, by: 8).compactMap { pointer(at: $0) }
        }
        let classes = list("__DATA_CONST", "__objc_classlist") + list("__DATA", "__objc_classlist")
        for cls in classes.prefix(200_000) {
            guard let ro = classRO(cls), let name = pointer(at: ro &+ 24).flatMap(string(at:)) else { continue }
            let shown = Self.className(name)
            if let m = pointer(at: ro &+ 32) { addMethods(m, "-[" + shown + " ") }
            if let meta = pointer(at: cls), let mro = classRO(meta), let m = pointer(at: mro &+ 32) { addMethods(m, "+[" + shown + " ") }
        }
        let categories = list("__DATA_CONST", "__objc_catlist") + list("__DATA", "__objc_catlist")
        for cat in categories.prefix(200_000) {
            // category_t: name, cls (a bind for another image's class: unknown here), instance and class methods.
            guard let catName = pointer(at: cat).flatMap(string(at:)) else { continue }
            let owner = pointer(at: cat &+ 8).flatMap(classRO).flatMap { pointer(at: $0 &+ 24) }.flatMap(string(at:)).map(Self.className) ?? "?"
            let shown = owner + "(" + catName + ")"
            if let m = pointer(at: cat &+ 16) { addMethods(m, "-[" + shown + " ") }
            if let m = pointer(at: cat &+ 24) { addMethods(m, "+[" + shown + " ") }
        }
    }

    /// class_t's data (low bits are flags; Swift sets some) → class_ro_t.
    private func classRO(_ cls: UInt64) -> UInt64? {
        guard let d = pointer(at: cls &+ 32) else { return nil }
        return d & ~7
    }

    /// method_list_t: entsize and flags, count, then the methods: relative (12 bytes: selector reference, types,
    /// implementation, each an offset from its own field) or absolute (24 bytes of pointers).
    private func addMethods(_ list: UInt64, _ prefix: String) {
        guard let flags = u32(at: list), let count = u32(at: list &+ 4), count < 100_000 else { return }
        let small = flags & 0x8000_0000 != 0
        let size = UInt64(small ? 12 : flags & 0xFFFC)
        guard size >= 12 else { return }
        for i in 0..<UInt64(count) {
            let e = list &+ 8 &+ i * size
            let sel: String?, imp: UInt64?
            if small {
                guard let n = u32(at: e), let m = u32(at: e &+ 8) else { continue }
                let ref = UInt64(bitPattern: Int64(bitPattern: e) &+ Int64(Int32(bitPattern: n)))
                sel = flags & 0x4000_0000 != 0 ? string(at: ref) : pointer(at: ref).flatMap(string(at:))
                imp = m == 0 ? nil : UInt64(bitPattern: Int64(bitPattern: e &+ 8) &+ Int64(Int32(bitPattern: m)))
            } else {
                sel = pointer(at: e).flatMap(string(at:))
                imp = pointer(at: e &+ 16)
            }
            guard let sel, let imp, imp >= textVM else { continue }
            methods[imp - textVM] = prefix + sel + "]"
        }
    }

    /// "_TtC13BetterDisplay7AppCore" (a Swift class's runtime name) is "BetterDisplay.AppCore".
    static func className(_ n: String) -> String {
        guard n.hasPrefix("_TtC") else { return n }
        var rest = Substring(n.dropFirst(4))
        var parts: [Substring] = []
        while let digits = rest.prefix(while: \.isNumber).nilIfEmpty, let len = Int(digits), rest.count >= digits.count + len {
            rest = rest.dropFirst(digits.count)
            parts.append(rest.prefix(len))
            rest = rest.dropFirst(len)
        }
        return parts.count >= 2 && rest.isEmpty ? parts.joined(separator: ".") : n
    }

    // MARK: Reading

    /// The address a pointer in data leads to. Chained fixups keep the target in the low bits (36 of them, as
    /// an address or as an offset from __TEXT); a bind (another image's symbol) leads nowhere here. Without
    /// fixups the pointer is the address itself. The reading that lands inside this image is taken.
    private func pointer(at a: UInt64) -> UInt64? {
        guard let v = u64(at: a), v != 0, v >> 63 == 0 else { return nil }
        let low = v & 0xF_FFFF_FFFF
        for c in [v, low, textVM &+ low] where section(containing: c) != nil { return c }
        return nil
    }

    private func section(containing a: UInt64) -> MachOSection? {
        if a >= code.addr, a < code.addr + code.size { return code }
        return data.first { a >= $0.addr && a < $0.addr + $0.size }
    }

    private func offset(_ a: UInt64, _ n: UInt64) -> Int? {
        guard let s = section(containing: a), s.offset != 0, a + n <= s.addr + s.size else { return nil }
        return slice + Int(s.offset) + Int(a - s.addr)
    }

    private func u64(at a: UInt64) -> UInt64? {
        guard let o = offset(a, 8), let base = file.base, o + 8 <= file.size else { return nil }
        return base.loadUnaligned(fromByteOffset: o, as: UInt64.self)
    }

    private func u32(at a: UInt64) -> UInt32? {
        guard let o = offset(a, 4) else { return nil }
        return Self.u32(file, o)
    }

    private func string(at addr: UInt64) -> String? {
        guard let s = strings.first(where: { addr >= $0.addr && addr < $0.addr + $0.size }), let base = file.base else { return nil }
        let off = slice + Int(s.offset) + Int(addr - s.addr)
        // Only at the start of a string: the byte before it ends the one before.
        guard addr == s.addr || base.load(fromByteOffset: off - 1, as: UInt8.self) == 0 else { return nil }
        var bytes: [UInt8] = []
        var i = off
        while i < file.size, bytes.count < 300 {
            let b = base.load(fromByteOffset: i, as: UInt8.self)
            if b == 0 { break }
            bytes.append(b)
            i += 1
        }
        guard let text = String(validating: bytes, as: UTF8.self), !text.isEmpty,
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || $0 == "\n" }) else { return nil }
        return text
    }

    private static func u32(_ f: MappedFile, _ at: Int) -> UInt32? {
        guard let base = f.base, at >= 0, at + 4 <= f.size else { return nil }
        return base.loadUnaligned(fromByteOffset: at, as: UInt32.self)
    }
}

private extension Substring {
    var nilIfEmpty: Substring? { isEmpty ? nil : self }
}
