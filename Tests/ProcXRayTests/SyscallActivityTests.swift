import XCTest
@testable import ProcXRay

final class SyscallActivityTests: XCTestCase {
    private func record(_ id: Int, _ name: String, _ time: UInt64, thread: UInt64 = 7, args: [UInt64] = [3],
                        ret: UInt64 = 10, label: String? = "/tmp/a") -> SyscallRecord {
        SyscallRecord(id: id, start: time, end: time + 5, thread: thread, mach: false, number: 0,
                      name: name, args: args, ret: ret, firstFDLabel: label)
    }

    func testDescriptorLife() {
        var open = record(1, "open_nocancel", 0, args: [0, 0], label: nil)
        open.paths = ["/tmp/a"]
        open.ret = 3
        let a = record(2, "read", 10)
        var b = record(3, "pread_nocancel", 20)
        b.ret1 = 1
        let fstat = record(4, "fstat64", 25)
        let close = record(5, "close", 30)
        // Same descriptor number, no open seen: a life of its own; 0.6 s later still the same life.
        let c = record(6, "read", 40)
        let d = record(7, "write", 600_000_100)
        var failure = record(8, "read", 600_000_110)
        failure.failed = true
        failure.error = 5
        // More than a second later: a new activity.
        let e = record(9, "write", 2_000_000_000)
        let records = [b, a, open, fstat, close, c, d, failure, e]
        let groups = SyscallActivity.build(records, filter: "", errorsOnly: false)
        XCTAssertEqual(groups.map { $0.calls.map(\.id) }, [[9], [6, 7, 8], [1, 2, 3, 4, 5]])
        XCTAssertEqual(groups.map(\.operation), [.write, .readWrite, .read])
        XCTAssertEqual(groups.last?.target, "/tmp/a")
        XCTAssertEqual(groups.last?.bytesIn, 4_294_967_316)
        XCTAssertEqual(groups[1].failures, 1)
        XCTAssertTrue(groups[1].detail.contains("1 failed"))
        XCTAssertEqual(SyscallActivity.build(records, filter: "read", errorsOnly: true).map(\.id), [8])
    }

