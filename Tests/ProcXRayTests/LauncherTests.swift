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
}
