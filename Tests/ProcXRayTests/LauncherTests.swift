import XCTest
@testable import ProcXRay

final class LauncherTests: XCTestCase {
    func testSplitArguments() {
        XCTAssertEqual(Launcher.splitArguments(""), [])
        XCTAssertEqual(Launcher.splitArguments("  -v   --name x "), ["-v", "--name", "x"])
        XCTAssertEqual(Launcher.splitArguments(#"open "My File.txt" 'it''s' a\ b"#), ["open", "My File.txt", "its", "a b"])
        XCTAssertEqual(Launcher.splitArguments(#"'a\b' "c\"d" """#), [#"a\b"#, #"c"d"#, ""])
    }

    func testExecutable() {
        XCTAssertEqual(Launcher.executable(for: URL(fileURLWithPath: "/System/Applications/TextEdit.app")),
                       "/System/Applications/TextEdit.app/Contents/MacOS/TextEdit")
        XCTAssertEqual(Launcher.executable(for: URL(fileURLWithPath: "/bin/ls")), "/bin/ls")
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-test-\(getpid()).txt")
        FileManager.default.createFile(atPath: plain.path, contents: Data("x".utf8), attributes: [.posixPermissions: 0o644])
        defer { try? FileManager.default.removeItem(at: plain) }
        XCTAssertNil(Launcher.executable(for: plain))
        XCTAssertNil(Launcher.executable(for: URL(fileURLWithPath: "/usr/bin")))
        XCTAssertEqual(Launcher.displayName(for: URL(fileURLWithPath: "/System/Applications/TextEdit.app")), "TextEdit")
    }

    func testSpawnSuspendedThenResume() throws {
        // Suspended: alive but not running until SIGCONT; then /usr/bin/true exits on its own.
        let child = try Launcher.spawnSuspended("/usr/bin/true", arguments: [], name: "true").get()
        usleep(200_000)
        XCTAssertTrue(Native.isSame(child.pid, start: child.start))
        Launcher.resume(child.pid)
        var gone = false
        for _ in 0..<50 where !gone { usleep(50_000); gone = !Native.isSame(child.pid, start: child.start) }
        XCTAssertTrue(gone)
    }

    private func waitForExit(_ pid: Int32) -> Launcher.Exit? {
        for _ in 0..<100 { if let e = Launcher.exit(of: pid) { return e }; usleep(50_000) }
        return nil
    }

    func testExitRecordsStatus() throws {
        let child = try Launcher.spawnSuspended("/usr/bin/false", arguments: [], name: "false").get()
        Launcher.resume(child.pid)
        let exit = try XCTUnwrap(waitForExit(child.pid))
        XCTAssertFalse(exit.codeSigning)
        XCTAssertEqual((exit.status >> 8) & 0xff, 1)
        XCTAssertNil(exit.problem)
    }

    func testAppleAppIsKilledForCodeSigning() throws {
        // With SIP on, Apple's apps have launch constraints that kill a direct spawn before its first instruction.
        let child = try Launcher.spawnSuspended("/System/Applications/Chess.app/Contents/MacOS/Chess", arguments: [], name: "Chess").get()
        Launcher.resume(child.pid)
        guard let exit = waitForExit(child.pid) else {
            kill(child.pid, SIGKILL)
            throw XCTSkip("Chess ran: no launch constraints here (SIP off?)")
        }
        XCTAssertTrue(exit.codeSigning)
        XCTAssertNotNil(exit.problem)
    }
}