    func testSocketLife() {
        let socket = record(1, "socket", 0, args: [UInt64(AF_INET), UInt64(SOCK_STREAM)], ret: 5, label: nil)
        var connect = record(2, "connect", 10, args: [5], label: "TCP 10.0.0.1:50000->1.2.3.4:443")
        connect.failed = true
        connect.error = Int64(EINPROGRESS)
        let send = record(3, "sendto", 20, args: [5], ret: 100, label: "TCP 10.0.0.1:50000->1.2.3.4:443")
        let recv = record(4, "recvfrom", 30, args: [5], ret: 2000, label: "TCP 10.0.0.1:50000->1.2.3.4:443")
        let groups = SyscallActivity.build([socket, connect, send, recv], filter: "", errorsOnly: false)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].operation, .connection)
        XCTAssertEqual(groups[0].target, "TCP 10.0.0.1:50000->1.2.3.4:443")
        XCTAssertEqual(groups[0].bytesOut, 100)
        XCTAssertEqual(groups[0].bytesIn, 2000)
        XCTAssertEqual(groups[0].failures, 0)
    }

    func testMessagesAndPathCalls() {
        let send = UInt64(MACH_SEND_MSG), rcv = UInt64(MACH_RCV_MSG)
        // mach_msg2_trap(data, options, bits | size << 32, remote | local << 32)
        var m1 = record(1, "mach_msg2_trap", 0, args: [1, send | rcv, 0x13 | 64 << 32, 0x903], label: nil)
        m1.end = 1_000
        let m2 = record(2, "mach_msg2_trap", 100_000, args: [1, send, 0x13 | 40 << 32, 0x903], label: nil)
        let m3 = record(3, "mach_msg2_trap", 200_000, args: [1, send, 0x13 | 40 << 32, 0xa03], label: nil)
        var stat1 = record(4, "stat64", 300_000, label: nil)
        stat1.paths = ["/missing"]; stat1.failed = true; stat1.error = Int64(ENOENT)
        let stat2 = SyscallRecord(id: 5, start: 400_000, end: 400_005, thread: 7, mach: false, number: 0, name: "stat64",
                              args: [0], error: Int64(ENOENT), paths: ["/missing"], failed: true)
        let kill = record(6, "kill", 500_000, args: [77, UInt64(SIGTERM)], ret: 0, label: nil)
        let context = SyscallActivity.Context(pid: 10, ports: [0x903: 42], processNames: [42: "cfprefsd"])
        let groups = SyscallActivity.build([m1, m2, m3, stat1, stat2, kill], filter: "", errorsOnly: false, context: context)
        XCTAssertEqual(groups.map(\.operation), [.signal, .lookup, .message, .message])
        XCTAssertEqual(groups.map(\.target), ["SIGTERM to pid 77", "/missing", "port 0xa03 (not in the port listing)", "cfprefsd (42)"])
        XCTAssertEqual(groups[1].calls.map(\.id), [4, 5])
        XCTAssertEqual(groups[3].calls.map(\.id), [1, 2])
        XCTAssertEqual(groups[3].bytesOut, 104)
        XCTAssertEqual(groups[3].replyTime, 1_000)
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

    func testMessageDestinationKinds() {
        let send = UInt64(MACH_SEND_MSG)
        let copySend = UInt64(MACH_MSG_TYPE_COPY_SEND), sendOnce = UInt64(MACH_MSG_TYPE_MOVE_SEND_ONCE)
        let task = record(1, "mach_msg2_trap", 0, args: [1, send, copySend | 40 << 32, 0x203], label: nil)
        let own = record(2, "mach_msg2_trap", 1_000_000_000, args: [1, send, copySend | 40 << 32, 0x1103], label: nil)
        let reply = record(3, "mach_msg2_trap", 2_000_000_000, args: [1, send, sendOnce | 40 << 32, 0x4407], label: nil)
        let gone = record(4, "mach_msg2_trap", 3_000_000_000, args: [1, send, copySend | 40 << 32, 0x5503], label: nil)
        let context = SyscallActivity.Context(pid: 10, portKinds: [0x203: "task port", 0x1103: "own port"])
        let groups = SyscallActivity.build([task, own, reply, gone], filter: "", errorsOnly: false, context: context)
        XCTAssertEqual(groups.map(\.target), ["port 0x5503 (not in the port listing)", "Reply (send-once)", "Own port", "Kernel: task port"])
    }

    func testPortKinds() {
        // lsmp's per-process records: a task port, an IOKit connection, a port the process receives on itself,
        // and a send right to another process's port.
        let procs: [[String: Any]] = [
            ["pid": NSNumber(value: 10), "ports": [
                ["name": "0x00000203", "ipc-object": "0xa", "rights": ["send"], "type": "TASK-CONTROL"],
                ["name": "0x00000307", "ipc-object": "0xb", "rights": ["send"], "type": "IOKIT-CONNECT",
                 "description": "IOSurfaceRootUserClient(0x1)"],
                ["name": "0x00001103", "ipc-object": "0xc", "rights": ["recv", "send"], "type": "port"],
                ["name": "0x00002203", "ipc-object": "0xd", "rights": ["send"], "type": "port"],
            ]],
            ["pid": NSNumber(value: 20), "ports": [
                ["name": "0x00000903", "ipc-object": "0xd", "rights": ["recv"], "type": "port"],
            ]],
        ]
        let kinds = MachSnapshot.portKinds(processes: procs)
        XCTAssertEqual(kinds[10], [0x203: "task port", 0x307: "IOKit connection (IOSurfaceRootUserClient)", 0x1103: "own port"])
        XCTAssertNil(kinds[20])
    }

    func testRootSymlinkPaths() {
        // VFS_LOOKUP: first event (func 1) args[0] = vnode id, then path bytes; last event has func 2.
        func words(_ s: String) -> [UInt64] {
            var b = Array(s.utf8); while b.count % 8 != 0 { b.append(0) }
            return stride(from: 0, to: b.count, by: 8).map { i in b[i..<i + 8].enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * $1.offset) } }
        }
        let w = words("private/etc/hosts")   // 3 words: fits the first event's three
        let lookupID: UInt32 = 3 << 24 | 1 << 16 | 0x24 << 2
        let openID: UInt32 = 4 << 24 | 0x0c << 16 | 5 << 2
        var dec = SyscallDecoder()
        let out = dec.feed([
            KdebugEvent(ts: 1, debugid: openID | 1, arg: [0, 0, 0, 0], thread: 7),
            KdebugEvent(ts: 2, debugid: lookupID | 3, arg: [99] + w, thread: 7),
            KdebugEvent(ts: 3, debugid: openID | 2, arg: [0, 3, 0, 0], thread: 7),
        ])
        XCTAssertEqual(out.first?.paths, ["/private/etc/hosts"])
    }
}
