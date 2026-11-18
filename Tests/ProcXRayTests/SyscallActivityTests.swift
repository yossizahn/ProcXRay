import XCTest
@testable import ProcXRay

final class SyscallActivityTests: XCTestCase {
    private func record(_ id: Int, _ name: String, _ time: UInt64, thread: UInt64 = 7) -> SyscallRecord {
        SyscallRecord(id: id, start: time, end: time + 5, thread: thread, mach: false, number: 0,
                      name: name, args: [3], ret: 10, firstFDLabel: "/tmp/a")
    }

    func testReadBursts() {
        let a = record(1, "read", 10)
        var b = record(2, "pread_nocancel", 20)
        b.ret1 = 1
        let close = record(3, "close", 30)
        let c = record(4, "read", 40)
        let d = record(5, "read", 600_000_100)
        var failure = record(6, "read", 600_000_110)
        failure.failed = true
        failure.error = 5
        let records = [b, a, close, c, d, failure]
        let groups = SyscallActivity.build(records, filter: "", errorsOnly: false)
        XCTAssertEqual(groups.map { $0.calls.map(\.id) }, [[6], [5], [4], [1, 2]])
        XCTAssertEqual(groups.last?.bytes, 4_294_967_316)
        XCTAssertEqual(groups.first?.bytes, 0)
        XCTAssertEqual(SyscallActivity.build(records, filter: "read", errorsOnly: true).map(\.id), [6])
    }

    func testWaitsAndConnection() {
        let connect = record(1, "connect", 0)
        var receive = record(2, "mach_msg2_trap", 10)
        receive.args = [0, UInt64(MACH_RCV_MSG)]
        var send = receive
        send.args = [0, UInt64(MACH_SEND_MSG)]
        var wait = record(3, "ulock_wait", 20, thread: 8)
        wait.end = nil
        wait.state = .inProgress
        let groups = SyscallActivity.build([wait, connect, send, receive], filter: "", errorsOnly: false)
        XCTAssertEqual(groups.map(\.operation), [.connect, .waits])
        XCTAssertEqual(groups[1].threads, [7, 8])
        XCTAssertEqual(groups[1].longest, 5)
        XCTAssertEqual(groups[1].calls.map(\.id), [2, 3])
    }
}
