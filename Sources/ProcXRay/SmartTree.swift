import Foundation

/// Top-level groups of the Smart tree, in display order. See docs/tree-and-inspector-proposal.md.
enum ProcCategory: Int, CaseIterable, Sendable {
    case apps, backgroundApps, extensions, thirdPartyServices, systemInterface, systemServices, other, leftBehind

    var title: String {
        switch self {
        case .apps: "Apps"
        case .backgroundApps: "Background apps"
        case .extensions: "Extensions"
        case .thirdPartyServices: "Third-party services"
        case .systemInterface: "System interface"
        case .systemServices: "System services"
        case .other: "Other"
        case .leftBehind: "Left behind"
        }
    }

    var symbol: String {
        switch self {
        case .apps: "square.grid.2x2"
        case .backgroundApps: "menubar.rectangle"
        case .extensions: "puzzlepiece.extension"
        case .thirdPartyServices: "shippingbox"
        case .systemInterface: "menubar.dock.rectangle"
        case .systemServices: "gearshape.2"
        case .other: "questionmark.square.dashed"
        case .leftBehind: "exclamationmark.triangle.fill"
        }
    }

    /// One member of the category, for the Kind column.
    var singular: String {
        switch self {
        case .apps: "App"
        case .backgroundApps: "Background app"
        case .extensions: "Extension"
        case .thirdPartyServices: "Third-party service"
        case .systemInterface: "System interface"
        case .systemServices: "System service"
        case .other: "Other"
        case .leftBehind: "Left behind"
        }
    }

    /// What one top-level row of the category is called in its summary ("12 apps · 151 processes").
    var unitNoun: String {
        switch self {
        case .apps, .backgroundApps: "apps"
        case .leftBehind: "groups"
        default: "items"
        }
    }

    /// The categories holding what the user started (and the Left Behind warning) start open.
    var startsExpanded: Bool { self == .apps || self == .backgroundApps || self == .leftBehind }
}

/// Builds the Smart tree in two passes: attach each process to at most one owner (the roots are
/// *units*), then place each unit root in a category. Descendants follow their root.
enum SmartTree {
    // Row ids. Process rows use their pid (>= 0); the existing synthetic rows use -pid - 1 (dead
    // responsible), -1,000,000 - coalition (previous instance) and -10,000,000 - 2 * coalition. These
    // ranges sit far below all of them and are stable across refreshes, so the outline sees no moves.
    private static let unitBase = -(1 << 40)
    private static let categoryBase = -(1 << 41)
    private static let groupBase = -(1 << 42)
    /// Rows inside a unit (role groups, terminals, jobs): the unit's root pid times 2^24 plus a hash.
    private static let roleBase = -(1 << 43)

    static func unitID(_ pid: pid_t) -> Int { unitBase - Int(pid) }
    static func categoryID(_ c: ProcCategory) -> Int { categoryBase - c.rawValue }
    static func groupID(_ c: ProcCategory, _ key: String) -> Int {
        groupBase - (c.rawValue << 32) - Int(fnv(key))
    }
    static func roleID(_ root: pid_t, _ key: String) -> Int {
        roleBase - (Int(root) << 24) - Int(fnv(key) & 0xFF_FFFF)
    }
    static func fnv(_ key: String) -> UInt32 {
        var h: UInt32 = 2_166_136_261   // FNV-1a: deterministic, unlike hashValue
        for b in key.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return h
    }

    /// The process a row stands for: its own pid, or the root of a unit row. nil for other group rows.
    static func pid(forRow id: Int) -> pid_t? {
        if id >= 0 { return pid_t(clamping: id) }
        let p = unitBase - id
        return p >= 0 && p <= Int(Int32.max) ? pid_t(p) : nil
    }

    // MARK: Classification

    /// Apple code: the signer once signing info has loaded, a path rule until then (so most rows don't
    /// change category a second after launch).
    static func isApple(_ p: ProcInfo) -> Bool {
        if p.pid == 0 { return true }   // kernel_task
        if let s = p.signer { return s.hasPrefix("Apple") }
        guard let path = p.path else { return false }
        if path.hasPrefix("/usr/local/") { return false }
        return ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/", "/Library/Developer/PrivateFrameworks/"].contains { path.hasPrefix($0) }
    }

