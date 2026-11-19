import XCTest
@testable import ProcXRay

final class LaunchTests: XCTestCase {
    /// Runs a request to the end and collects its piped output.
    private func run(_ r: Launcher.Request) throws -> (out: String, err: String, exit: Launcher.Exit) {
        let s = try Launcher.spawn(r).get()
        func drain(_ fd: Int32?) -> String {
            guard let fd else { return "" }
            defer { close(fd) }
            var data = Data(), buf = [UInt8](repeating: 0, count: 4096)
            while true { let n = read(fd, &buf, buf.count); if n <= 0 { break }; data.append(contentsOf: buf[0..<n]) }
            return String(decoding: data, as: UTF8.self)
        }
        let out = drain(s.stdout), err = drain(s.stderr)
        var exit: Launcher.Exit?
        for _ in 0..<100 where exit == nil { exit = Launcher.exit(of: s.child.pid); if exit == nil { usleep(20_000) } }
        return (out, err, try XCTUnwrap(exit))
    }

    private func shell(_ script: String) -> Launcher.Request {
        var r = Launcher.Request(path: "/bin/sh", argv: ["/bin/sh", "-c", script], environment: ["PATH": "/usr/bin:/bin"], name: "sh")
        r.stdout = .pipe
        r.stderr = .pipe
        return r
    }

    func testPipesEnvironmentWorkingDirectoryAndArgv0() throws {
        var r = shell("echo \"$0 $FOO\"; pwd; echo oops >&2; exit 3")
        r.argv = ["renamed", "-c", r.argv[2]]
        r.environment["FOO"] = "bar"
        r.workingDirectory = "/private/tmp"
        let (out, err, exit) = try run(r)
        XCTAssertEqual(out, "renamed bar\n/private/tmp\n")
        XCTAssertEqual(err, "oops\n")
        XCTAssertEqual((exit.status >> 8) & 0xff, 3)
        XCTAssertEqual(exit.summary, "It exited with status 3.")
    }

