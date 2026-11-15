import Foundation
import MachO

/// libsandbox's own name tables: operations, filters (with their named values) and modifiers, read out of the
/// loaded library so they always match the libsandbox that compiled a profile on this system.
///
/// Measured on macOS 27.2 (libsandbox D8A93887-…): 204 operations (plus 6 used inside message filters),
/// 112 filters, 21 modifiers. Compiled profiles refer to all three by index.
///
/// The tables are plain arrays in libsandbox's `__DATA_CONST`:
/// - operations: `const char *[]`, starting "default", "appleevent-send".
/// - filters: 32-byte records `{ name, category, u64 flags, values }`, index 0 empty, 1 = "path". The low byte
///   of `flags` is the argument type; `values` points at `{ const char *name; u64 value }` pairs, null-terminated.
/// - modifiers: 32-byte records `{ name, u32 actions, u32 kind, u32 mask, u32 value, values }`, index 1 = "send-signal".
struct SandboxTables {
    struct Filter {
        let name: String
        let category: String
        let flags: UInt64
        /// Named values: the compiled argument is the low 16 bits.
        let values: [(name: String, value: UInt64)]
        var argType: UInt8 { UInt8(flags & 0xff) }
        /// Byte 3 of the flags: 1 = the argument indexes the profile's state-flag table.
        var indexKind: UInt8 { UInt8((flags >> 24) & 0xff) }
    }
    struct Modifier {
        let name: String
        let actions: UInt32     // 1 = deny, 2 = allow (a bit set)
        let kind: UInt32        // 1 = flag, 2 = integer argument, 3 = string argument, 4 = message filter
        let mask: UInt32        // for flags: the bits of the terminal's flags it owns, and their value
        let value: UInt32
        let values: [(name: String, value: UInt64)]
    }

    /// The regular operations, indexed as in a profile's operation table.
    let operations: [String]
    /// Every name in the table, including the message-filter operations after the regular ones.
    let allOperations: [String]
    let filters: [Filter?]
    let modifiers: [Modifier?]

    static let shared: SandboxTables? = load()

    private static func load() -> SandboxTables? {
        guard dlopen("/usr/lib/libsandbox.1.dylib", RTLD_LAZY) != nil else { return nil }
        var cstring: Range<UInt>?, dataConst: Range<UInt>?, data: Range<UInt>?
        for i in 0..<_dyld_image_count() {
            guard let n = _dyld_get_image_name(i), String(cString: n).hasSuffix("/libsandbox.1.dylib"),
                  let h = _dyld_get_image_header(i) else { continue }
            let slide = UInt(bitPattern: _dyld_get_image_vmaddr_slide(i))
            var lc = UnsafeRawPointer(h).advanced(by: MemoryLayout<mach_header_64>.size)
            for _ in 0..<h.pointee.ncmds {
                let cmd = lc.load(as: load_command.self)
                if cmd.cmd == LC_SEGMENT_64 {
                    let seg = lc.load(as: segment_command_64.self)
                    var sp = lc.advanced(by: MemoryLayout<segment_command_64>.size)
                    for _ in 0..<seg.nsects {
                        let s = sp.load(as: section_64.self)
                        let name = withUnsafeBytes(of: s.sectname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                        let segname = withUnsafeBytes(of: s.segname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                        let r = UInt(s.addr) &+ slide ..< UInt(s.addr) &+ slide &+ UInt(s.size)
                        if name == "__cstring" { cstring = r }
                        if name == "__const" && segname == "__DATA_CONST" { dataConst = r }
                        if name == "__data" && segname == "__DATA" { data = r }
                        sp = sp.advanced(by: MemoryLayout<section_64>.size)
                    }
                }
                lc = lc.advanced(by: Int(cmd.cmdsize))
            }
            break
        }
        guard let cs = cstring, let dc = dataConst else { return nil }

        // Data pointers in the shared cache carry no PAC bits here, but strip the top anyway.
        func strip(_ p: UInt) -> UInt { p & 0x0000_000F_FFFF_FFFF }
        func word(_ a: UInt) -> UInt { UnsafeRawPointer(bitPattern: a)!.load(as: UInt.self) }
        func str(_ p: UInt) -> String? {
            let a = strip(p)
            guard cs.contains(a) else { return nil }
            return String(cString: UnsafePointer<CChar>(bitPattern: a)!)
        }
        func values(_ p: UInt) -> [(String, UInt64)] {
            let a = strip(p)
            guard a != 0, dc.contains(a) || (data?.contains(a) ?? false) else { return [] }
            var out: [(String, UInt64)] = []
            var q = a
            while out.count < 4096, let n = str(word(q)) {
                out.append((n, UInt64(word(q + 8))))
                q += 16
            }
            return out
        }

        // Operations.
        var opsStart: UInt?
        var q = dc.lowerBound
        while q + 16 <= dc.upperBound {
            if str(word(q)) == "default", str(word(q + 8)) == "appleevent-send" { opsStart = q; break }
            q += 8
        }
        guard let os = opsStart else { return nil }
        var all: [String] = []
        q = os
        while all.count < 1024, q < dc.upperBound, let n = str(word(q)) { all.append(n); q += 8 }
        guard let firstMessage = all.firstIndex(of: "default-message-filter") else { return nil }
        let ops = Array(all[..<firstMessage])

        // Filters: an empty record followed by "path", "path".
        var filtersStart: UInt?
        q = dc.lowerBound
        while q + 64 <= dc.upperBound {
            if word(q) == 0, word(q + 8) == 0, str(word(q + 32)) == "path", str(word(q + 40)) == "path" { filtersStart = q; break }
            q += 8
        }
        guard let fs = filtersStart else { return nil }
        var filters: [Filter?] = [nil]
        q = fs + 32
        while filters.count < 512, q + 32 <= dc.upperBound, let n = str(word(q)), let c = str(word(q + 8)) {
            filters.append(Filter(name: n, category: c, flags: UInt64(word(q + 16)), values: values(word(q + 24)).map { (name: $0.0, value: $0.1) }))
            q += 32
        }

        // Modifiers: the record named "send-signal" is index 1.
        var modsStart: UInt?
        q = dc.lowerBound
        while q + 32 <= dc.upperBound {
            if str(word(q)) == "send-signal", word(q + 8) & 0xffff_ffff == 3 { modsStart = q; break }
            q += 8
        }
        var modifiers: [Modifier?] = [nil]
        if let ms = modsStart {
            q = ms
            while modifiers.count < 128, q + 32 <= dc.upperBound, let n = str(word(q)) {
                let w1 = word(q + 8), w2 = word(q + 16)
                let actions = UInt32(w1 & 0xffff_ffff), kind = UInt32(w1 >> 32)
                guard (1...15).contains(actions), (1...8).contains(kind) else { break }
                modifiers.append(Modifier(name: n, actions: actions, kind: kind, mask: UInt32(w2 & 0xffff_ffff), value: UInt32(w2 >> 32),
                                          values: values(word(q + 24)).map { (name: $0.0, value: $0.1) }))
                q += 32
            }
        }
        guard filters.count > 1, modifiers.count > 1 else { return nil }
        return SandboxTables(operations: ops, allOperations: all, filters: filters, modifiers: modifiers)
    }
}
