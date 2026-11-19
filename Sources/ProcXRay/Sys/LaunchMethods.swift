import AppKit
import Foundation

/// The launch methods besides posix_spawn: a launchd job, Launch Services, and /usr/bin/open. Each gives back the
/// process it started (found by pid where the method doesn't say), and where its stdout and stderr went.
enum LaunchMethods {
    /// Where a launched program's stdout and stderr go when they're shown but the method only takes a file path
    /// (launchd, open): files in a directory of their own, followed while it runs.
    struct OutputFiles {
        var stdout: String?
        var stderr: String?
        /// Files to follow: (path, 1 or 2).
        var shown: [(String, Int)] = []
    }

    static func outputFiles(_ spec: LaunchSpec) -> OutputFiles {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("launch-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var o = OutputFiles()
        switch spec.stdout {
        case .null, .stdout: o.stdout = nil
        case .file: o.stdout = spec.stdoutPath.isEmpty ? nil : (spec.stdoutPath as NSString).expandingTildeInPath
        case .show:
            let p = dir.appendingPathComponent("stdout").path
            FileManager.default.createFile(atPath: p, contents: nil)
            o.stdout = p; o.shown.append((p, 1))
        }
        switch spec.stderr {
        case .null: o.stderr = nil
        case .stdout: o.stderr = o.stdout
        case .file: o.stderr = spec.stderrPath.isEmpty ? nil : (spec.stderrPath as NSString).expandingTildeInPath
        case .show:
            let p = dir.appendingPathComponent("stderr").path
            FileManager.default.createFile(atPath: p, contents: nil)
            o.stderr = p; o.shown.append((p, 2))
        }
        return o
    }

    // MARK: launchd

    /// A job in the user's GUI domain, named after the program. One label per program: launching it again
    /// replaces the job.
    enum Launchd {
        static func label(for name: String) -> String {
            let safe = name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
            return "\(HelperConfig.bundleID).launch.\(String(safe).lowercased())"
        }
        static var domain: String { "gui/\(getuid())" }

        /// The job's launchd.plist (man launchd.plist).
        static func plist(_ spec: LaunchSpec, executable: String, label: String, output: OutputFiles, stopped: Bool) -> [String: Any] {
            let k = spec.launchd
            var p: [String: Any] = [
                "Label": label,
                "Program": executable,
                "ProgramArguments": [spec.argv0.isEmpty ? executable : spec.argv0] + spec.argumentList,
                "RunAtLoad": true,
            ]
            if !spec.workingDirectory.isEmpty { p["WorkingDirectory"] = (spec.workingDirectory as NSString).expandingTildeInPath }
            let env = spec.addedEnvironment
            if !env.isEmpty { p["EnvironmentVariables"] = env }
            if spec.stdin == .file, !spec.stdinPath.isEmpty { p["StandardInPath"] = (spec.stdinPath as NSString).expandingTildeInPath }
            if let o = output.stdout { p["StandardOutPath"] = o }
            if let e = output.stderr { p["StandardErrorPath"] = e }
            if k.processType != .unset { p["ProcessType"] = k.processType.rawValue }
            if let n = k.nice { p["Nice"] = n }
            if k.lowPriorityIO { p["LowPriorityIO"] = true }
            if k.lowPriorityBackgroundIO { p["LowPriorityBackgroundIO"] = true }
            if let u = Int(k.umask, radix: 8) { p["Umask"] = u }
            var soft: [String: Int] = [:], hard: [String: Int] = [:]
            for (name, l) in k.limits {
                guard let key = LaunchdSettings.limitKeys[name] else { continue }
                if let v = Int(l.soft.trimmingCharacters(in: .whitespaces)) { soft[key] = v }
                if let v = Int(l.hard.trimmingCharacters(in: .whitespaces)) { hard[key] = v }
            }
            if !soft.isEmpty { p["SoftResourceLimits"] = soft }
            if !hard.isEmpty { p["HardResourceLimits"] = hard }
            if k.keepAlive { p["KeepAlive"] = true }
            if k.abandonProcessGroup { p["AbandonProcessGroup"] = true }
            if let t = k.exitTimeOut { p["ExitTimeOut"] = t }
            if let t = k.throttleInterval { p["ThrottleInterval"] = t }
            if stopped || k.waitForDebugger { p["WaitForDebugger"] = true }
            if k.enablePressuredExit { p["EnablePressuredExit"] = true }
            if k.enableTransactions { p["EnableTransactions"] = true }
            if k.legacyTimers { p["LegacyTimers"] = true }
            if k.materializeDatalessFiles { p["MaterializeDatalessFiles"] = true }
            if k.sessionCreate { p["SessionCreate"] = true }
            return p
        }

        /// Loads and starts the job; replies once launchd has a pid for it.
        static func start(_ spec: LaunchSpec, executable: String, name: String, output: OutputFiles, stopped: Bool) -> Result<(Launcher.Child, String), LaunchError> {
            let label = label(for: name)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("launchd")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("\(label).plist")
            let plist = plist(spec, executable: executable, label: label, output: output, stopped: stopped)
            guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
                  (try? data.write(to: file)) != nil else { return .failure(LaunchError(message: "Couldn't write the job's plist.")) }
            remove(label)
            let r = Shell.exec("/bin/launchctl", ["bootstrap", domain, file.path], timeout: 15)
            guard r.status == 0 else {
                return .failure(LaunchError(message: "launchctl bootstrap failed: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))"))
            }
            for _ in 0..<50 {
                let info = Shell.exec("/bin/launchctl", ["print", "\(domain)/\(label)"], timeout: 5).output
                if let pid = field(info, "pid").flatMap({ Int32($0) }), let start = Native.process(pid)?.start {
                    return .success((Launcher.Child(pid: pid, start: start, name: name, executable: executable), label))
                }
                if let reason = field(info, "last exit reason") ?? field(info, "last exit code"), field(info, "state") == "not running",
                   reason != "(never exited)" {
                    return .failure(LaunchError(message: "launchd started it but it exited at once: \(reason)"))
                }
                usleep(100_000)
            }
            return .failure(LaunchError(message: "launchd loaded the job but didn't start it (launchctl print \(domain)/\(label))."))
        }

        /// Unloads the job (killing it if it runs).
        static func remove(_ label: String) {
            _ = Shell.exec("/bin/launchctl", ["bootout", "\(domain)/\(label)"], timeout: 15)
        }

        /// "\tkey = value" in `launchctl print`'s top level.
        static func field(_ text: String, _ key: String) -> String? {
            for line in text.split(separator: "\n") where line.hasPrefix("\t") && !line.hasPrefix("\t\t") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix(key + " = ") { return String(t.dropFirst(key.count + 3)) }
            }
            return nil
        }
    }