    func testStderrSameAsStdoutAndFiles() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("launch-test-\(getpid()).txt").path
        defer { unlink(file) }
        var r = shell("echo one; echo two >&2")
        r.stdout = .file(file, append: false)
        r.stderr = .sameAsStdout
        _ = try run(r)
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "one\ntwo\n")
    }

    func testSpawnAttributes() throws {
        var r = shell("ps -o pid=,pgid=,sess= -p $$")
        r.spawn.newSession = true
        let (out, _, _) = try run(r)
        let f = out.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(f.count, 3)
        XCTAssertEqual(f[0], f[1], "its own process group")
    }

    func testTrampolineSettings() throws {
        let exec = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/pxr-exec").path
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: exec), "pxr-exec not built (swift build --product pxr-exec)")
        setenv("PXR_EXEC", exec, 1)
        defer { unsetenv("PXR_EXEC") }
        var r = shell("ulimit -n; umask; echo $0")
        r.argv[0] = "named"
        r.process.limits["nofile"] = .init(soft: "77", hard: "")
        r.process.umask = "027"
        r.process.nice = 4
        let (out, err, _) = try run(r)
        XCTAssertEqual(out, "77\n0027\nnamed\n", err)

        var bad = shell("true")
        bad.process.limits["nofile"] = .init(soft: "x", hard: "")
        let (_, err2, exit2) = try run(bad)
        XCTAssertTrue(err2.contains("pxr-exec: bad limit"), err2)
        XCTAssertEqual((exit2.status >> 8) & 0xff, 127)
    }

    func testEnvironmentResolution() {
        var s = LaunchSpec()
        s.environmentBase = .empty
        s.environment = "A=1\n# comment\n\nB=x=y\n-A\nC="
        XCTAssertEqual(s.resolvedEnvironment(user: .current), ["B": "x=y", "C": ""])
        s.environmentBase = .login
        let env = s.resolvedEnvironment(user: .current)
        XCTAssertEqual(env["USER"], NSUserName())
        XCTAssertEqual(env["B"], "x=y")
        XCTAssertEqual(s.addedEnvironment, ["B": "x=y", "C": ""])
    }

    func testProcessSettingsArguments() {
        var p = ProcessSettings()
        XCTAssertTrue(p.isEmpty)
        p.limits["nofile"] = .init(soft: "256", hard: "inf")
        p.limits["cpu"] = .init(soft: "", hard: "")
        p.umask = "077"
        p.darwinBackground = true
        p.ioPolicy = .throttle
        XCTAssertFalse(p.isEmpty)
        XCTAssertEqual(p.execArguments, ["-r", "nofile=256:inf", "-u", "077", "-b", "-i", "3"])
    }

    func testLaunchdPlist() {
        var s = LaunchSpec()
        s.arguments = "a 'b c'"
        s.environment = "FOO=1"
        s.workingDirectory = "/tmp"
        s.launchd.processType = .Background
        s.launchd.nice = 5
        s.launchd.limits = ["nofile": .init(soft: "77", hard: "")]
        let files = LaunchMethods.OutputFiles(stdout: "/tmp/o", stderr: "/tmp/o")
        let p = LaunchMethods.Launchd.plist(s, executable: "/bin/echo", label: "x.y", output: files, stopped: true)
        XCTAssertEqual(p["ProgramArguments"] as? [String], ["/bin/echo", "a", "b c"])
        XCTAssertEqual(p["EnvironmentVariables"] as? [String: String], ["FOO": "1"])
        XCTAssertEqual(p["ProcessType"] as? String, "Background")
        XCTAssertEqual(p["Nice"] as? Int, 5)
        XCTAssertEqual(p["SoftResourceLimits"] as? [String: Int], ["NumberOfFiles": 77])
        XCTAssertNil(p["HardResourceLimits"])
        XCTAssertEqual(p["WaitForDebugger"] as? Bool, true)
        XCTAssertEqual(p["StandardOutPath"] as? String, "/tmp/o")
        XCTAssertEqual(LaunchMethods.Launchd.field("x = {\n\tstate = running\n\tpid = 42\n\t\tpid = 7\n}", "pid"), "42")
    }

    func testOpenArguments() {
        var s = LaunchSpec()
        s.arguments = "-x"
        s.environment = "B=2\nA=1"
        s.open.newInstance = true
        s.open.documents = "/tmp/f.txt\nhttps://example.com"
        let a = LaunchMethods.openArguments(s, app: "/Applications/X.app", output: .init(stdout: "/tmp/o", stderr: nil))
        XCTAssertEqual(a, ["-n", "-W", "--env", "A=1", "--env", "B=2", "--stdout", "/tmp/o", "-a", "/Applications/X.app",
                           "/tmp/f.txt", "https://example.com", "--args", "-x"])
    }

    func testSpecDecodesOlderSaves() throws {
        let s = try JSONDecoder().decode(LaunchSpec.self, from: Data(#"{"path":"/bin/ls","method":"launchd"}"#.utf8))
        XCTAssertEqual(s.path, "/bin/ls")
        XCTAssertEqual(s.method, .launchd)
        XCTAssertEqual(s.stdout, .show)
    }
}

/// Loads a real launchd job in the user's GUI domain: only with PXR_LAUNCHD_TEST=1.
final class LaunchdJobTests: XCTestCase {
    func testStoppedJobRunsWithItsSettings() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PXR_LAUNCHD_TEST"] == "1", "set PXR_LAUNCHD_TEST=1 to load a launchd job")
        var s = LaunchSpec()
        s.method = .launchd
        s.arguments = #"-c "ulimit -n; umask; echo $FOO; pwd""#
        s.environment = "FOO=fromjob"
        s.workingDirectory = "/private/tmp"
        s.launchd.umask = "027"
        s.launchd.limits = ["nofile": .init(soft: "77", hard: "")]
        let files = LaunchMethods.outputFiles(s)
        let (child, label) = try LaunchMethods.Launchd.start(s, executable: "/bin/sh", name: "pxr-test-sh", output: files, stopped: true).get()
        defer { LaunchMethods.Launchd.remove(label) }
        XCTAssertEqual(Native.process(child.pid).map { Int($0.stat) }, Int(SSTOP), "WaitForDebugger: stopped before it runs")
        Launcher.resume(child.pid)
        for _ in 0..<50 where Native.isSame(child.pid, start: child.start) { usleep(50_000) }
        usleep(200_000)
        XCTAssertEqual(try String(contentsOfFile: try XCTUnwrap(files.stdout), encoding: .utf8), "77\n0027\nfromjob\n/private/tmp\n")
    }
}
