import XCTest
@testable import ProcXRay

final class SyscallLanesTests: XCTestCase {
    private func record(_ id: Int, _ start: UInt64?, _ end: UInt64?, thread: UInt64, library: Bool = false) -> SyscallRecord {
        SyscallRecord(id: id, start: start, end: end, thread: thread, mach: false, number: library ? SyscallRecord.libraryCall : 3,
                      name: library ? "dlopen" : "read")
    }

    func testBuild() {
        let recs = [record(1, 50, 60, thread: 9), record(2, 10, 20, thread: 9), record(3, 30, nil, thread: 4),
                    record(4, nil, 5, thread: 7), record(5, 70, 100, thread: 7)]
        let l = SyscallLanes.build(recs, threadNames: [7: "main thread"])
        // The main thread first, then by id.
        XCTAssertEqual(l.lanes.map(\.tid), [7, 4, 9])
        XCTAssertEqual(l.end, 100)
        // Entered before the trace: from 0. Still running at the stop: to the trace's end.
        XCTAssertEqual(l.lanes[0].starts, [0, 70])
        XCTAssertEqual(l.lanes[1].ends, [100])
        XCTAssertEqual(l.lanes[2].calls.map(\.id), [2, 1])
        XCTAssertEqual(l.callCount, 5)
    }

    /// A call nested in a longer one (dyld's dlopen around its syscalls) is found inside it, and the outer one where
    /// nothing inner is.
    func testNestedHit() {
        let outer = record(1, 100, 1_000, thread: 1, library: true)
        let inner = record(2, 200, 210, thread: 1)
        let later = record(3, 1_100, 1_200, thread: 1)
        let lane = SyscallLanes.build([later, inner, outer]).lanes[0]
        XCTAssertEqual(lane.reach, [1_000, 1_000, 1_200])
        XCTAssertEqual(lane.firstReaching(500), 0)
        XCTAssertEqual(lane.firstReaching(1_050), 2)
        XCTAssertEqual(lane.call(at: 205, tolerance: 0).map { lane.calls[$0].id }, 2)
        XCTAssertEqual(lane.call(at: 500, tolerance: 0).map { lane.calls[$0].id }, 1)
        XCTAssertEqual(lane.call(at: 1_090, tolerance: 20).map { lane.calls[$0].id }, 3)
        XCTAssertNil(lane.call(at: 1_050, tolerance: 20))
    }

    func testNiceStep() {
        XCTAssertEqual(LanesCanvas.niceStep(3), 5)
        XCTAssertEqual(LanesCanvas.niceStep(120_000), 200_000)
        XCTAssertEqual(LanesCanvas.niceStep(1_000), 1_000)
    }
}