    static func isExtension(_ p: ProcInfo) -> Bool { p.path?.contains(".appex/") == true }

    /// The .app bundles a path lies inside, innermost first.
    static func enclosingApps(_ path: String) -> [String] {
        var out: [String] = []
        var rest = path[...]
        while let r = rest.range(of: ".app/", options: .backwards) {
            out.append(String(path[..<r.lowerBound]) + ".app")
            rest = path[..<r.lowerBound]
        }
        return out
    }

    static func category(ofRoot p: ProcInfo) -> ProcCategory {
        if p.leftBehindGroup != nil { return .leftBehind }
        if p.lsType == "Foreground" { return .apps }
        // Before the LaunchServices background types: Finder Sync and Quick Look extensions register as
        // BackgroundOnly, and would otherwise fill "Background apps" with things that aren't apps.
        if isExtension(p) { return .extensions }
        // A job in launchd's system domain runs outside every login session, so it can't show any UI,
        // whatever LaunchServices type its bundle registered as (Foxit's update service registers as UIElement).
        if p.launchdDomain == "system", let l = p.launchdLabel, !l.hasPrefix("application.") {
            return isApple(p) ? .systemServices : .thirdPartyServices
        }
        if p.lsType == "UIElement" || p.lsType == "BackgroundOnly" { return isApple(p) ? .systemInterface : .backgroundApps }
        let apple = isApple(p)
        if let l = p.launchdLabel, !apple, !l.hasPrefix("application.") { return .thirdPartyServices }
        return apple ? .systemServices : .other
    }

    /// Sub-group of a unit inside its category, or nil for none.
    static func subgroup(ofRoot p: ProcInfo, in c: ProcCategory) -> String? {
        switch c {
        case .backgroundApps: return p.lsType == "UIElement" ? "No Dock icon" : "Background only"
        case .extensions: return p.extensionPoint.map(ExtensionInfo.title) ?? "Unknown extension point"
        case .thirdPartyServices: return p.launchdDomain == "system" || p.uid == 0 ? "Daemons" : "Agents"
        default: return nil
        }
    }

    // MARK: Roles inside a unit

    /// A helper's role, only where the bundle layout says it exactly: an app extension runs from an
    /// `.appex` bundle, an XPC service from an `.xpc` bundle in an `XPCServices` folder. Everything else
    /// is a plain helper. (Guessing renderers or GPU processes from names was dropped as unreliable.)
    static func role(of p: ProcInfo) -> ProcRole {
        if isExtension(p) { return .extensions }
        if isXPCService(p) { return .xpcServices }
        return .helpers
    }

    static func isXPCService(_ p: ProcInfo) -> Bool {
        guard let path = p.path, let r = path.range(of: "/XPCServices/") else { return false }
        return path[r.upperBound...].contains(".xpc/Contents/MacOS/")
    }

