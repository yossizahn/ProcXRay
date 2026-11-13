import Foundation

// MARK: - LaunchServices (lsappinfo)

struct LSApp: Identifiable, Hashable, Sendable {
    var id: String { asn }
    var index: Int
    var name: String
    var asn: String
    var bundleID: String?
    var bundlePath: String?
    var executablePath: String?
    var pid: pid_t?
    var type: String?
    var version: String?
    var arch: String?
    var coalition: UInt64?            // jetsam coalition id
    var coalitionPIDs: [pid_t] = []   // `{ … }` after the coalition id
    var relatedCoalitionIDs: [UInt64] = []
    var relatedCoalitionPIDs: [pid_t] = []   // e.g. helpers left over from a previous instance
    var parentASN: String?
    var stateTags: [String] = []      // e.g. "exited-with-subordinates", "!signalled"
    var raw: String

    var exited: Bool { stateTags.contains { $0.hasPrefix("exited") } }
}

enum LSAppInfo {
    static func list() -> [LSApp] {
        parse(Shell.run("/usr/bin/lsappinfo", ["list"], timeout: 10))
    }

    static func parse(_ text: String) -> [LSApp] {
        // `  6) "Google Chrome" ASN:0x0-0x10010: (in front)`: the frontmost app's header carries a trailing tag.
        let header = try! NSRegularExpression(pattern: #"^\s*(\d+)\) "(.*)" (ASN:\S+?):?(?:\s+\(([^)]*)\))?\s*$"#)
        var apps: [LSApp] = []
        var cur: LSApp?
        func flush() { if let c = cur { apps.append(c) }; cur = nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let ns = line as NSString
            if let m = header.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                flush()
                cur = LSApp(index: Int(ns.substring(with: m.range(at: 1))) ?? 0,
                            name: ns.substring(with: m.range(at: 2)),
                            asn: ns.substring(with: m.range(at: 3)), raw: line)
                if m.range(at: 4).location != NSNotFound { cur?.stateTags.append(ns.substring(with: m.range(at: 4))) }
                continue
            }
            guard var c = cur else { continue }
            c.raw += "\n" + line
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("bundleID=") { c.bundleID = quoted(t, "bundleID=") }
            else if t.hasPrefix("bundle path=") { c.bundlePath = quoted(t, "bundle path=") }
            else if t.hasPrefix("executable path=") { c.executablePath = quoted(t, "executable path=") }
            else if t.hasPrefix("coalition:") {
                // coalition: 108929  { 15173 15177 }    relatedCoalitionIDs: ( 108927)  relatedCoalitionPIDs: ( 15166)
                let rest = t.dropFirst("coalition:".count).trimmingCharacters(in: .whitespaces)
                c.coalition = rest.split(separator: " ").first.flatMap { UInt64($0) }
                c.coalitionPIDs = numbers(in: rest, between: "{", and: "}")
                c.relatedCoalitionIDs = numbers(in: rest, after: "relatedCoalitionIDs:")
                c.relatedCoalitionPIDs = numbers(in: rest, after: "relatedCoalitionPIDs:")
            }
            else if t.hasPrefix("parentASN=") { c.parentASN = quoted(t, "parentASN=") }
            else if t.hasPrefix("pid = ") {
                let parts = t.split(separator: " ")
                if parts.count > 2 { c.pid = pid_t(parts[2]) }
                c.type = field(t, "type")
                c.version = field(t, "Version")
                if let r = t.range(of: "Arch=") {
                    let rest = t[r.upperBound...]
                    c.arch = rest.split(separator: " ").first.map(String.init)
                }
                for tok in t.split(separator: " ") where tok.hasPrefix("!") { c.stateTags.append(String(tok)) }
                if let o = t.lastIndex(of: "("), let cl = t.lastIndex(of: ")"), o < cl {
                    c.stateTags.append(String(t[t.index(after: o)..<cl]))
                }
            }
            cur = c
        }
        flush()
        return apps
    }

    private static func numbers<T: FixedWidthInteger>(in s: String, between open: Character, and close: Character) -> [T] {
        guard let o = s.firstIndex(of: open), let c = s[o...].firstIndex(of: close) else { return [] }
        return s[s.index(after: o)..<c].split(separator: " ").compactMap { T($0) }
    }

    private static func numbers<T: FixedWidthInteger>(in s: String, after key: String) -> [T] {
        guard let r = s.range(of: key) else { return [] }
        return numbers(in: String(s[r.upperBound...]), between: "(", and: ")")
    }

    private static func quoted(_ s: String, _ prefix: String) -> String? {
        let v = s.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("[ NULL ]") { return nil }
        if v.hasPrefix("\""), let end = v.dropFirst().firstIndex(of: "\"") { return String(v[v.index(after: v.startIndex)..<end]) }
        return v
    }

