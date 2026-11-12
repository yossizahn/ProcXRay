import Foundation

/// launchd pid domains: every process owns one, holding the services it asked launchd to start. An extension
/// host's domain lists its running extensions (`chronod` its widgets, `linkd` App Intents extensions), and an
/// app's lists its own XPC services. Reading a process's domain therefore names the processes it hosts; the
/// inverse gives each process its host (`ProcInfo.domainOwner`).
///
/// `launchctl print pid/<n>` takes ~5 ms. Another user's or root's domain is "Operation not permitted"
/// without the helper.
enum PidDomain {
    /// Pids of the running services listed in `launchctl print pid/<n>` output; nil when the domain couldn't
    /// be printed. Service lines read "<pid> <last exit> <label>", pid 0 for one not running.
    static func children(_ text: String) -> [pid_t]? {
        guard text.hasPrefix("pid/") else { return nil }
        guard let open = text.range(of: "\n\tservices = {\n") else { return [] }
        let rest = text[open.upperBound...]
        let block = rest[..<(rest.range(of: "\n\t}")?.lowerBound ?? rest.endIndex)]
        var out: [pid_t] = []
        for line in block.split(separator: "\n") {
            // Indented with tabs, then the pid right-aligned with spaces.
            guard let first = line.split(whereSeparator: \.isWhitespace).first,
                  let pid = pid_t(first), pid > 0 else { continue }
            out.append(pid)
        }
        return out
    }

    /// Reads one domain: as the user for the user's own processes, through the helper for the rest.
    static func read(_ pid: pid_t, ownedByUser: Bool, viaHelper: Bool) -> [pid_t]? {
        if ownedByUser, let (path, args) = HelperTool.pidDomain.argv(pid: pid),
           let c = children(Shell.run(path, args, mergeStderr: true, timeout: HelperTool.pidDomain.timeout)) {
            return c
        }
        guard viaHelper, let out = HelperClient.shared.run(.pidDomain, pid: pid) else { return nil }
        return children(out)
    }
}
