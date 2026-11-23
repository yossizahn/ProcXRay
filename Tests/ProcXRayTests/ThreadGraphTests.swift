import XCTest
@testable import ProcXRay

final class ThreadGraphTests: XCTestCase {
    /// Thread 1 works in activities 0 and 2, thread 2 in 1 to 3, thread 3 in 3 and 4. After thread 1's lane ends,
    /// thread 2's moves into its column and thread 3 starts next to it: no hole.
    func testLanes() {
        let g = ThreadGraph(activities: [(false, [1]), (false, [2]), (false, [1, 2]), (false, [2, 3]), (false, [3]),
                                         (true, [1, 2, 3])])
        XCTAssertEqual(g.span[1]?.bottom, 2)
        // The waits don't stretch lanes to the bottom.
        XCTAssertEqual(g.span[3]?.bottom, 4)
        XCTAssertEqual(g.lanes, [[1], [1, 2], [1, 2], [2, 3], [3], []])
        XCTAssertEqual(g.columns, 2)

        // Activity 1 (thread 2's first): thread 1's lane passes, thread 2 has a dot and goes on down.
        let row1 = Dictionary(uniqueKeysWithValues: g.groupMarks(1, expanded: false).map { ($0.tid, $0) })
        XCTAssertEqual(row1[1], .init(tid: 1, column: 0, from: 0, bottom: true, dot: false))
        XCTAssertEqual(row1[2], .init(tid: 2, column: 1, from: nil, bottom: true, dot: true))
        // Activity 2 is thread 1's last: its lane stops at the dot; open, it goes on into the calls.
        XCTAssertEqual(g.groupMarks(2, expanded: false).first { $0.tid == 1 }?.bottom, false)
        XCTAssertEqual(g.groupMarks(2, expanded: true).first { $0.tid == 1 }?.bottom, true)
        // Activity 3: thread 2 curves from column 1 into thread 1's column 0; thread 3 starts beside it.
        let row3 = Dictionary(uniqueKeysWithValues: g.groupMarks(3, expanded: false).map { ($0.tid, $0) })
        XCTAssertEqual(row3[2], .init(tid: 2, column: 0, from: 1, bottom: false, dot: true))
        XCTAssertEqual(row3[3], .init(tid: 3, column: 1, from: nil, bottom: true, dot: true))
        // Calls of activity 2: thread 1's call (first) leads on to thread 2's; thread 2 goes on past the activity.
        let first = Dictionary(uniqueKeysWithValues: g.callMarks(group: 2, call: 0, thread: 1).map { ($0.tid, $0) })
        XCTAssertEqual(first[1], .init(tid: 1, column: 0, from: 0, bottom: false, dot: true))
        XCTAssertEqual(first[2]?.bottom, true)
        XCTAssertNil(g.callMarks(group: 2, call: 1, thread: 2).first { $0.tid == 1 })
    }

    func testColours() {
        let c = ThreadColors.map([30, 10, 20])
        XCTAssertEqual(c[10], ThreadColors.palette[0])
        XCTAssertEqual(c[30], ThreadColors.palette[2])
    }
}
