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

    /// Following one thread: only its calls, and another thread's close still ends the descriptor's life.
    func testOneThread() {
        let a = record(1, "read", 0, thread: 7)
        let b = record(2, "read", 10, thread: 8)
        let close = record(3, "close", 20, thread: 8)
        let c = record(4, "read", 30, thread: 7)
        let groups = SyscallActivity.build([a, b, close, c], filter: "", errorsOnly: false, threads: [7])
        XCTAssertEqual(groups.map { $0.calls.map(\.id) }, [[4], [1]])
        XCTAssertEqual(SyscallActivity.build([a, b, close, c], filter: "", errorsOnly: false, threads: [9]).count, 0)
        XCTAssertEqual(SyscallActivity.build([a, b, close, c], filter: "", errorsOnly: false, threads: [7, 8]).map { $0.calls.map(\.id) }, [[4], [1, 2, 3]])
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

        // The same lookup on another thread, between the two: its own activity, and the first thread's repeat
        // still joins its first.
        let other = SyscallRecord(id: 7, start: 350_000, end: 350_005, thread: 8, mach: false, number: 0, name: "stat64",
                                  args: [0], error: Int64(ENOENT), paths: ["/missing"], failed: true)
        let split = SyscallActivity.build([stat1, other, stat2], filter: "", errorsOnly: false, context: context)
        XCTAssertEqual(split.map { $0.calls.map(\.id) }, [[7], [4, 5]])
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

    private func stat(_ id: Int, _ path: String, _ time: UInt64, thread: UInt64 = 7, missing: Bool = false) -> SyscallRecord {
        SyscallRecord(id: id, start: time, end: time + 5, thread: thread, mach: false, number: 0, name: "stat64", args: [0],
                      error: missing ? Int64(ENOENT) : 0, paths: [path], failed: missing)
    }

    /// A walk of a directory tree is one activity under the directory its paths spread out from, whichever
    /// threads made the calls; what lies outside the tree, or comes later, stays its own.
    func testBurstRollsUpByDirectory() {
        var recs = [stat(1, "/Users/me/.config.json", 0)]
        let names = ["a", "a/SKILL.md", "b", "b/SKILL.md", "synced/x", "synced/x/SKILL.md", "synced/y"]
        for (i, n) in names.enumerated() {
            recs.append(stat(10 + i, "/Users/me/.claude/skills/" + n, 1_000 + UInt64(i) * 1_000, thread: i % 2 == 0 ? 7 : 8,
                             missing: n == "synced/y"))
        }
        recs.append(stat(30, "/Users/me/.claude/skills/late", 500_000_000))
        let groups = SyscallActivity.build(recs, filter: "", errorsOnly: false)
        XCTAssertEqual(groups.map(\.target), ["/Users/me/.claude/skills/late", "/Users/me/.claude/skills", "/Users/me/.config.json"])
        let tree = groups[1]
        XCTAssertEqual(tree.operation, .lookup)
        XCTAssertEqual(tree.paths, 7)
        XCTAssertEqual(tree.calls.map(\.id), Array(10...16))
        XCTAssertEqual(tree.failures, 1)
        XCTAssertEqual(tree.id, 10)
        XCTAssertTrue(tree.detail.hasPrefix("7 paths in "), tree.detail)
        XCTAssertTrue(tree.detail.contains("1 failed"), tree.detail)

        // Three paths aren't a walk, and paths with nothing in common below the top have no directory to go under.
        XCTAssertEqual(SyscallActivity.build(Array(recs[1...3]), filter: "", errorsOnly: false).count, 3)
        let apart = ["/usr/lib/a", "/usr/share/b", "/private/tmp/c", "/Users/me/d", "/System/Library/e"].enumerated().map { stat($0, $1, UInt64($0)) }
        XCTAssertEqual(SyscallActivity.build(apart, filter: "", errorsOnly: false).count, 5)
    }

    /// A walk that changes into each directory and names its entries: the paths are followed through the chdirs.
    func testRelativePathsFollowTheWorkingDirectory() {
        func chdir(_ id: Int, _ path: String, _ time: UInt64) -> SyscallRecord {
            SyscallRecord(id: id, start: time, end: time + 1, thread: 7, mach: false, number: 0, name: "chdir", args: [0], paths: [path])
        }
        let before = stat(1, "notes.txt", 0)
        var at = stat(8, "x", 70)
        at = SyscallRecord(id: 8, start: 70, end: 71, thread: 7, mach: false, number: 0, name: "fstatat64", args: [5, 0], paths: ["x"])
        let recs = [before, chdir(2, "/usr/share/zsh", 10), stat(3, "5.9", 20), chdir(4, "5.9", 30), stat(5, "functions", 40),
                    chdir(6, "..", 50), stat(7, "./site-functions", 60), at]
        let context = SyscallActivity.Context(cwd: "/Users/me")
        let groups = SyscallActivity.build(recs, filter: "", errorsOnly: false, context: context)
        XCTAssertEqual(groups.map(\.target), ["x", "/usr/share/zsh/site-functions", "/usr/share/zsh/5.9/functions", "/usr/share/zsh/5.9",
                                              "/Users/me/notes.txt"])
        // Nobody knows where it started: the path stays as the program gave it.
        XCTAssertEqual(SyscallActivity.build([before], filter: "", errorsOnly: false).map(\.target), ["notes.txt"])
    }

    /// The same thing at even intervals is marked on each of its rounds; every round stays its own row, in place.
    func testRecurringActivitiesAreMarked() {
        var recs: [SyscallRecord] = []
        for round in 0..<4 {
            recs.append(stat(round * 10, "/repo/.git/HEAD", UInt64(round) * 1_000_000_000 + UInt64(round) * 3_000_000))
        }
        // The same path at uneven times, and one seen once: no rhythm.
        for (i, t) in [UInt64(100_000_000), 900_000_000, 3_500_000_000].enumerated() { recs.append(stat(100 + i, "/etc/hosts", t)) }
        recs.append(stat(200, "/etc/once", 2_000_000_000))
        let groups = SyscallActivity.build(recs, filter: "", errorsOnly: false)
        XCTAssertEqual(groups.map(\.id), [102, 30, 20, 200, 10, 101, 100, 0])
        let beat = groups.filter { $0.target == "/repo/.git/HEAD" }
        XCTAssertEqual(beat.map { $0.recurrence?.round }, [4, 3, 2, 1])
        XCTAssertEqual(beat[0].recurrence, SyscallActivity.Recurrence(period: 1_003_000_000, round: 4, rounds: 4))
        XCTAssertTrue(beat[0].detail.hasSuffix("↻ every 1.0 s (4 of 4)"), beat[0].detail)
        XCTAssertTrue(groups.filter { $0.target != "/repo/.git/HEAD" }.allSatisfy { $0.recurrence == nil })
        // Filtering by the mark's words shows the loop alone.
        XCTAssertEqual(SyscallActivity.matching(groups, "every 1.0 s").map(\.id), [30, 20, 10, 0])
    }

    /// Time on a CPU comes from the context switches the helper marks as the process's: the thread's own when it
    /// leaves, another thread's when it is put back on.
    func testTimeOnCPUFromContextSwitches() {
        let read: UInt32 = 0x040c_0000 | 3 << 2, sched: UInt32 = 0x0140_0000
        var dec = SyscallDecoder()
        let out = dec.feed([
            KdebugEvent(ts: 100, debugid: read | 1, arg: [3, 0, 0, 0], thread: 7),
            // A "switch" to itself: it keeps its CPU.
            KdebugEvent(ts: 120, debugid: sched, arg: [0, 7, 0, 0], thread: 7, ours: 3),
            KdebugEvent(ts: 150, debugid: sched, arg: [0, 99, 0, 0], thread: 7, ours: 1),
            // Another process's thread hands the CPU to thread 7.
            KdebugEvent(ts: 400, debugid: sched, arg: [0, 7, 0, 0], thread: 99, ours: 2),
            KdebugEvent(ts: 450, debugid: read | 2, arg: [0, 10, 0, 0], thread: 7),
            // Thread 8 of the process only computes: known by the scheduler leaving it on, then by its switches.
            KdebugEvent(ts: 500, debugid: sched, arg: [0, 8, 0, 0], thread: 8, ours: 3),
            KdebugEvent(ts: 560, debugid: sched, arg: [0, 99, 0, 0], thread: 8, ours: 1),
        ])
        XCTAssertEqual(out.first?.duration, 350)
        XCTAssertEqual(out.first?.cpu, 100)
        XCTAssertTrue(dec.cpuMeasured)
        XCTAssertEqual(dec.takeRuns(), [SyscallDecoder.Run(thread: 7, start: 100, end: 150), SyscallDecoder.Run(thread: 8, start: 500, end: 560)])
        XCTAssertEqual(dec.openRuns(), [SyscallDecoder.Run(thread: 7, start: 400, end: 560)])

        var cpu = TraceCPU()
        cpu.add([SyscallDecoder.Run(thread: 7, start: 100, end: 150)], open: [SyscallDecoder.Run(thread: 7, start: 400, end: 450)], measured: true)
        XCTAssertEqual(cpu.total(7), 100)
        XCTAssertEqual(cpu.time(in: 120...420, threads: []), 50)
        XCTAssertEqual(cpu.time(in: 0...500, threads: [8]), 0)
        let row = SyscallSummaryRow.build(out)[0]
        XCTAssertEqual([row.cpuNanos, row.offNanos], [100, 250])

        // Events lost: who was on a CPU across the hole isn't known, so nothing is claimed from then on.
        _ = dec.feed([KdebugEvent(ts: 600, debugid: KdebugEvent.lostEvents, arg: [], thread: 0)])
        XCTAssertFalse(dec.cpuMeasured)
        XCTAssertEqual(dec.endRuns(), [])
        // Switches nobody marked (an older helper, ktrace): not measured, and no call gets a time.
        var old = SyscallDecoder()
        let alone = old.feed([
            KdebugEvent(ts: 100, debugid: read | 1, arg: [3, 0, 0, 0], thread: 7),
            KdebugEvent(ts: 150, debugid: sched, arg: [0, 99, 0, 0], thread: 7),
            KdebugEvent(ts: 450, debugid: read | 2, arg: [0, 10, 0, 0], thread: 7),
        ])
        XCTAssertFalse(old.cpuMeasured)
        XCTAssertNil(alone.first?.cpu)
        XCTAssertEqual(alone.first?.blocked, true)
    }

    /// A connection over before anyone can ask about its socket keeps the endpoints the helper read as its
    /// connect came by; the next socket with the same number doesn't inherit them.
    func testSocketKeepsEndpointsReadAtItsConnect() {
        func call(_ id: Int, _ name: String, _ time: UInt64, args: [UInt64], ret: UInt64 = 0) -> SyscallRecord {
            var r = SyscallRecord(id: id, start: time, end: time + 5, thread: 7, mach: false, number: 0, name: name, args: args, ret: ret)
            SyscallFormat.fill(&r)
            return r
        }
        let tcp: [UInt64] = [UInt64(AF_INET), UInt64(SOCK_STREAM), 0]
        var recs = [call(1, "socket", 0, args: tcp, ret: 5), call(2, "connect", 100, args: [5, 0, 16]),
                    call(3, "sendto", 200, args: [5, 0, 18, 0]), call(4, "close", 300, args: [5]),
                    call(5, "socket", 400, args: tcp, ret: 5), call(6, "sendto", 500, args: [5, 0, 18, 0])]
        var fds = FdLabeler()
        // The lookup comes after the close and the new socket: it has nothing for the first connection.
        fds.label(&recs, sockets: { [SeenSocket(fd: 5, time: 100, label: "TCP 10.0.0.2:50000->1.1.1.1:80")] }) { _ in [:] }
        XCTAssertEqual(recs.map(\.firstFDLabel), [nil, "TCP 10.0.0.2:50000->1.1.1.1:80", "TCP 10.0.0.2:50000->1.1.1.1:80",
                                                   "TCP 10.0.0.2:50000->1.1.1.1:80", nil, "TCP socket"])
        XCTAssertEqual(SeenSocket(key: SeenSocket(fd: 5, time: 100, label: "x").key, label: "x"), SeenSocket(fd: 5, time: 100, label: "x"))
        XCTAssertNil(SeenSocket(key: "5", label: "x"))
    }

    /// Network.framework's NECP and Skywalk calls and mac_syscall's policy are named; psynch_cvwait's errno has
    /// libpthread's bits over it, and a timed wait running out is not a failure.
    func testNamesNetworkCallsPolicyAndCondvarTimeouts() {
        func call(_ name: String, _ args: [UInt64], error: Int64 = 0) -> SyscallRecord {
            var r = SyscallRecord(id: 1, start: 0, end: 5, thread: 7, mach: false, number: 0, name: name, args: args, ret: 0)
            r.error = error
            SyscallFormat.fill(&r)
            return r
        }
        XCTAssertEqual(call("necp_client_action", [6, 18, 0x74c62f12e0, 16]).argValues, ["6", "REMOVE_FLOW", "0x74c62f12e0", "16"])
        XCTAssertEqual(call("channel_sync", [9, 2, 5, 0x16d46a760]).argValues, ["9", "CHANNEL_SYNC_UPP", "CHANNEL_SYNCF_ALLOC|CHANNEL_SYNCF_PURGE"])
        XCTAssertEqual(call("channel_sync", [9, 0, 3, 0]).argValues[1], "CHANNEL_SYNC_TX")

        // strerror's text for a known errno is a constant in libsystem_c, so in the shared cache.
        let inCache = UInt64(UInt(bitPattern: strerror(EPERM)))
        XCTAssertEqual(call("mac_syscall", [inCache, 180, 0x16d353958]).argValues, ["\"Operation not permitted\"", "180", "0x16d353958"])
        let heap = strdup("Quarantine")!
        defer { free(heap) }
        XCTAssertEqual(call("mac_syscall", [UInt64(UInt(bitPattern: heap)), 180, 0]).argValues.first, "0x" + String(UInt(bitPattern: heap), radix: 16))

        let timedOut = call("psynch_cvwait", [0x74c5c52478, 0, 0, 0], error: 316)
        XCTAssertFalse(timedOut.failed)
        XCTAssertEqual(timedOut.resultText, "-1 ETIMEDOUT (Operation timed out) | ECVCLEARED")
        XCTAssertFalse(call("psynch_cvwait", [0, 0, 0, 0], error: Int64(EINTR)).failed)
        let bad = call("psynch_cvwait", [0, 0, 0, 0], error: Int64(EINVAL) | 0x200)
        XCTAssertTrue(bad.failed)
        XCTAssertFalse(bad.expected)
        XCTAssertEqual(bad.resultText, "-1 EINVAL (Invalid argument) | ECVPREPOST")
        XCTAssertTrue(timedOut.expected)
    }

    /// Errors that are the answer the caller asked for are muted, not failures; the same errno from another
    /// call still fails.
    func testErrorsThatAreAnswers() {
        func call(_ name: String, _ args: [UInt64], error: Int64 = 0, ret: UInt64 = 0, mach: Bool = false) -> SyscallRecord {
            var r = SyscallRecord(id: 1, start: 0, end: 5, thread: 7, mach: mach, number: 0, name: name, args: args, ret: ret)
            r.error = error
            SyscallFormat.fill(&r)
            return r
        }
        let answers: [(SyscallRecord, String)] = [
            (call("mkdirat", [UInt64(bitPattern: -2), 0, 0o777], error: Int64(EEXIST)), "-1 EEXIST: already exists"),
            (call("mkdir", [0, 0o755], error: Int64(EEXIST)), "-1 EEXIST: already exists"),
            (call("readlink", [0, 0, 1026], error: Int64(EINVAL)), "-1 EINVAL: not a symlink"),
            (call("gettid", [0, 0], error: Int64(ESRCH)), "-1 ESRCH: no identity of its own (the process's applies)"),
            (call("ulock_wake", [0x1000002, 0x201eda32c, 0], ret: UInt64(bitPattern: Int64(-ENOENT))), "-2 (ENOENT): nobody was waiting"),
        ]
        for (r, text) in answers {
            XCTAssertFalse(r.failed, r.name)
            XCTAssertTrue(r.expected, r.name)
            XCTAssertEqual(r.resultText, text)
        }
        let timeout = call("mach_msg2_trap", [0, UInt64(MACH_RCV_MSG | MACH_RCV_TIMEOUT), 0, 0], error: 0x10004003, mach: true)
        XCTAssertTrue(timeout.expected)
        XCTAssertFalse(timeout.failed)

        for r in [call("mkdirat", [0, 0, 0o777], error: Int64(EACCES)), call("open", [0, 0, 0], error: Int64(EEXIST)),
                  call("readlinkat", [0, 0, 0], error: Int64(ENOENT))] {
            XCTAssertTrue(r.failed, r.name)
            XCTAssertFalse(r.expected, r.name)
        }
        XCTAssertFalse(call("mkdirat", [0, 0, 0o777]).expected)
    }

    func testScopeNarrowsByKindAndStretch() {
        let context = SyscallActivity.Context()
        let lookup = stat(1, "/a", 100)
        let send = record(2, "sendto", 200, label: "TCP 10.0.0.1:50000->1.2.3.4:443")
        let read = record(3, "read", 300, label: "TCP 10.0.0.1:50000->1.2.3.4:443")
        let file = record(4, "read", 400)
        let unknown = record(7, "read", 450, label: nil)
        let pipe = record(5, "write", 500, label: "pipe")
        let wait = record(6, "kevent", 600, label: nil)
        let all = [lookup, send, read, file, pipe, wait]
        XCTAssertEqual(all.map { SyscallActivity.kind($0, context) }, [.files, .network, .network, .files, .other, .waits])
        XCTAssertEqual(SyscallActivity.kind(unknown, context), .other)
        let network = SyscallActivity.build(all, scope: TraceScope(kinds: [.network]), context: context)
        XCTAssertEqual(network.map { $0.calls.map(\.id) }, [[2, 3]])
        let early = SyscallActivity.build(all, scope: TraceScope(range: 0...250), context: context)
        XCTAssertEqual(early.map { $0.calls.map(\.id) }, [[2], [1]])
    }

    func testOverview() {
        let context = SyscallActivity.Context()
        // Thread 7 waits from 0 to 600 ms, looks five paths up, then waits to the end; thread 8 is parked throughout.
        var first = record(1, "kevent", 0, label: nil)
        first.start = nil; first.end = 600_000_000; first.state = .entryMissed
        var recs = [first]
        for i in 0..<5 { recs.append(stat(10 + i, "/Users/me/tree/f\(i)", 600_000_000 + UInt64(i) * 1_000_000)) }
        var last = record(20, "kevent", 700_000_000, label: nil)
        last.end = nil; last.state = .inProgress
        var parked = record(21, "ulock_wait", 100, thread: 8, label: nil)
        parked.end = 1_000_000_000
        recs += [last, parked]
        let scope = TraceScope()
        let o = TraceOverview.build(recs, scope: scope, context: context,
                                    groups: SyscallActivity.build(recs, scope: scope, context: context), fromStart: true)
        XCTAssertEqual(o.lo, 0)
        XCTAssertEqual(o.hi, 1_000_000_000)
        XCTAssertEqual(o.counts[TraceKind.files.rawValue], 5)
        XCTAssertEqual(o.counts[TraceKind.waits.rawValue], 3)
        XCTAssertEqual(o.bars[0].reduce(0, +), 5)
        XCTAssertEqual(o.bars[0][TraceOverview.bins * 6 / 10], 5)
        XCTAssertEqual(o.sentence, "1.0 s · 2 threads · 5 lookups")

        let part = TraceScope(range: 600_000_000...800_000_000)
        let p = TraceOverview.build(recs, scope: part, context: context,
                                    groups: SyscallActivity.build(recs, scope: part, context: context), fromStart: true)
        XCTAssertTrue(p.sentence.hasPrefix("200 ms selected · 1 thread · 5 lookups"), p.sentence)
        XCTAssertEqual(p.bars, o.bars)
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

    /// Mach calls made inside an OS function the process called (stacks) are one row per function, as BetterDisplay's
    /// display poll is: IOServiceGetMatchingServices, then IOIteratorNext and property reads from several places.
    func testCallsIntoOSFunctions() throws {
        let sendRcv = UInt64(MACH_SEND_MSG | MACH_RCV_MSG)
        let routine = try XCTUnwrap(MIGRoutines.names.firstIndex(of: "task_info"))
        let matching = "IOServiceGetMatchingServices  (IOKit)", next = "IOIteratorNext  (IOKit)"
        let property = "IORegistryEntrySearchCFProperty  (IOKit)"
        var id = 0
        func call(_ t: UInt64, _ api: String, _ site: String, _ name: String = "mach_msg2_trap", receiver: Int32? = nil) -> SyscallRecord {
            id += 1
            var r = SyscallRecord(id: id, start: t, end: t + 5, thread: 7, mach: true, number: 0, name: name,
                                  args: name == "mach_msg2_trap" ? [1, sendRcv, 0x13, 0x203] : [0x203, 0x1503])
            if name == "mach_msg2_trap", receiver == nil { r.kernelRoutine = routine }
            r.receiver = receiver
            r.api = api
            r.site = site
            return r
        }
        var recs: [SyscallRecord] = []
        for round in 0..<3 {
            let t = UInt64(round) * 2_000_000_000
            recs += [call(t, matching, "App + 0x10"), call(t + 6, matching, "App + 0x10"),
                     // A port released inside the call: joins it.
                     call(t + 8, matching, "App + 0x10", "mach_port_deallocate_trap"),
                     call(t + 20, next, "App + 0x20"), call(t + 40, next, "App + 0x20"),
                     call(t + 100, property, "App + 0x30"), call(t + 200, property, "App + 0x40")]
        }
        // Released with no call under way: no row. A message with no API: a row of its own as before.
        recs.append(call(5_000_000_000, matching, "App + 0x99", "mach_port_deallocate_trap"))
        var plain = call(5_100_000_000, "", "", receiver: 42)
        plain.args = [1, UInt64(MACH_SEND_MSG), 0x13, 0x1650b]
        recs.append(plain)

        let context = SyscallActivity.Context(pid: 10, processNames: [42: "cfprefsd"])
        let groups = SyscallActivity.build(recs, scope: TraceScope(), context: context).reversed().map { $0 }
        XCTAssertEqual(groups.map(\.operation), [.api, .api, .api, .api, .api, .api, .api, .api, .api, .message])
        XCTAssertEqual(groups.prefix(3).map(\.target), [matching, next, property])
        XCTAssertEqual(groups[0].calls.count, 3)
        XCTAssertEqual(groups[1].calls.count, 2)
        XCTAssertEqual(groups[2].sites, ["App + 0x30", "App + 0x40"])
        XCTAssertEqual(groups[0].reached, ["task_info (kernel)"])
        XCTAssertTrue(groups[0].detail.hasPrefix("task_info (kernel) · took "), groups[0].detail)
        XCTAssertTrue(groups[0].detail.contains("from App + 0x10 · 3 calls · ↻ every 2.0 s (1 of 3)"), groups[0].detail)
        XCTAssertTrue(groups[2].detail.contains("from 2 places"), groups[2].detail)
        XCTAssertEqual(groups.last?.target, "cfprefsd (42)")
        XCTAssertEqual(SyscallActivity.kind(groups[0].calls[0], context), .messages)
        let sentence = TraceOverview.build(recs, scope: TraceScope(), context: context, groups: groups, fromStart: true).sentence
        XCTAssertTrue(sentence.contains("1 message to 1 destination · 18 kernel calls"), sentence)
    }

    /// Two timers entering through one shared Swift thunk (as BetterDisplay's 1 s and 2 s timers do), each tick
    /// woken by a worker thread: every row a tick starts carries its timer's rhythm and handler, a one-off message
    /// inside a tick included, and the worker's wakeup is marked as that timer's delivery.
    func testTimerTicksNameTheirHandler() {
        let send = UInt64(MACH_SEND_MSG), sendRcv = UInt64(MACH_SEND_MSG | MACH_RCV_MSG)
        var id = 0
        func message(_ t: UInt64, thread: UInt64 = 7, to port: UInt64, receiver: Int32? = nil, trigger: String, inner: String = "") -> SyscallRecord {
            id += 1
            var r = SyscallRecord(id: id, start: t, end: t + 5_000, thread: thread, mach: true, number: 0, name: "mach_msg2_trap",
                                  args: [1, receiver == nil ? send : sendRcv, 0x18, port])
            r.receiver = receiver
            r.trigger = trigger
            r.triggerInner = inner
            return r
        }
        let thunk = "dispatch source · App + 0x38"
        var recs: [SyscallRecord] = []
        for s in 0..<6 {
            let t = UInt64(s) * 1_000_000_000 + 457_000_000
            recs.append(message(t - 500_000, thread: 9, to: 0x3003, trigger: StackSymbols.timerDelivery))
            recs.append(message(t, to: 0x80f, receiver: 1, trigger: thunk, inner: "App + 0xcf"))
            if s == 3 { recs.append(message(t + 100_000, to: 0x17f77, receiver: 443, trigger: thunk, inner: "App + 0xcf")) }
            if s % 2 == 0 {
                recs.append(message(t - 292_500_000, thread: 9, to: 0x3003, trigger: StackSymbols.timerDelivery))
                recs.append(message(t - 292_000_000, to: 0x80f, receiver: 1, trigger: thunk, inner: "App + 0xd1"))
            }
        }
        let context = SyscallActivity.Context(pid: 10, processNames: [1: "launchd", 443: "WindowServer"], portKinds: [0x3003: "own port"])
        let groups = SyscallActivity.build(recs, scope: TraceScope(), context: context).reversed().map { $0 }
        let one = groups.filter { $0.recurrence?.cause == "timer · App + 0xcf" }
        XCTAssertEqual(one.count, 7)
        XCTAssertEqual(one.first?.recurrence?.period, 1_000_000_000)
        let windowServer = try? XCTUnwrap(groups.first { $0.target == "WindowServer (443)" })
        XCTAssertEqual(windowServer?.recurrence?.text, "↻ every 1.0 s (4 of 6) · timer · App + 0xcf")
        let two = groups.filter { $0.recurrence?.cause == "timer · App + 0xd1" }
        XCTAssertEqual(two.map { $0.recurrence!.period }, [2_000_000_000, 2_000_000_000, 2_000_000_000])
        let delivery = groups.filter { $0.target == "Own port" }
        XCTAssertEqual(Set(delivery.compactMap { $0.recurrence?.cause }), ["timer · App + 0xcf (delivery)", "timer · App + 0xd1 (delivery)"])
        // Without triggers, rows keep the rhythm of their own operation and target only.
        let plain = recs.map { r -> SyscallRecord in var r = r; r.trigger = ""; return r }
        XCTAssertNil(SyscallActivity.build(plain, scope: TraceScope(), context: context).first { $0.target == "WindowServer (443)" }?.recurrence)
    }
}