    /// The members directly under a unit's root: extensions and XPC services grouped when there are two
    /// or more, and not when every member would land in the same group (it would only add a level). Other
    /// helpers stay plain rows. Terminal sessions (`sessionRoots`, from anywhere in the unit) are grouped by tty, then
    /// by process group, so a pipeline is one row.
    static func roleGroups(_ root: pid_t, direct: [ProcInfo], sessionRoots: [ProcInfo], kids: [pid_t: [ProcInfo]],
                           node: (ProcInfo) -> ProcNode) -> [ProcNode] {
        var byRole: [ProcRole: [ProcInfo]] = [:]
        for d in direct { byRole[role(of: d), default: []].append(d) }
        var out: [ProcNode] = []

        // A session holds the terminal's process and everything under it, tty or not (a job that
        // detached from the terminal still belongs to the session that started it).
        func subtree(_ p: ProcInfo, _ depth: Int) -> [ProcInfo] {
            [p] + (depth < 64 ? (kids[p.pid] ?? []).flatMap { subtree($0, depth + 1) } : [])
        }
        let sessions = Dictionary(grouping: sessionRoots) { $0.tty! }.mapValues { $0.flatMap { subtree($0, 0) } }
        let sessionCount = sessions.values.reduce(0) { $0 + $1.count }
        if sessionCount >= 2 {
            var ttys: [ProcNode] = []
            for (tty, ps) in sessions {
                var rows: [ProcNode] = []
                for (pgid, members) in Dictionary(grouping: ps, by: \.pgid) {
                    let ordered = members.sorted { $0.pid < $1.pid }
                    var row: ProcNode
                    if ordered.count == 1 {
                        row = ProcNode(id: Int(ordered[0].pid), proc: ordered[0], title: ordered[0].name)
                    } else {
                        row = ProcNode(id: roleID(root, "job\(tty):\(pgid)"), proc: nil, title: "job \(pgid)",
                                       subtitle: ordered.map(\.name).joined(separator: " | "),
                                       children: ordered.map { ProcNode(id: Int($0.pid), proc: $0, title: $0.name) })
                        row.kind = .group
                    }
                    row.fixedOrder = Int(pgid)   // the shell first, then its jobs in the order they started
                    rows.append(row)
                }
                // A terminal running just its shell needs no row of its own; the Context column names the tty.
                if rows.count == 1, var only = rows.first, only.proc != nil {
                    only.fixedOrder = Int(tty)   // in tty order with the terminals that have rows
                    ttys.append(only)
                    continue
                }
                var t = ProcNode(id: roleID(root, "tty\(tty)"), proc: nil, title: ttyName(tty), children: rows)
                t.kind = .group
                t.fixedOrder = Int(tty)
                ttys.append(t)
            }
            var g = ProcNode(id: roleID(root, "role\(ProcRole.terminalSessions.rawValue)"), proc: nil,
                             title: ProcRole.terminalSessions.title, children: ttys)
            g.kind = .group
            g.fixedOrder = 1 + ProcRole.terminalSessions.rawValue
            out.append(g)
        } else {
            out += sessionRoots.map(node)
        }

        let onlyOneRole = byRole.count == 1 && sessionCount < 2
        for (r, ps) in byRole {
            guard r != .helpers, ps.count >= 2, !onlyOneRole else { out += ps.map(node); continue }
            var g = ProcNode(id: roleID(root, "role\(r.rawValue)"), proc: nil, title: r.title, children: ps.map(node))
            g.kind = .group
            g.fixedOrder = 1 + r.rawValue
            g.startsCollapsed = true
            out.append(g)
        }
        return out
    }

    /// devname() searches /dev, so each device is looked up once (the TTY column asks per process per refresh).
    static func ttyName(_ tty: Int32) -> String {
        ttyLock.lock(); defer { ttyLock.unlock() }
        if let n = ttyNames[tty] { return n }
        let n = devname(dev_t(tty), mode_t(S_IFCHR)).map { String(cString: $0) } ?? "tty \(tty)"
        ttyNames[tty] = n
        return n
    }
    nonisolated(unsafe) private static var ttyNames: [Int32: String] = [:]
    private static let ttyLock = NSLock()

    // MARK: Build

    struct Input {
        var procs: [pid_t: ProcInfo]
        var lsApps: [LSApp]
        /// BTM.ownerIndex of the Background Items records; empty until they're loaded.
        var btmOwners: [String: [String]] = [:]
    }

