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
        XCTAssertEqual(groups.map(\.target), ["SIGTERM to pid 77", "/missing", "Unknown destination (port not in any listing)", "cfprefsd (42)"])
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
        XCTAssertEqual(groups.map(\.target), ["Unknown destination (port not in any listing)", "Reply (send-once)", "Own port", "Kernel: task port"])
    }

    func testMessageDestinationFromTheCall() {
        let send = UInt64(MACH_SEND_MSG), sendRcv = UInt64(MACH_SEND_MSG | MACH_RCV_MSG)
        let copySend = UInt64(MACH_MSG_TYPE_COPY_SEND), sendOnce = UInt64(MACH_MSG_TYPE_MOVE_SEND_ONCE)
        // Not in any listing: woke a thread of pid 42; a request answered without blocking; a reply that woke
        // its requester; a one-way send that woke nobody.
        var woke = record(1, "mach_msg2_trap", 0, args: [1, send, copySend, 0x1650b], label: nil)
        woke.receiver = 42; woke.blocked = true
        var kernel = record(2, "mach_msg2_trap", 1_000_000_000, args: [1, sendRcv, copySend, 0x16507], label: nil)
        kernel.blocked = false
        var reply = record(3, "mach_msg2_trap", 2_000_000_000, args: [1, send, sendOnce, 0x4407], label: nil)
        reply.receiver = 42
        var oneway = record(4, "mach_msg2_trap", 3_000_000_000, args: [1, send, copySend, 0x5503], label: nil)
        oneway.blocked = false
        // A listed name wins over the call.
        var listed = record(5, "mach_msg2_trap", 4_000_000_000, args: [1, sendRcv, copySend, 0x1203], label: nil)
        listed.blocked = false
        let context = SyscallActivity.Context(pid: 10, ports: [0x1203: 77], processNames: [42: "cfprefsd", 77: "WindowServer"])
        let groups = SyscallActivity.build([woke, kernel, reply, oneway, listed], filter: "", errorsOnly: false, context: context)
        XCTAssertEqual(groups.map(\.target), ["WindowServer (77)", "Unknown destination (port not in any listing)", "Reply to cfprefsd (42)",
                                              "Kernel object (port gone before any listing)", "cfprefsd (42)"])
        XCTAssertFalse(context.unnamed(0x1650b, sendOnce: false, call: woke))
        XCTAssertFalse(context.unnamed(0x16507, sendOnce: false, call: kernel))
        XCTAssertTrue(context.unnamed(0x5503, sendOnce: false, call: oneway))
    }

    func testDecoderSchedulerEvents() {
        // Thread 7 sends: wakes thread 900, blocks, gets its reply. Thread 8: a call answered without blocking.
        let msgEntry: UInt32 = 0x010c_00bc | 1, msgReturn: UInt32 = 0x010c_00bc | 2
        let events = [
            KdebugEvent(ts: 1, eventname: "MSC_mach_msg2_trap", debugid: msgEntry, arg: [1, 3, 0, 0x1650b], thread: 7),
            KdebugEvent(ts: 2, debugid: KdebugEvent.makeRunnable, arg: [900, 0x4f, 0, 4], thread: 7),
            KdebugEvent(ts: 3, debugid: 0x0140_003c, arg: [0, 0, 0, 0], thread: 7),
            KdebugEvent(ts: 4, debugid: KdebugEvent.makeRunnable, arg: [901, 0x4f, 0, 4], thread: 7),
            KdebugEvent(ts: 5, eventname: "MSC_mach_msg2_trap", debugid: msgReturn, arg: [0, 0, 0, 0], thread: 7),
            KdebugEvent(ts: 6, eventname: "MSC_mach_msg2_trap", debugid: msgEntry, arg: [1, 3, 0, 0x16507], thread: 8),
            KdebugEvent(ts: 7, eventname: "MSC_mach_msg2_trap", debugid: msgReturn, arg: [0, 0, 0, 0], thread: 8),
        ]
        var dec = SyscallDecoder()
        let recs = dec.feed(events)
        XCTAssertEqual(recs.map(\.woke), [900, 0])
        XCTAssertEqual(recs.map(\.blocked), [true, false])
        var labeled = recs
        var wakes = ThreadLabeler()
        _ = wakes.label(&labeled) { tids in Dictionary(uniqueKeysWithValues: tids.map { ($0, ThreadInfo(pid: 42, name: $0 == 7 ? "worker" : "", main: $0 == 8)) }) }
        XCTAssertEqual(wakes.threadNames, [7: "worker", 8: "main thread"])
        XCTAssertEqual(labeled.map(\.receiver), [42, nil])
        // Without scheduler events in the trace, nothing says the call didn't block.
        var plain = SyscallDecoder()
        XCTAssertEqual(plain.feed(Array(events.suffix(2))).map(\.blocked), [nil])
    }

    /// Little-endian words of a string, NUL-padded to whole words.
    private func words(_ s: String) -> [UInt64] {
        var b = Array(s.utf8); repeat { b.append(0) } while b.count % 8 != 0
        return stride(from: 0, to: b.count, by: 8).map { i in b[i..<i + 8].enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * $1.offset) } }
    }

    /// TRACE_STRING_GLOBAL events for one string, as libkdebug splits it: owner, id and two words, then four a time.
    private func stringEvents(_ text: String, id: UInt64, owner: UInt32, ts: UInt64, thread: UInt64) -> [KdebugEvent] {
        let w = words(text)
        var out: [KdebugEvent] = []
        var rest = Array(w.dropFirst(2))
        out.append(KdebugEvent(ts: ts, debugid: 0x0701_0000 | 1 | (rest.isEmpty ? 2 : 0), arg: [UInt64(owner), id] + Array(w.prefix(2)), thread: thread))
        while !rest.isEmpty {
            let chunk = Array(rest.prefix(4)); rest = Array(rest.dropFirst(4))
            out.append(KdebugEvent(ts: ts, debugid: 0x0701_0000 | (rest.isEmpty ? 2 : 0), arg: chunk + Array(repeating: 0, count: 4 - chunk.count), thread: thread))
        }
        return out
    }

    func testDecoderDyldAndThreadNames() {
        let lib = "/System/Library/Frameworks/QuartzCore.framework/QuartzCore", sym = "CARenderUpdateSetGreedy"
        var events = stringEvents(lib, id: 0x70ac_0001, owner: 0x1f08_0000, ts: 1, thread: 7)
        events += stringEvents(sym, id: 0x70ac_0002, owner: 0x1f08_000c, ts: 2, thread: 7)
        events += stringEvents("missingSymbol", id: 0x70ac_0003, owner: 0x1f08_000c, ts: 2, thread: 7)
        events += stringEvents("/usr/lib/libfoo.dylib", id: 0x70ac_0004, owner: 0x1f05_0000, ts: 2, thread: 7)
        let name = words("probe.named-thread")
        events += [
            KdebugEvent(ts: 3, debugid: 0x0701_0010 | 3, arg: name + Array(repeating: 0, count: 4 - name.count), thread: 9),
            KdebugEvent(ts: 10, debugid: 0x1f08_0000 | 1, arg: [0x1af, 0x70ac_0001, 0x101, 0], thread: 7),
            KdebugEvent(ts: 20, debugid: 0x1f08_0000 | 2, arg: [0x1af, 0x2_93b8_34a1, 0, 0], thread: 7),
            KdebugEvent(ts: 30, debugid: 0x1f08_000c | 1, arg: [0x1b0, 0x2_93b8_34a1, 0x70ac_0002, 0], thread: 7),
            KdebugEvent(ts: 35, debugid: 0x1f08_000c | 2, arg: [0x1b0, 0x1_a185_0c00, 0, 0], thread: 7),
            KdebugEvent(ts: 40, debugid: 0x1f08_000c | 1, arg: [0x1b1, UInt64(bitPattern: -2), 0x70ac_0003, 0], thread: 7),
            KdebugEvent(ts: 41, debugid: 0x1f08_000c | 2, arg: [0x1b1, 0, 0, 0], thread: 7),
            KdebugEvent(ts: 50, debugid: 0x1f05_0000, arg: [1, 2, 0x1_0000_0000, 0], thread: 7),
            KdebugEvent(ts: 50, debugid: 0x1f05_0004, arg: [0, 0x70ac_0004, 0, 0], thread: 7),
            KdebugEvent(ts: 60, debugid: 0x1f07_0000 | 1, arg: [0x1b2, 0x1_0000_0000, 0x1_0000_4000, 0], thread: 7),
            KdebugEvent(ts: 70, debugid: 0x1f07_0000 | 2, arg: [0x1b2, 0, 0, 0], thread: 7),
        ]
        var dec = SyscallDecoder()
        let recs = dec.feed(events)
        XCTAssertEqual(dec.threadNames, [9: "probe.named-thread"])
        XCTAssertEqual(recs.map(\.name), ["dlopen", "dlsym", "dlsym", "load image", "initializer"])
        XCTAssertTrue(recs.allSatisfy(\.isLibraryCall))
        XCTAssertEqual(recs[0].argValues, ["\"" + lib + "\"", "0x101"])
        XCTAssertEqual(recs[0].resultText, "handle 0x293b834a1")
        XCTAssertEqual(recs[1].argValues, ["\"" + lib + "\"", "\"" + sym + "\""])
        XCTAssertEqual(recs[1].paths, [lib])
        XCTAssertEqual(recs[1].duration, 5)
        XCTAssertEqual(recs[2].argValues, ["RTLD_DEFAULT", "\"missingSymbol\""])
        XCTAssertTrue(recs[2].failed)
        XCTAssertEqual(recs[3].paths, ["/usr/lib/libfoo.dylib"])
        XCTAssertEqual(recs[4].paths, ["/usr/lib/libfoo.dylib"])
        XCTAssertEqual(recs[4].stack, [0x1_0000_4000])

        let groups = SyscallActivity.build(recs, filter: "", errorsOnly: false)
        XCTAssertEqual(groups.map(\.operation), [.initializers, .loadImage, .symbol, .symbol, .openLibrary])
        XCTAssertEqual(groups.map(\.target), ["", "", "Any loaded library (RTLD_DEFAULT)", lib, lib])
        XCTAssertEqual(groups[2].detail, "NULL (not found)")
    }

    func testKernelRoutines() {
        // libsandbox's table, in the kernel's index order: present on this OS, starting at host_info.
        XCTAssertGreaterThanOrEqual(MIGRoutines.names.count, 300)
        XCTAssertEqual(MIGRoutines.names.first, "host_info")
        // Names that start with an underscore or a capital are routines too (27.2: 355 in all).
        XCTAssertTrue(MIGRoutines.names.contains("UNDAlertCompletedWithResult_rpc"))
        XCTAssertFalse(MIGRoutines.names.contains { !$0.contains(where: \.isLowercase) })
        let taskInfo = try! XCTUnwrap(MIGRoutines.names.firstIndex(of: "task_info"))   // task_info_from_user, suffix dropped
        // A task_info call: mach_msg2_trap to the task port with the MIG start and end inside it.
        let entry: UInt32 = 0x010c_00bc | 1, ret: UInt32 = 0x010c_00bc | 2
        let send = UInt64(MACH_SEND_MSG | MACH_RCV_MSG)
        var dec = SyscallDecoder()
        let recs = dec.feed([
            KdebugEvent(ts: 1, eventname: "MSC_mach_msg2_trap", debugid: entry, arg: [1, send, 0x13, 0x203], thread: 7),
            KdebugEvent(ts: 2, debugid: 0xff00_0000 | UInt32(taskInfo) << 2 | 1, arg: [0, 0, 0, 0], thread: 7),
            KdebugEvent(ts: 3, debugid: 0xff00_0000 | UInt32(taskInfo) << 2 | 2, arg: [0, 0, 0, 0], thread: 7),
            KdebugEvent(ts: 4, eventname: "MSC_mach_msg2_trap", debugid: ret, arg: [0, 0, 0, 0], thread: 7),
        ])
        XCTAssertEqual(recs.map(\.kernelRoutine), [taskInfo])
        let groups = SyscallActivity.build(recs, filter: "", errorsOnly: false)
        XCTAssertEqual(groups.map(\.operation), [.kernelCall])
        XCTAssertEqual(groups.map(\.target), ["task_info"])
    }

    func testCallsTableLabels() {
        let send = UInt64(MACH_SEND_MSG), sendRcv = UInt64(MACH_SEND_MSG | MACH_RCV_MSG)
        var kernel = record(1, "mach_msg2_trap", 0, args: [1, sendRcv, 0x13, 0x203], label: nil)
        kernel.kernelRoutine = MIGRoutines.names.firstIndex(of: "task_info")
        kernel.resultText = "KERN_SUCCESS"
        var woke = record(2, "mach_msg2_trap", 5, thread: 9, args: [1, send, 0x13, 0x1650b], label: nil)
        woke.receiver = 42
        woke.resultText = "KERN_SUCCESS"
        let read = record(3, "read", 10)
        let context = SyscallActivity.Context(pid: 10, processNames: [42: "cfprefsd"], threadNames: [9: "main thread"])
        XCTAssertEqual(context.messageTarget(kernel), "task_info (kernel)")
        XCTAssertEqual(context.messageTarget(woke), "cfprefsd (42)")
        XCTAssertNil(context.messageTarget(read))
        let line = SyscallTraceView.line(woke, context: context)
        XCTAssertTrue(line.contains("[9 main thread]"), line)
        XCTAssertTrue(line.contains("= KERN_SUCCESS  → cfprefsd (42)"), line)

        XCTAssertEqual(ManPage.page(for: "open_nocancel"), ManPage.Page(name: "open", section: 2))
        XCTAssertEqual(ManPage.page(for: "dlsym")?.title, "dlsym(3)")
        XCTAssertNil(ManPage.page(for: "initializer"))
    }

    func testLaunchedMainThreadName() {
        // The helper found nothing (the process exited): the trace's own knowledge names the main thread.
        XCTAssertEqual(SyscallTracer.threadNames([:], [7: "worker"], main: 5), [5: "main thread", 7: "worker"])
        // Named during the trace, or already "main thread" from the helper: kept, not doubled.
        XCTAssertEqual(SyscallTracer.threadNames([:], [5: "loop"], main: 5), [5: "main thread, loop"])
        XCTAssertEqual(SyscallTracer.threadNames([5: "main thread"], [:], main: 5), [5: "main thread"])
        XCTAssertEqual(SyscallTracer.threadNames([5: "main thread"], [5: "loop"], main: 5), [5: "main thread, loop"])
    }

    func testLaunchMarkers() {
        // As traced in the VM: dyld starts (twice: it restarts from the shared cache), the launch begins with the
        // main executable's header, its image load names it, the launch ends, main's first call follows.
        var events = stringEvents("/tmp/hello", id: 0x70ac_0010, owner: 0x1f05_0000, ts: 1, thread: 7)
        events += [
            KdebugEvent(ts: 100, debugid: 0x1f07_0034, arg: [0, 0, 0, 0], thread: 7),
            KdebugEvent(ts: 200, debugid: 0x1f07_0034, arg: [0, 0, 0, 0], thread: 7),
            KdebugEvent(ts: 300, debugid: 0x1f07_0004 | 1, arg: [2, 0x1_00d0_c000, 0, 0], thread: 7),
            KdebugEvent(ts: 400, debugid: 0x1f05_0000, arg: [1, 2, 0x1_00d0_c000, 0], thread: 7),
            KdebugEvent(ts: 400, debugid: 0x1f05_0004, arg: [0, 0x70ac_0010, 0, 0], thread: 7),
            KdebugEvent(ts: 1_500, debugid: 0x1f07_0004 | 2, arg: [2, 0, 0, 0], thread: 7),
        ]
        var dec = SyscallDecoder()
        let recs = dec.feed(events)
        XCTAssertEqual(recs.map(\.name), ["load image", "dyld setup", "main()"])
        XCTAssertEqual(recs[1].start, 100)          // from dyld's first start
        XCTAssertEqual(recs[1].duration, 1_400)
        XCTAssertEqual(recs[1].paths, ["/tmp/hello"])
        XCTAssertEqual(recs[2].start, 1_500)
        XCTAssertTrue(recs[1].isLaunchMarker && recs[2].isLaunchMarker && !recs[0].isLaunchMarker)
        XCTAssertEqual(SyscallSummaryRow.build(recs).map(\.name), ["load image"])
        let groups = SyscallActivity.build(recs, filter: "", errorsOnly: false)
        XCTAssertEqual(groups.map(\.operation), [.mainStarts, .loadImage, .dyldSetup])
        XCTAssertEqual(groups[2].target, "/tmp/hello")
        XCTAssertEqual(groups[0].detail, "the program's own code starts")
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
