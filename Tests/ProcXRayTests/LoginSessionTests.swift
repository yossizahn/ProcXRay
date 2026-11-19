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

    func testOwnSessionReads() {
        XCTAssertNotNil(LoginSessions.own)
        XCTAssertEqual(LoginSessions.asid(getpid()), LoginSessions.own)
        let d = LoginSessions.describe([LoginSessions.own!])
        XCTAssertEqual(d[LoginSessions.own!]?.isOwn, true)
    }
}
