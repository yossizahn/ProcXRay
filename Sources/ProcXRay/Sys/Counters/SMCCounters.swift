import Foundation
import IOKit

/// Every key of the System Management Controller (AppleSMC user client; opens without privileges, measured on an
/// M1 MacBook Air, macOS 27.2: 1,644 keys). Keys are four characters whose first letter says what they are:
/// T temperature, P power, V voltage, I current, F fan, B battery… The names past the first letter are Apple's
/// and undocumented, so the browser shows them raw.
///
/// The user client takes one 80-byte struct (SMCKeyData_t) through selector 2, with a command in `data8`:
/// 8 key at index, 9 key info (size and type), 5 read. It's built here as raw bytes at fixed offsets.
final class SMCCounters: CounterSource {
    let kind = CounterSourceKind.smc

    private var conn: io_connect_t = 0
    private struct Key { var code: UInt32; var size: UInt32; var type: String; var id: String }
    private var keys: [String: [Key]] = [:]

    private enum Off {
        static let key = 0, size = 28, type = 32, result = 40, data8 = 42, data32 = 44, bytes = 48, length = 80
    }

    init() {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard s != 0 else { return }
        defer { IOObjectRelease(s) }
        if IOServiceOpen(s, mach_task_self_, 0, &conn) != KERN_SUCCESS { conn = 0 }
    }

    deinit { if conn != 0 { IOServiceClose(conn) } }

    private func call(_ key: UInt32, command: UInt8, size: UInt32 = 0, index: UInt32 = 0) -> [UInt8]? {
        guard conn != 0 else { return nil }
        var input = [UInt8](repeating: 0, count: Off.length)
        var output = [UInt8](repeating: 0, count: Off.length)
        input.withUnsafeMutableBytes { p in
            p.storeBytes(of: key, toByteOffset: Off.key, as: UInt32.self)
            p.storeBytes(of: size, toByteOffset: Off.size, as: UInt32.self)
            p.storeBytes(of: command, toByteOffset: Off.data8, as: UInt8.self)
            p.storeBytes(of: index, toByteOffset: Off.data32, as: UInt32.self)
        }
        var outSize = Off.length
        guard IOConnectCallStructMethod(conn, 2, input, Off.length, &output, &outSize) == KERN_SUCCESS,
              output[Off.result] == 0 else { return nil }
        return output
    }

    private static func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
    private static func string(_ c: UInt32) -> String {
        String(decoding: [UInt8(c >> 24), UInt8(c >> 16 & 0xff), UInt8(c >> 8 & 0xff), UInt8(c & 0xff)], as: UTF8.self)
    }

    private static let families: [Character: (String, String)] = [
        "T": ("Temperatures", "°C"), "P": ("Power", "W"), "V": ("Voltages", "V"), "I": ("Currents", "A"),
        "F": ("Fans", ""), "B": ("Battery", ""), "C": ("Charger", ""), "D": ("Display and ports", ""),
    ]

    func groups() -> [CounterGroup] {
        keys = [:]
        // "#KEY" (the number of keys) is big-endian, unlike the integer keys after it.
        guard let raw = call(Self.code("#KEY"), command: 5, size: 4) else { return [] }
        let count = Double(raw[Off.bytes..<(Off.bytes + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard count > 0 else { return [] }
        var byGroup: [String: [CounterInfo]] = [:]
        for i in 0..<UInt32(min(count, 10_000)) {
            guard let out = call(0, command: 8, index: i) else { continue }
            // The key at an index comes back in the struct's key field.
            let code = out.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: Off.key, as: UInt32.self) }
            guard let info = call(code, command: 9) else { continue }
            let (size, typeCode) = info.withUnsafeBytes {
                ($0.loadUnaligned(fromByteOffset: Off.size, as: UInt32.self), $0.loadUnaligned(fromByteOffset: Off.type, as: UInt32.self))
            }
            let name = Self.string(code), type = Self.string(typeCode)
            let first = name.first ?? "?"
            let gid = "smc|" + (Self.families[first] != nil ? String(first) : "other")
            let id = gid + "|" + name
            keys[gid, default: []].append(Key(code: code, size: size, type: type, id: id))
            var unit = Self.families[first]?.1 ?? ""
            if first == "F", name.hasSuffix("Ac") || name.hasSuffix("Mn") || name.hasSuffix("Mx") || name.hasSuffix("Tg") { unit = "rpm" }
            byGroup[gid, default: []].append(CounterInfo(id: id, group: gid, name: name, sub: type.trimmingCharacters(in: .whitespaces),
                                                         unit: Self.numeric(type) ? unit : "", format: Self.numeric(type) ? .number : .text))
        }
        return byGroup.map { gid, counters in
            let letter = gid.dropFirst(4)
            let title = letter.count == 1 ? "\(Self.families[letter.first!]!.0) (\(letter)…)" : "Other keys"
            return CounterGroup(id: gid, source: .smc, name: title,
                                note: "SMC keys" + (letter.count == 1 ? " starting with \(letter)" : " of other kinds") + ", read through the AppleSMC user client",
                                counters: counters)
        }
        .sorted { $0.name < $1.name }
    }

    func read(_ groups: Set<String>?) -> [String: CounterValue] {
        var out: [String: CounterValue] = [:]
        for (gid, list) in keys where groups?.contains(gid) ?? true {
            for k in list { if let v = read(k.code, size: k.size, type: k.type) { out[k.id] = v } }
        }
        return out
    }

    private static func numeric(_ t: String) -> Bool {
        ["flt ", "ui8 ", "ui16", "ui32", "ui64", "si8 ", "si16", "si32", "si64", "fpe2", "sp78", "flag"].contains(t)
    }

    private func read(_ code: UInt32, size: UInt32, type: String) -> CounterValue? {
        guard size > 0, size <= 32, let out = call(code, command: 5, size: size) else { return nil }
        let b = Array(out[Off.bytes..<(Off.bytes + Int(size))])
        func be(_ n: Int) -> UInt64 { b.prefix(n).reduce(0) { $0 << 8 | UInt64($1) } }
        // Integer keys are little-endian on Apple silicon (B0CT, the cycle count, reads 307 so; 13,057 big-endian).
        func le(_ n: Int) -> UInt64 { b.prefix(n).reversed().reduce(0) { $0 << 8 | UInt64($1) } }
        switch type {
        case "flt ": guard b.count >= 4 else { return nil }
            // Little-endian on Apple silicon.
            let f = b.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
            return .double((Double(f) * 1000).rounded() / 1000)
        case "ui8 ", "ui16", "ui32", "ui64": return .unsigned(le(b.count))
        case "si8 ": return .signed(Int64(Int8(bitPattern: b[0])))
        case "si16": return .signed(Int64(Int16(bitPattern: UInt16(le(2)))))
        case "si32": return .signed(Int64(Int32(bitPattern: UInt32(le(4)))))
        case "si64": return .signed(Int64(bitPattern: le(8)))
        // Fixed-point types keep the Intel SMC's big-endian layout.
        case "fpe2": return .double(Double(be(2)) / 4)
        case "sp78": return .double(Double(Int16(bitPattern: UInt16(be(2)))) / 256)
        case "flag": return .text(b.first == 0 ? "no" : "yes")
        case "ch8*": return .text(String(decoding: b.prefix { $0 != 0 }, as: UTF8.self))
        default: return .text(b.map { String(format: "%02x", $0) }.joined())
        }
    }
}
