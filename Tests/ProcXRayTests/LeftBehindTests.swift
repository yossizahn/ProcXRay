import XCTest
@testable import ProcXRay

final class LeftBehindTests: XCTestCase {
    /// lsappinfo for an app that quit leaving the launchd agent it bootstrapped (Rex's server), plus a live
    /// service that loaded one of the same jobs.
    private let lsText = """
     71) "Rex Beta" ASN:0x0-0x2a82a8: 
        bundleID="com.superlogical.rex"
        pid = 20807 token=[sess=100015 pid=20807 uid:501,501,501 g:20,20 pV:43826] type="Foreground" flavor=3 Version="1996" fileType="APPL" creator="????" Arch=ARM64 (exited-with-subordinates) 
        coalition: 5315
        loadedJobs:"com.superlogical.rex.server.53b9" "com.apple.CoreSimulator.simdiskimaged" 
     94) "com.apple.CoreSimulator.CoreSimulatorService" ASN:0x0-0x368368: 
        pid = 32103 token=[sess=100039 pid=32103 uid:501,501,501 g:20,20 pV:65578] type="BackgroundOnly" flavor=3 Version="1174.21" fileType="XPC!" creator="????" Arch=ARM64 
        loadedJobs:"com.apple.CoreSimulator.simdiskimaged" 
    """

    private func proc(_ pid: pid_t, label: String, coalition: UInt64) -> ProcInfo {
        var p = ProcInfo(pid: pid, ppid: 1, pgid: pid, uid: 501, user: "u", comm: "x", path: nil,
                         start: Date(), stat: 2, pflags: 0)
        p.launchdLabel = label
        p.coalition = coalition
        p.jetsamCoalition = coalition
        return p
    }

    func testParsesLoadedJobs() {
        let apps = LSAppInfo.parse(lsText)
        XCTAssertEqual(apps.first?.loadedJobs, ["com.superlogical.rex.server.53b9", "com.apple.CoreSimulator.simdiskimaged"])
        XCTAssertEqual(apps.last?.loadedJobs, ["com.apple.CoreSimulator.simdiskimaged"])
    }

    func testJobLoadedByExitedAppIsLeftBehind() {
        let apps = LSAppInfo.parse(lsText)
        let procs: [pid_t: ProcInfo] = [
            20826: proc(20826, label: "com.superlogical.rex.server.53b9", coalition: 9001),
            32109: proc(32109, label: "com.apple.CoreSimulator.simdiskimaged", coalition: 9002),
        ]
        let ghosts = Store.ghosts(procs: procs, lsApps: apps)
        XCTAssertEqual(ghosts.count, 1)
        XCTAssertEqual(ghosts.first?.name, "Rex Beta")
        // simdiskimaged is also loaded by a live service, so it isn't Rex's leftover.
        XCTAssertEqual(ghosts.first?.survivors.map(\.pid), [20826])
    }
}