    // MARK: Launch Services

    static func documentURLs(_ lines: String) -> [URL] {
        lines.split(whereSeparator: \.isNewline).compactMap { raw in
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return nil }
            if t.contains("://"), let u = URL(string: t) { return u }
            return URL(fileURLWithPath: (t as NSString).expandingTildeInPath)
        }
    }

    /// NSWorkspace.openApplication (or open(_:withApplicationAt:) with documents). `existing`: Launch Services
    /// handed over an app that was already running instead of starting one.
    @MainActor
    static func launchServices(_ spec: LaunchSpec, app: URL, name: String) async -> Result<(Launcher.Child, existing: Bool), LaunchError> {
        let k = spec.launchServices
        let c = NSWorkspace.OpenConfiguration()
        c.activates = k.activates
        c.hides = k.hides
        c.hidesOthers = k.hidesOthers
        c.createsNewApplicationInstance = k.createsNewInstance
        c.allowsRunningApplicationSubstitution = k.allowsSubstitution
        c.addsToRecentItems = k.addsToRecentItems
        c.promptsUserIfNeeded = k.promptsUserIfNeeded
        c.isForPrinting = k.forPrinting
        c.arguments = spec.argumentList
        c.environment = spec.addedEnvironment
        switch k.architecture {
        case .any: break
        case .arm64, .arm64e: c.architecture = CPU_TYPE_ARM64
        case .x86_64: c.architecture = CPU_TYPE_X86_64
        }
        let before = Date()
        do {
            let docs = documentURLs(k.documents)
            let app = docs.isEmpty ? try await NSWorkspace.shared.openApplication(at: app, configuration: c)
                                   : try await NSWorkspace.shared.open(docs, withApplicationAt: app, configuration: c)
            let pid = app.processIdentifier
            guard pid > 0, let start = Native.process(pid)?.start else {
                return .failure(LaunchError(message: "Launch Services opened \(name) but gave no process for it."))
            }
            let exe = app.executableURL?.path ?? Native.path(pid) ?? ""
            return .success((Launcher.Child(pid: pid, start: start, name: name, executable: exe), start < before.addingTimeInterval(-1)))
        } catch {
            return .failure(LaunchError(message: "Launch Services couldn't open \(name): \(error.localizedDescription)"))
        }
    }

    // MARK: open

    /// /usr/bin/open's arguments for this launch.
    static func openArguments(_ spec: LaunchSpec, app: String, output: OutputFiles) -> [String] {
        let k = spec.open
        var a: [String] = []
        if k.newInstance { a.append("-n") }
        if k.background { a.append("-g") }
        if k.hidden { a.append("-j") }
        if k.fresh { a.append("-F") }
        if k.wait { a.append("-W") }
        switch k.architecture {
        case .any: break
        case .arm64, .arm64e: a += ["--arch", "arm64"]
        case .x86_64: a += ["--arch", "x86_64"]
        }
        for (key, v) in spec.addedEnvironment.sorted(by: { $0.key < $1.key }) { a += ["--env", "\(key)=\(v)"] }
        if spec.stdin == .file, !spec.stdinPath.isEmpty { a += ["--stdin", (spec.stdinPath as NSString).expandingTildeInPath] }
        if let o = output.stdout { a += ["--stdout", o] }
        if let e = output.stderr { a += ["--stderr", e] }
        a += ["-a", app]
        a += documentURLs(k.documents).map { $0.isFileURL ? $0.path : $0.absoluteString }
        let args = spec.argumentList
        if !args.isEmpty { a += ["--args"] + args }
        return a
    }

    /// The process running `executable` that started last, at or after `since`: what open started (it doesn't
    /// say). Nil when there's none yet.
    static func newest(running executable: String, since: Date) -> Launcher.Child? {
        let name = String((executable as NSString).lastPathComponent.prefix(16))
        let candidates = Native.allProcesses().filter { $0.comm == name && $0.start >= since.addingTimeInterval(-0.5) }
        guard let p = candidates.filter({ Native.path($0.pid) == executable }).max(by: { $0.start < $1.start }) else { return nil }
        return Launcher.Child(pid: p.pid, start: p.start, name: (executable as NSString).lastPathComponent, executable: executable)
    }

    /// Any process running `executable` (an app already running, which open only brought forward).
    static func running(_ executable: String) -> Launcher.Child? { newest(running: executable, since: .distantPast) }
}
