import XCTest
@testable import ProcXRay

final class LoginSessionTests: XCTestCase {
    private let own = LoginSession(asid: 100019, kind: .login, flags: 0x6030, user: "me", onScreen: true, isOwn: true)
    private let system = LoginSession(asid: 100001, kind: .system, flags: 0x1)
    private let ssh = LoginSession(asid: 100129, kind: .remote, flags: 0x5020, user: "admin")
    private let other = LoginSession(asid: 100746, kind: .login, flags: 0x2030, user: "atlas")

    private func proc(_ pid: pid_t, ppid: pid_t, _ s: LoginSession, path: String) -> ProcInfo {
        var p = ProcInfo(pid: pid, ppid: ppid, pgid: pid, uid: 501, user: "u", comm: (path as NSString).lastPathComponent,
                         path: path, start: Date(), stat: 2, pflags: 0)
        p.asid = s.asid
        p.session = s
        return p
    }

    /// An SSH login's processes hang off sshd, a daemon in the boot session; another GUI login's agent is a child of
    /// launchd. Both go under Other logins, one group per login, and the own login's processes stay where they were.
    func testOtherLoginsGetTheirOwnGroups() {
        let procs: [pid_t: ProcInfo] = [
            100: proc(100, ppid: 1, system, path: "/usr/sbin/sshd"),
            200: proc(200, ppid: 100, ssh, path: "/usr/libexec/sshd-session"),
            201: proc(201, ppid: 200, ssh, path: "/bin/zsh"),
            300: proc(300, ppid: 1, other, path: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"),
            400: proc(400, ppid: 1, own, path: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"),
        ]
        let roots = SmartTree.build(.init(procs: procs, lsApps: []))
        let others = roots.first { $0.category == .otherLogins }
        XCTAssertEqual(others?.children?.map(\.title), ["atlas's login", "SSH login: admin"])
        func pids(_ n: ProcNode) -> Set<pid_t> { Set([n.proc?.pid].compactMap { $0 } + (n.children ?? []).flatMap(pids)) }
        XCTAssertEqual(others.map(pids), [200, 201, 300])
        let rest = roots.filter { $0.category != .otherLogins }.reduce(Set<pid_t>()) { $0.union(pids($1)) }
        XCTAssertEqual(rest, [100, 400])
    }

    func testOwnAuditToken() throws {
        let t = try XCTUnwrap(AuditToken.read(getpid()))
        XCTAssertEqual(t.pid, getpid())
        XCTAssertEqual(t.euid, geteuid())
        XCTAssertEqual(t.rgid, getgid())
        XCTAssertEqual(t.asid, LoginSessions.own)
        XCTAssertNotNil(AuditSessionRecord.read(t.asid))
        XCTAssertNil(AuditToken.read(0))
    }

    func testOwnTaskDetail() throws {
        let d = try XCTUnwrap(TaskDetail.read(getpid()))
        XCTAssertEqual(d.token?.pid, getpid())
        let vm = try XCTUnwrap(d.vm)
        XCTAssertGreaterThan(vm.footprint, 0)
        XCTAssertGreaterThan(vm.internal, 0)
        XCTAssertEqual(d.basic?.suspendCount, 0)
        XCTAssertEqual(d.extmod?.anyFromOutside, false)
        XCTAssertNotEqual(d.extmod?.uuid, UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)).uuidString)
        // Only the token without `full`.
        XCTAssertNil(TaskDetail.read(getpid(), full: false)?.vm)
    }

    /// A child started suspended (POSIX_SPAWN_START_SUSPENDED) has a suspend count of 1, and 0 once SIGCONT resumes it.
    func testSuspendedChild() throws {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_START_SUSPENDED))
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("30"), nil]
        defer { argv.forEach { free($0) } }
        XCTAssertEqual(posix_spawn(&pid, "/bin/sleep", nil, &attr, argv, nil), 0)
        defer { kill(pid, SIGKILL); var st: Int32 = 0; waitpid(pid, &st, 0) }
        XCTAssertEqual(TaskBasic.suspendCount(pid), 1)
        kill(pid, SIGCONT)
        usleep(100_000)
        XCTAssertEqual(TaskBasic.suspendCount(pid), 0)
    }

    func testTerminalAddress() {
        // 192.168.64.1, as at_addr[0] holds it (network byte order in memory).
        var r = AuditSessionRecord(auid: 501, flags: 0x5020, maskSuccess: 0, maskFailure: 0, termPort: 22, termType: 4,
                                   termAddr: [UInt32(bigEndian: 0xC0A8_4001), 0, 0, 0])
        XCTAssertEqual(r.address, "192.168.64.1")
        XCTAssertEqual(r.terminalText, "port 22 from 192.168.64.1")
        XCTAssertEqual(r.flagText, "HAS_TTY, IS_REMOTE, HAS_AUTHENTICATED")
        r.termAddr = [0, 0, 0, 0]
        XCTAssertNil(r.address)
        r.flags = 0x2030
        r.termPort = 0x0300_0002
        XCTAssertEqual(r.terminalText, "/dev/null (device 3,2)")
    }

    func testOwnSessionReads() {
        XCTAssertNotNil(LoginSessions.own)
        XCTAssertEqual(LoginSessions.asid(getpid()), LoginSessions.own)
        let d = LoginSessions.describe([LoginSessions.own!])
        XCTAssertEqual(d[LoginSessions.own!]?.isOwn, true)
    }
}
