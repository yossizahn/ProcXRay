import XCTest
@testable import ProcXRay

final class RegistrationsTests: XCTestCase {
    /// Trimmed from `sfltool dumpbtm` on macOS 27.2: an SMAppService login item and daemon (paths relative to
    /// their app), a legacy agent (absolute paths), and an app record, which is never matched to a process.
    private let dump = """
    ========================
     Records for UID 501 : 3A2B1C0D-0000-0000-0000-000000000000
    ========================

     #1:
                     UUID: 0A4F4A02-4C56-45CE-992D-AF104A65AB8D
                     Name: 1Password Browser Helper
                     Type: login item (0x4)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 4.2BUA8C4S2C.com.1password.browser-helper
                      URL: Contents/Library/LoginItems/1Password Browser Helper.app
        Parent Identifier: 2.com.1password.1password

     #2:
                     UUID: CB36EA9F-BB5F-4251-B8FD-C2E48E6AD9AD
                     Name: BridgeService
                     Type: legacy agent (0x10008)
              Disposition: [disabled, allowed, notified] (0xa)
               Identifier: 8.com.jetbrains.AppCode.BridgeService
                      URL: /Users/501/Library/LaunchAgents/com.jetbrains.AppCode.BridgeService.plist
          Executable Path: /Users/501/Applications/Rider.app/Contents/bin/BridgeService

     #3:
                     UUID: 8A0D5472-152E-4924-908B-5D63F7B45F70
                     Name: ProcXRay
                     Type: daemon (0x10)
              Disposition: [enabled, allowed, not notified] (0x3)
               Identifier: 16.local.procxray.helper
          Executable Path: Contents/MacOS/ProcXRay

     #4:
                     UUID: 547A2CC6-9C60-445A-8060-F052435E9732
                     Name: AlDente
                     Type: app (0x2)
              Disposition: [disabled, allowed, notified] (0xa)
               Identifier: 2.com.apphousekitchen.aldente-pro
                      URL: /Applications/AlDente.app
    """

    private func proc(_ path: String, label: String? = nil, domain: String? = nil, ls: String? = nil) -> ProcInfo {
        var p = ProcInfo(pid: 100, ppid: 1, pgid: 100, uid: 501, user: "u", comm: "x", path: path,
                         start: Date(), stat: 2, pflags: 0)
        p.launchdLabel = label
        p.launchdDomain = domain
        p.lsType = ls
        p.lsAppName = ls == nil ? nil : "X"
        return p
    }

    private func kinds(_ p: ProcInfo) -> [Registration.Kind] {
        Registrations.of(p, btm: BTM.itemIndex(BTM.parse(dump))).map(\.kind)
    }

    func testIndexKeepsOnlyWhatLaunchdRuns() {
        let index = BTM.itemIndex(BTM.parse(dump))
        XCTAssertEqual(Set(index.keys), [
            "label:2BUA8C4S2C.com.1password.browser-helper",
            "label:com.jetbrains.AppCode.BridgeService",
            "path:/Users/501/Applications/Rider.app/Contents/bin/BridgeService",
            "label:local.procxray.helper",
        ])
    }

    func testLoginItemIsAppAndBackgroundItem() {
        let p = proc("/Applications/1Password.app/Contents/Library/LoginItems/1Password Browser Helper.app/Contents/MacOS/1Password Browser Helper",
                     label: "2BUA8C4S2C.com.1password.browser-helper", domain: "gui", ls: "UIElement")
        XCTAssertEqual(kinds(p), [.launchServices, .launchdJob, .backgroundItem])
    }

    func testLegacyAgentMatchesByPathAndWarnsWhenDisabled() {
        let p = proc("/Users/501/Applications/Rider.app/Contents/bin/BridgeService")
        let r = Registrations.of(p, btm: BTM.itemIndex(BTM.parse(dump)))
        XCTAssertEqual(r.map(\.kind), [.backgroundItem])
        XCTAssertEqual(r.first?.warning, true)
    }

    func testAppJobAndXPCService() {
        XCTAssertEqual(kinds(proc("/Applications/Foo.app/Contents/MacOS/Foo", label: "application.com.foo.1.2", domain: "gui", ls: "Foreground")),
                       [.launchServices, .launchdAppJob])
        // An XPC service's job comes from its bundle: the XPC glyph, not a declared-job one.
        XCTAssertEqual(kinds(proc("/Applications/Foo.app/Contents/XPCServices/Bar.xpc/Contents/MacOS/Bar", label: "com.foo.bar")),
                       [.xpcService])
        let host = { (path: String) in Registrations.of(self.proc(path), btm: [:]).first?.facts.first { $0.label == "Ships in" }?.value }
        XCTAssertEqual(host("/Applications/Foo.app/Contents/XPCServices/Bar.xpc/Contents/MacOS/Bar"), "Foo")
        XCTAssertEqual(host("/System/Library/PrivateFrameworks/C.framework/Versions/A/XPCServices/S.xpc/Contents/MacOS/S"), "C.framework")
    }

    func testNothingBeforeBackgroundItemsLoad() {
        let p = proc("/Users/501/Applications/Rider.app/Contents/bin/BridgeService")
        XCTAssertTrue(Registrations.of(p, btm: [:]).isEmpty)
    }
}