    /// Pass 1: the unit root of every process.
    static func unitRoots(_ input: Input) -> [pid_t: pid_t] {
        let procs = input.procs
        // Owners, by the proposal's rules in order.
        var appByBundle: [String: pid_t] = [:], appByID: [String: pid_t] = [:]
        for a in input.lsApps where !a.exited {
            guard let pid = a.pid, procs[pid] != nil else { continue }
            if let b = a.bundlePath { appByBundle[b] = pid }
            // The main app wins over a helper app sharing its bundle id (none should, but don't nest by chance).
            if let id = a.bundleID, appByID[id] == nil || a.type == "Foreground" { appByID[id] = pid }
        }
        var owner: [pid_t: pid_t] = [:]
        for p in procs.values {
            if p.leftBehindGroup != nil { continue }                                  // 1: Left Behind group
            if let r = p.responsible, r != p.pid, procs[r] != nil { owner[p.pid] = r; continue }  // 2
            if isExtension(p), let b = p.bundlePath, let app = appByBundle[b], app != p.pid {     // 3
                owner[p.pid] = app; continue
            }
            // 3b: the app that registered its launchd job through SMAppService, as launchd records it
            // (`parent bundle identifier`). This says whose job it is, not who made launchd start it: an
            // on-demand job starts on any client's message, and launchd doesn't record the sender.
            if let id = p.launchdParentBundle, let app = appByID[id], app != p.pid {
                owner[p.pid] = app; continue
            }
            // 3c: the app that installed it, as Background Items records it, for launchd items installed the old
            // way (a plist in /Library/LaunchDaemons, a tool in /Library/PrivilegedHelperTools), which launchd
            // links to no app: AlDente's helper. Matched on executable path, else job label. Children of
            // launchd only, like 3d: the record says what launchd runs, not what other processes spawn.
            if p.ppid == 1,
               let ids = p.path.flatMap({ input.btmOwners["path:" + $0] }) ?? p.launchdLabel.flatMap({ input.btmOwners["label:" + $0] }),
               let app = ids.lazy.compactMap({ appByID[$0] }).first, app != p.pid {
                owner[p.pid] = app; continue
            }
            // 3d: failing that, a child of launchd that isn't a LaunchServices app of its own, run from inside
            // a running app's bundle (helpers and updaters launchd starts for an app that registered no job
            // with SMAppService). Only children of launchd: a process another one spawned directly follows its
            // parent (rule 5), e.g. 1Password's native-messaging host under the browser that started it.
            // Innermost bundle first, so a helper app's daemon goes to the helper app when that's running.
            if p.ppid == 1, p.lsType == nil, !isExtension(p), let path = p.path,
               let app = enclosingApps(path).lazy.compactMap({ appByBundle[$0] }).first, app != p.pid {
                owner[p.pid] = app; continue
            }
            // 4: the host whose launchd pid domain it runs in, except for an extension: its host is a system
            // daemon (chronod hosts every widget), shown in Context and Origin instead of nesting under it.
            if !isExtension(p), let o = p.domainOwner, o != p.pid, procs[o] != nil { owner[p.pid] = o; continue }
            if p.ppid > 1, p.ppid != p.pid, procs[p.ppid] != nil { owner[p.pid] = p.ppid }        // 5
        }
        // Unit root of every process. A cycle (A owned by B, B by A) is broken at its lowest pid.
        var rootOf: [pid_t: pid_t] = [:]
        func root(_ start: pid_t) -> pid_t {
            var path: [pid_t] = []
            var at: [pid_t: Int] = [:]
            var cur = start
            var r: pid_t
            while true {
                if let known = rootOf[cur] { r = known; break }
                if let i = at[cur] {
                    r = path[i...].min()!
                    owner[r] = nil
                    break
                }
                at[cur] = path.count
                path.append(cur)
                guard let o = owner[cur] else { r = cur; break }
                cur = o
            }
            for q in path { rootOf[q] = r }
            return r
        }
        for p in procs.values { _ = root(p.pid) }
        return rootOf
    }

    /// "App · XPC service", "Extension · Widgets", "System service": the Kind column, per pid; and each
    /// pid's unit root.
    static func kinds(_ input: Input) -> (kinds: [pid_t: String], roots: [pid_t: pid_t]) {
        let rootOf = unitRoots(input)
        var out: [pid_t: String] = [:]
        for p in input.procs.values {
            let r = rootOf[p.pid] ?? p.pid
            guard let rp = input.procs[r] else { continue }
            let c = category(ofRoot: rp)
            var s = c.singular
            if c == .extensions, let e = rp.extensionPoint { s += " · " + ExtensionInfo.title(e) }
            if p.pid != r {
                s += " · " + (p.tty != nil ? "Terminal" : role(of: p).singular)
                // An app's own extension: what kind, from its declared extension point.
                if isExtension(p), let e = p.extensionPoint { s += " · " + ExtensionInfo.title(e) }
            }
            out[p.pid] = s
        }
        return (out, rootOf)
    }

    private static func hidingExtensionPoint(_ n: ProcNode) -> ProcNode {
        var m = n
        m.extensionPointShownAbove = true
        m.children = n.children?.map(hidingExtensionPoint)
        return m
    }

