import XCTest
@testable import ProcXRay

final class SeriesRingTests: XCTestCase {
    func testKeepsTheNewestReadingsOldestFirst() {
        var r = SeriesRing(lanes: 2, capacity: 3)
        XCTAssertEqual(r.values(0), [])
        for i in 1...5 { r.push { lane in lane == 0 ? Double(i) : Double(i * 10) } }
        XCTAssertEqual(r.count, 3)
        XCTAssertEqual(r.values(0), [3, 4, 5])
        XCTAssertEqual(r.values(1), [30, 40, 50])
    }

    func testAReadingThatWasNotMadeIsNilAndFillsAsZero() {
        var r = SeriesRing(lanes: 1, capacity: 4)
        r.push { _ in 1 }
        r.push { _ in nil }
        r.push { _ in 3 }
        XCTAssertEqual(r.values(0), [1, nil, 3])
        XCTAssertEqual(r.filled(0), [1, 0, 3])
    }

    func testResizeKeepsTheNewest() {
        var r = SeriesRing(lanes: 1, capacity: 5)
        for i in 1...7 { r.push { _ in Double(i) } }
        r.resize(3)
        XCTAssertEqual(r.values(0), [5, 6, 7])
        r.push { _ in 8 }
        XCTAssertEqual(r.values(0), [6, 7, 8])
        r.resize(6)
        XCTAssertEqual(r.values(0), [6, 7, 8])
        r.push { _ in 9 }
        XCTAssertEqual(r.values(0), [6, 7, 8, 9])
    }

    func testHistoryFollowsTheLengthSetting() {
        var h = History(capacity: 4)
        var p = ProcInfo(pid: 1, ppid: 0, pgid: 1, uid: 0, user: "root", comm: "x", path: nil, start: Date(), stat: 2, pflags: 0)
        for i in 1...6 {
            p.footprint = UInt64(i)
            h.append(p, capacity: 4)
        }
        XCTAssertEqual(h.memory, [3, 4, 5, 6])
        XCTAssertEqual(h.cpu, [nil, nil, nil, nil])   // no rates without a previous sample
        h.append(p, capacity: 2)
        XCTAssertEqual(h.memory, [6, 6])
    }

    func testLaunchdExitStatusReadsAsLaunchctlPrintsIt() {
        XCTAssertEqual(Launchd.exitText(nil), "-")
        XCTAssertEqual(Launchd.exitText(0), "0")
        XCTAssertEqual(Launchd.exitText(78 << 8), "78")   // exited with 78
        XCTAssertEqual(Launchd.exitText(9), "-9")         // killed by signal 9
    }
}