    private static func field(_ s: String, _ key: String) -> String? {
        guard let r = s.range(of: " \(key)=") else { return nil }
        let rest = s[r.upperBound...]
        if rest.hasPrefix("\"") {
            let body = rest.dropFirst()
            return body.firstIndex(of: "\"").map { String(body[..<$0]) }
        }
        return rest.split(separator: " ").first.map(String.init)
    }
}

// MARK: - Background Task Management (sfltool dumpbtm)

struct BTMItem: Identifiable, Hashable, Sendable {
    var id: String { uid + ":" + (fields["UUID"] ?? "\(index)") }
    var uid: String
    var index: Int
    var fields: [String: String]
    var embedded: [String] = []

    var name: String { fields["Name"] ?? "?" }
    var type: String { fields["Type"] ?? "" }
    var disposition: String { fields["Disposition"] ?? "" }
    var identifier: String { fields["Identifier"] ?? "" }
    var developer: String { fields["Developer Name"] ?? "" }
    var teamID: String { fields["Team Identifier"] ?? "" }
    var url: String { fields["URL"] ?? "" }
    var executable: String { fields["Executable Path"] ?? "" }
    var bundleID: String { fields["Bundle Identifier"] ?? "" }
    var parent: String { fields["Parent Identifier"] ?? "" }
    var lastUse: String { fields["Last Use"] ?? "" }
    var enabled: Bool { disposition.contains("[enabled") }
    var allowed: Bool { disposition.contains(" allowed") || disposition.contains("[allowed") }
    /// "AlDente" from "Parent Identifier: 2.com.foo.app" is not a bundle id; "2.com.foo.app" is the app record's
    /// identifier (type number, then the bundle id).
    var parentBundleID: String? {
        guard let dot = parent.firstIndex(of: "."), parent[..<dot].allSatisfy(\.isNumber), !parent[..<dot].isEmpty
        else { return nil }
        return String(parent[parent.index(after: dot)...])
    }
    /// `AssociatedBundleIdentifiers` from the job's plist: "[ com.a com.b ]".
    var assocBundleIDs: [String] {
        (fields["Assoc. Bundle IDs"] ?? "").split(whereSeparator: { $0 == " " || $0 == "[" || $0 == "]" }).map(String.init)
    }
}

enum BTM {
    /// NOTE: sfltool requests `system.privilege.admin` (password prompt) on every run.
    /// Never call this automatically — only from an explicit user action.
    // Long limit: sfltool waits for the user to type an admin password.
    static func dump() -> [BTMItem] { parse(Shell.run("/usr/bin/sfltool", ["dumpbtm"], timeout: 300)) }

    /// The records, or why there are none: a cancelled password prompt, a failed tool and a helper that
    /// didn't answer must not look like a successful load of zero records.
    static func load(viaHelper: Bool) -> ([BTMItem], String?) {
        let text: String
        if viaHelper {
            guard let t = HelperClient.shared.run(.btmDump) else { return ([], "The helper did not answer.") }
            text = t
        } else {
            let r = Shell.exec("/usr/bin/sfltool", ["dumpbtm"], timeout: 300)
            guard r.ok else {
                let out = r.annotated.trimmingCharacters(in: .whitespacesAndNewlines)
                return ([], "sfltool dumpbtm failed (exit \(r.status))" + (out.isEmpty ? "." : ":\n\(out)"))
            }
            text = r.output
        }
        let items = parse(text)
        // A dump always has a "Records for UID" section; anything else is an error message.
        if items.isEmpty && !text.contains("Records for UID") {
            let out = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return ([], out.isEmpty ? "sfltool dumpbtm returned no output." : out)
        }
        return (items, nil)
    }

    /// The apps each launchd item belongs to, by "path:<executable>" and "label:<job label>": the item's parent
    /// app record, then the bundle ids its plist associates. Only daemons, agents and login items with an
    /// absolute executable path or a label (SMAppService items have relative paths; launchd records those).
    static func ownerIndex(_ items: [BTMItem]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for i in items {
            let t = i.type
            guard t.hasPrefix("daemon") || t.hasPrefix("agent") || t.hasPrefix("legacy daemon")
                    || t.hasPrefix("legacy agent") || t.hasPrefix("login item") else { continue }
            var ids: [String] = []
            for id in [i.parentBundleID].compactMap({ $0 }) + i.assocBundleIDs where !ids.contains(id) { ids.append(id) }
            guard !ids.isEmpty else { continue }
            if i.executable.hasPrefix("/") { out["path:" + i.executable, default: []] += ids }
            // "16.com.foo.helper": type number, then the label.
            if let dot = i.identifier.firstIndex(of: "."), i.identifier[..<dot].allSatisfy(\.isNumber) {
                out["label:" + i.identifier[i.identifier.index(after: dot)...], default: []] += ids
            }
        }
        return out
    }