    static func build(_ input: Input) -> [ProcNode] {
        let procs = input.procs
        let rootOf = unitRoots(input)
        var members: [pid_t: [ProcInfo]] = [:]
        for p in procs.values { members[rootOf[p.pid] ?? p.pid, default: []].append(p) }

        // Inside a unit the parent chain gives the structure (a shell under its terminal, a job under the
        // shell); a member whose parent is outside the unit hangs off the root.
        func unitNode(_ rootPid: pid_t, _ ms: [ProcInfo]) -> ProcNode {
            let rootProc = procs[rootPid]!
            var kids: [pid_t: [ProcInfo]] = [:]
            // Where a terminal session starts: a member on a tty whose parent isn't on that tty. Wherever it
            // sits in the unit (a shell under an Electron app's pty helper, say), it moves to Terminal sessions.
            var sessionRoots: [ProcInfo] = []
            for m in ms where m.pid != rootPid {
                let par = m.ppid != m.pid && rootOf[m.ppid] == rootPid && procs[m.ppid] != nil ? m.ppid : rootPid
                if let t = m.tty, procs[par]?.tty != t { sessionRoots.append(m); continue }
                kids[par, default: []].append(m)
            }
            func node(_ p: ProcInfo, depth: Int) -> ProcNode {
                let c = depth < 64 ? (kids[p.pid] ?? []).map { node($0, depth: depth + 1) } : []
                return ProcNode(id: Int(p.pid), proc: p, title: p.name, children: c.isEmpty ? nil : c)
            }
            guard ms.count > 1 else { return node(rootProc, depth: 0) }
            // Too few for a Terminal sessions group: back where they were.
            if sessionRoots.count == 1, (kids[sessionRoots[0].pid] ?? []).isEmpty {
                let m = sessionRoots.removeFirst()
                let par = m.ppid != m.pid && rootOf[m.ppid] == rootPid && procs[m.ppid] != nil ? m.ppid : rootPid
                kids[par, default: []].append(m)
            }
            var leaf = ProcNode(id: Int(rootPid), proc: rootProc, title: rootProc.name)
            leaf.fixedOrder = 0   // the app's own process stays at the top of its unit
            let rest = roleGroups(rootPid, direct: kids[rootPid] ?? [], sessionRoots: sessionRoots, kids: kids) { node($0, depth: 1) }
            var u = ProcNode(id: unitID(rootPid), proc: nil, title: rootProc.lsAppName ?? rootProc.name,
                             children: [leaf] + rest)
            u.kind = .unit
            u.rootPid = rootPid
            return u
        }

        // Pass 2: categories.
        var byCategory: [ProcCategory: [(sub: String?, node: ProcNode)]] = [:]
        var ghosts: [Int: (title: String, nodes: [ProcNode])] = [:]
        for (r, ms) in members {
            let rp = procs[r]!
            let n = unitNode(r, ms)
            if let g = rp.leftBehindGroup {
                ghosts[g, default: ("† \(rp.leftBehindText ?? "exited app") — exited", [])].nodes.append(n)
                continue
            }
            let c = category(ofRoot: rp)
            byCategory[c, default: []].append((subgroup(ofRoot: rp, in: c), n))
        }
        if !ghosts.isEmpty {
            byCategory[.leftBehind] = ghosts.map { gid, g in
                var n = ProcNode(id: gid, proc: nil, title: g.title, subtitle: "", isGhost: true, children: g.nodes)
                n.kind = .ghost
                return (nil, n)
            }
        }

        var out: [ProcNode] = []
        for c in ProcCategory.allCases {
            guard let entries = byCategory[c], !entries.isEmpty else { continue }
            // A sub-group is only made when it would hold two or more units; a lone unit sits directly
            // in the category, as does everything when the category has only one sub-group.
            let bySub = Dictionary(grouping: entries) { $0.sub ?? "" }
            var children: [ProcNode] = []
            for (sub, es) in bySub {
                if sub.isEmpty || es.count < 2 || bySub.count < 2 { children += es.map(\.node); continue }
                // Under a group named after the extension point, the rows needn't repeat it.
                let kids = c == .extensions ? es.map { Self.hidingExtensionPoint($0.node) } : es.map(\.node)
                var g = ProcNode(id: groupID(c, sub), proc: nil, title: sub, children: kids)
                g.kind = .group
                g.category = c
                children.append(g)
            }
            var n = ProcNode(id: categoryID(c), proc: nil, title: c.title, children: children)
            n.kind = .category
            n.category = c
            n.fixedOrder = c.rawValue
            n.startsCollapsed = !c.startsExpanded
            out.append(n)
        }
        return out
    }
}

