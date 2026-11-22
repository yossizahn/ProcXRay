import Foundation

/// The last `capacity` readings of a few quantities side by side (lanes), in one block of Floats: a ring, so a
/// new reading overwrites the oldest in place. NaN marks a reading that wasn't made.
///
/// Every graph's history is one of these (History for the process window, ProcHistory for the menu bar): one
/// small allocation per process that is never reallocated, where five growing arrays of optional doubles took
/// four times the memory and a memmove per append.
struct SeriesRing: Sendable {
    let lanes: Int
    private(set) var capacity: Int
    private var buf: [Float] = []
    /// The slot the next reading goes into.
    private var next = 0
    private(set) var count = 0

    init(lanes: Int, capacity: Int) {
        self.lanes = lanes
        self.capacity = max(1, capacity)
    }

    /// Adds one reading: `value` gives each lane's, nil when it wasn't read.
    mutating func push(_ value: (Int) -> Double?) {
        if buf.isEmpty { buf = [Float](repeating: .nan, count: lanes * capacity) }
        let base = next * lanes
        for l in 0..<lanes { buf[base + l] = value(l).map { Float($0) } ?? .nan }
        next = (next + 1) % capacity
        count = min(count + 1, capacity)
    }

    /// Keeps the newest readings when the length setting changes.
    mutating func resize(_ n: Int) {
        let n = max(1, n)
        guard n != capacity else { return }
        var new = SeriesRing(lanes: lanes, capacity: n)
        let keep = min(count, n)
        for i in (count - keep)..<count {
            let base = slot(i) * lanes
            new.push { l in buf[base + l].isNaN ? nil : Double(buf[base + l]) }
        }
        self = new
    }

    /// Where the i-th oldest reading is.
    private func slot(_ i: Int) -> Int { (next - count + i + capacity * 2) % capacity }

    /// A lane's readings, oldest first; nil where none was made.
    func values(_ lane: Int) -> [Double?] {
        guard count > 0 else { return [] }
        return (0..<count).map { i in
            let v = buf[slot(i) * lanes + lane]
            return v.isNaN ? nil : Double(v)
        }
    }

    /// A lane's readings, oldest first, with 0 where none was made.
    func filled(_ lane: Int) -> [Double] {
        guard count > 0 else { return [] }
        return (0..<count).map { i in
            let v = buf[slot(i) * lanes + lane]
            return v.isNaN ? 0 : Double(v)
        }
    }
}