    static func parse(_ text: String) -> [BTMItem] {
        var items: [BTMItem] = []
        var uid = "?"
        var cur: BTMItem?
        var inEmbedded = false
        func flush() { if let c = cur { items.append(c) }; cur = nil }
        for raw in text.split(separator: "\n").map(String.init) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Records for UID") {
                flush()
                uid = t.replacingOccurrences(of: "Records for UID ", with: "").components(separatedBy: " :").first ?? "?"
                continue
            }
            // Item headers have 1 leading space ("  #1:"), embedded entries are deeper.
            let lead = raw.prefix { $0 == " " }.count
            if t.hasPrefix("#"), t.hasSuffix(":"), lead <= 2 {
                flush()
                inEmbedded = false
                cur = BTMItem(uid: uid, index: Int(t.dropFirst().dropLast()) ?? 0, fields: [:])
                continue
            }
            guard var c = cur else { continue }
            if t == "Embedded Item Identifiers:" { inEmbedded = true; cur = c; continue }
            if inEmbedded, t.hasPrefix("#"), let r = t.range(of: ": ") {
                c.embedded.append(String(t[r.upperBound...])); cur = c; continue
            }
            if let r = t.range(of: ": ") {
                inEmbedded = false
                c.fields[String(t[..<r.lowerBound])] = String(t[r.upperBound...])
            }
            cur = c
        }
        flush()
        return items
    }
}

// MARK: - launchd

struct LaunchdJob: Identifiable, Hashable, Sendable {
    var id: String { label }
    var label: String
    var pid: pid_t?
    var lastExit: String
    /// launchd domain the job lives in: "gui", "system" or "user".
    var domain = "gui"
}

enum Launchd {
    /// Running jobs of the system and user domains, which `launchctl list` (gui domain only) leaves out.
    /// Both are readable without root; together the three calls take ~25 ms.
    static func otherDomains() -> [LaunchdJob] {
        services("system", domain: "system") + services("user/\(getuid())", domain: "user")
    }

    /// The `services = { … }` block of `launchctl print <target>`: `<pid> <last exit> <label>` per line,
    /// pid 0 when not running. Only running jobs are returned: the result labels processes.
    static func services(_ target: String, domain: String) -> [LaunchdJob] {
        parseServices(Shell.run("/bin/launchctl", ["print", target], mergeStderr: false, timeout: 10), domain: domain)
    }

    static func parseServices(_ text: String, domain: String) -> [LaunchdJob] {
        var out: [LaunchdJob] = []
        var inside = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if !inside { inside = line == "\tservices = {"; continue }
            if line.hasPrefix("\t}") { break }
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard f.count >= 3, let pid = pid_t(f[0]), pid > 0 else { continue }
            out.append(LaunchdJob(label: f[2...].joined(separator: " "), pid: pid, lastExit: String(f[1]), domain: domain))
        }
        return out
    }

    static func list() -> [LaunchdJob] {
        Shell.run("/bin/launchctl", ["list"], mergeStderr: false, timeout: 10)
            .split(separator: "\n").dropFirst().compactMap { line in
                let p = line.split(separator: "\t", maxSplits: 2).map(String.init)
                guard p.count == 3 else { return nil }
                return LaunchdJob(label: p[2], pid: pid_t(p[0]), lastExit: p[1])
            }
    }

    /// launchd's `parent bundle identifier` for a job: set only for jobs an app registered through
    /// SMAppService. `domain` is LaunchdJob.domain ("gui", "system" or "user").
    static func parentBundle(_ label: String, domain: String) -> String? {
        let target = domain == "system" ? "system/\(label)" : "\(domain)/\(getuid())/\(label)"
        let out = Shell.run("/bin/launchctl", ["print", target], mergeStderr: false, timeout: 10)
        for line in out.split(separator: "\n") where line.hasPrefix("\tparent bundle identifier = ") {
            let v = line.dropFirst("\tparent bundle identifier = ".count).trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? nil : v
        }
        return nil
    }

    static func printJob(_ label: String) -> String {
        let domain = "gui/\(getuid())/\(label)"
        let out = Shell.run("/bin/launchctl", ["print", domain], timeout: 10)
        if out.contains("Could not find service") {
            return Shell.run("/bin/launchctl", ["print", "system/\(label)"], timeout: 10)
        }
        return out
    }
}