/// Extension point of an app extension, read from its bundle's Info.plist once per bundle.
enum ExtensionInfo {
    nonisolated(unsafe) private static var cache: [String: String?] = [:]
    private static let lock = NSLock()

    static func bundle(ofExecutable path: String) -> String? {
        guard let r = path.range(of: ".appex/", options: .backwards) else { return nil }
        return String(path[..<r.lowerBound]) + ".appex"
    }

    static func point(forExecutable path: String) -> String? {
        guard let b = bundle(ofExecutable: path) else { return nil }
        lock.lock()
        if let hit = cache[b] { lock.unlock(); return hit }
        lock.unlock()
        // iOS-app wrappers keep Info.plist at the bundle root rather than under Contents/.
        let plist = NSDictionary(contentsOfFile: b + "/Contents/Info.plist") ?? NSDictionary(contentsOfFile: b + "/Info.plist")
        let ns = plist?["NSExtension"] as? [String: Any]
        let ex = plist?["EXAppExtensionAttributes"] as? [String: Any]
        let point = ns?["NSExtensionPointIdentifier"] as? String ?? ex?["EXExtensionPointIdentifier"] as? String
        lock.lock(); cache[b] = .some(point); lock.unlock()
        return point
    }

    private static let titles: [String: String] = [
        "com.apple.widgetkit-extension": "Widgets",
        "com.apple.appintents-extension": "App Intents",
        "com.apple.wallpaper": "Wallpaper",
        "com.apple.quicklook.thumbnail": "Quick Look thumbnails",
        "com.apple.quicklook.thumbnail.secure": "Quick Look thumbnails",
        "com.apple.quicklook.preview": "Quick Look previews",
        "com.apple.intents-service": "Siri intents",
        "com.apple.intents-ui-service": "Siri intents",
        "com.apple.FinderSync": "Finder Sync",
        "com.apple.modelmanager.inferenceprovider": "Model inference providers",
        "com.apple.share-services": "Share",
        "com.apple.services": "Services",
        "com.apple.fileprovider-nonui": "File providers",
        "com.apple.fileprovider-actionsui": "File providers",
        "com.apple.Safari.web-extension": "Safari extensions",
        "com.apple.Safari.content-blocker": "Safari extensions",
        "com.apple.Safari.extension": "Safari extensions",
        "com.apple.spotlight.import": "Spotlight importers",
        "com.apple.usernotifications.service": "Notification services",
        "com.apple.usernotifications.content-extension": "Notification services",
        "com.apple.photo-editing": "Photo editing",
        "com.apple.networkextension.packet-tunnel": "Network extensions",
        "com.apple.networkextension.app-proxy": "Network extensions",
        "com.apple.networkextension.filter-data": "Network extensions",
        "com.apple.screensaver": "Screen savers",
        "com.apple.textinputmethod": "Input methods",
        "com.apple.background-asset-downloader-extension": "Background asset downloaders",
        "com.apple.extensionkit.app-extension": "App extensions",
        "com.apple.fskit.fsmodule": "File system modules",
        "com.apple.spotlight.index": "Spotlight indexers",
        "com.apple.AudioUnit-Speech": "Speech voices",
    ]

    static func title(_ point: String) -> String { titles[point] ?? point }
}

/// Role of a helper inside its app's unit, in display order. Only the first three form groups.
enum ProcRole: Int, CaseIterable, Sendable {
    case extensions, xpcServices, terminalSessions, helpers

    var title: String {
        switch self {
        case .extensions: "Extensions"
        case .xpcServices: "XPC services"
        case .terminalSessions: "Terminal sessions"
        case .helpers: "Helpers"
        }
    }

    var singular: String {
        switch self {
        case .extensions: "Extension"
        case .xpcServices: "XPC service"
        case .terminalSessions: "Terminal"
        case .helpers: "Helper"
        }
    }
}
