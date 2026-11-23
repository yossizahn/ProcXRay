import Darwin
import Foundation

@_silgen_name("_dyld_get_shared_cache_range")
private func _dyld_get_shared_cache_range(_ length: UnsafeMutablePointer<Int>) -> UnsafeRawPointer?

/// A C string constant a traced process passed by pointer, read from our own copy of the dyld shared cache:
/// the cache is mapped at the same address in every native process until the next boot, so a string literal
/// in a system library (mac_syscall's policy name, "Quarantine" from libquarantine) is at that address here
/// too. Only addresses inside the cache are read, with mach_vm_read_overwrite (an error, not a crash, if the
/// page is gone), and only short printable text counts. A Rosetta process has its own x86_64 cache elsewhere,
/// so its pointers fall outside the range and stay hex.
enum SharedCacheString {
    private static let range: ClosedRange<UInt64>? = {
        var length = 0
        guard let base = _dyld_get_shared_cache_range(&length), length > 0 else { return nil }
        let start = UInt64(UInt(bitPattern: base))
        return start...(start + UInt64(length) - 1)
    }()

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [UInt64: String?] = [:]

    static func read(_ address: UInt64, maxLength: Int = 48) -> String? {
        guard let range, range.contains(address) else { return nil }
        lock.lock()
        if let hit = cache[address] { lock.unlock(); return hit }
        lock.unlock()
        let text = load(address, maxLength: maxLength)
        lock.lock(); cache[address] = .some(text); lock.unlock()
        return text
    }

    private static func load(_ address: UInt64, maxLength: Int) -> String? {
        // Up to the end of the page: a read crossing into an unmapped page fails as a whole.
        let page = UInt64(vm_page_size)
        let count = Int(min(UInt64(maxLength + 1), page - address % page))
        var buffer = [UInt8](repeating: 0, count: count)
        var got: mach_vm_size_t = 0
        let kr = buffer.withUnsafeMutableBytes { raw in
            mach_vm_read_overwrite(mach_task_self_, address, mach_vm_size_t(count),
                                   mach_vm_address_t(UInt(bitPattern: raw.baseAddress)), &got)
        }
        guard kr == KERN_SUCCESS, let end = buffer.prefix(Int(got)).firstIndex(of: 0), end > 0 else { return nil }
        let bytes = buffer[..<end]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}
