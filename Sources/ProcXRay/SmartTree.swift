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

    static func unitID(_ pid: pid_t) -> Int { unitBase - Int(pid) }
    static func categoryID(_ c: ProcCategory) -> Int { categoryBase - c.rawValue }
    static func groupID(_ c: ProcCategory, _ key: String) -> Int {
        var h: UInt32 = 2_166_136_261   // FNV-1a: deterministic, unlike hashValue
        for b in key.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return groupBase - (c.rawValue << 32) - Int(h)
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

    static func category(ofRoot p: ProcInfo) -> ProcCategory {
        if p.leftBehindGroup != nil { return .leftBehind }
        if p.lsType == "Foreground" { return .apps }
        // Before the LaunchServices background types: Finder Sync and Quick Look extensions register as
        // BackgroundOnly, and would otherwise fill "Background apps" with things that aren't apps.
        if isExtension(p) { return .extensions }
        if p.lsType == "UIElement" || p.lsType == "BackgroundOnly" { return isApple(p) ? .systemInterface : .backgroundApps }
        let apple = isApple(p)
        if let l = p.launchdLabel, !apple, !l.hasPrefix("application.") { return .thirdPartyServices }
        return apple ? .systemServices : .other
    }

    /// Sub-group of a unit inside its category, or nil for none.
    static func subgroup(ofRoot p: ProcInfo, in c: ProcCategory) -> String? {
        switch c {
        case .backgroundApps: return p.lsType == "UIElement" ? "Menu bar" : "Background only"
        case .extensions: return p.extensionPoint.map(ExtensionInfo.title) ?? "Unknown extension point"
        case .thirdPartyServices: return p.launchdDomain == "system" || p.uid == 0 ? "Daemons" : "Agents"
        default: return nil
        }
    }

    // MARK: Build

    struct Input {
        var procs: [pid_t: ProcInfo]
        var lsApps: [LSApp]
    }

    static func build(_ input: Input) -> [ProcNode] {
        let procs = input.procs
        // Pass 1: owners. Rule order follows the proposal (pid-domain owner, rule 4, is not read yet).
        var appByBundle: [String: pid_t] = [:]
        for a in input.lsApps where !a.exited {
            if let pid = a.pid, let b = a.bundlePath, procs[pid] != nil { appByBundle[b] = pid }
        }
        var owner: [pid_t: pid_t] = [:]
        for p in procs.values {
            if p.leftBehindGroup != nil { continue }                                  // 1: Left Behind group
            if let r = p.responsible, r != p.pid, procs[r] != nil { owner[p.pid] = r; continue }  // 2
            if isExtension(p), let b = p.bundlePath, let app = appByBundle[b], app != p.pid {     // 3
                owner[p.pid] = app; continue
            }
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
        var members: [pid_t: [ProcInfo]] = [:]
        for p in procs.values { members[root(p.pid), default: []].append(p) }

        // Inside a unit the parent chain gives the structure (a shell under its terminal, a job under the
        // shell); a member whose parent is outside the unit hangs off the root.
        func unitNode(_ rootPid: pid_t, _ ms: [ProcInfo]) -> ProcNode {
            let rootProc = procs[rootPid]!
            var kids: [pid_t: [ProcInfo]] = [:]
            for m in ms where m.pid != rootPid {
                let par = m.ppid != m.pid && rootOf[m.ppid] == rootPid && procs[m.ppid] != nil ? m.ppid : rootPid
                kids[par, default: []].append(m)
            }
            func node(_ p: ProcInfo, depth: Int) -> ProcNode {
                let c = depth < 64 ? (kids[p.pid] ?? []).map { node($0, depth: depth + 1) } : []
                return ProcNode(id: Int(p.pid), proc: p, title: p.name, children: c.isEmpty ? nil : c)
            }
            guard ms.count > 1 else { return node(rootProc, depth: 0) }
            var leaf = ProcNode(id: Int(rootPid), proc: rootProc, title: rootProc.name)
            leaf.fixedOrder = 0   // the app's own process stays at the top of its unit
            let rest = (kids[rootPid] ?? []).map { node($0, depth: 1) }
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
                var g = ProcNode(id: groupID(c, sub), proc: nil, title: sub, children: es.map(\.node))
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
