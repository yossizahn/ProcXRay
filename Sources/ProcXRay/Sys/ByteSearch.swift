/// Byte-wise substring search for paths. Foundation's `range(of:)` and `contains(_:)` compare through its
/// locale-aware machinery, and the Smart tree's path checks (`.app/`, `.appex/`) made them half the cost of
/// every table rebuild. The needles here are ASCII, and an ASCII byte never occurs inside a multi-byte UTF-8
/// sequence, so a byte match always lands on a character boundary.
extension StringProtocol {
    func byteRange(of needle: String, backwards: Bool = false) -> Range<Index>? {
        var n = needle
        func search(_ hay: UnsafeBufferPointer<UInt8>) -> Int? {
            n.withUTF8 { byteOffset(of: $0, in: hay, backwards: backwards) }
        }
        // Not stored contiguously (bridged from NSString): search a copy of the bytes.
        let found = utf8.withContiguousStorageIfAvailable(search) ?? Array(utf8).withUnsafeBufferPointer(search)
        guard let off = found else { return nil }
        let lo = utf8.index(utf8.startIndex, offsetBy: off)
        return lo..<utf8.index(lo, offsetBy: needle.utf8.count)
    }

    func containsBytes(_ needle: String) -> Bool { byteRange(of: needle) != nil }
}

private func byteOffset(of needle: UnsafeBufferPointer<UInt8>, in hay: UnsafeBufferPointer<UInt8>, backwards: Bool) -> Int? {
    let n = needle.count, h = hay.count
    guard n > 0 else { return 0 }
    guard n <= h else { return nil }
    let first = needle[0]
    func matches(at i: Int) -> Bool {
        guard hay[i] == first else { return false }
        for j in 1..<n where hay[i + j] != needle[j] { return false }
        return true
    }
    if backwards {
        for i in stride(from: h - n, through: 0, by: -1) where matches(at: i) { return i }
    } else {
        for i in 0...(h - n) where matches(at: i) { return i }
    }
    return nil
}
