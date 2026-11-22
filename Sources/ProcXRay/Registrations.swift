import Foundation

/// A system registry that knows a process, shown as a small glyph after its name in the process table; a click
/// on it opens a bubble with what the registry is and what it has on record. Together they say who started the
/// process and who can start it again.
struct Registration: Equatable, Sendable {
    enum Kind: Sendable { case launchServices, launchdJob, launchdAppJob, xpcService, appExtension, backgroundItem }

    /// One labelled value in the bubble (InfoBubble.Section).
    struct Fact: Equatable, Sendable {
        let label: String
        let value: String
        var mono = false
        /// A path to offer reveal-in-Finder for.
        var reveal: String? = nil
    }

    let kind: Kind
    /// The bubble's facts, after the registry's own description.
    let facts: [Fact]
    /// Something to look at: a Background Items record that is disabled or not allowed.
    var warning = false

    var symbol: String {
        switch kind {
        case .launchServices: "app"
        case .launchdJob: "gearshape.fill"
        case .launchdAppJob: "gearshape"
        case .xpcService: "cable.connector"
        case .appExtension: "puzzlepiece.extension"
        case .backgroundItem: "clock.arrow.circlepath"
        }
    }

    /// The bubble's first section title, and the glyph's accessibility label.
    var title: String {
        switch kind {
        case .launchServices: "Registered with LaunchServices"
        case .launchdJob: "Its own launchd job"
        case .launchdAppJob: "launchd job made for an app"
        case .xpcService: "XPC service"
        case .appExtension: "App extension"
        case .backgroundItem: "In Background Items"
        }
    }

    /// What the registry is, in a sentence or two.
    var about: String {
        switch kind {
        case .launchServices:
            "LaunchServices knows it as an app: it has an entry in lsappinfo, gets activated, opened and quit as an app, and can be found by bundle id."
        case .launchdJob:
            "launchd runs it as a job someone declared, in a LaunchAgents or LaunchDaemons plist or through SMAppService. launchd starts it again on demand or when it exits, as the job says."
        case .launchdAppJob:
            "launchd makes one of these for every app LaunchServices starts. Nobody declared it: it goes away when the app quits."
        case .xpcService:
            "A service bundle (.xpc) inside an app or framework. launchd starts it when a client first connects, and may end it when it's idle."
        case .appExtension:
            "An app extension (.appex) that the system or another app loads for an extension point, through ExtensionKit or PlugInKit."
        case .backgroundItem:
            "Background Task Management keeps a record of it: it's listed under System Settings › General › Login Items & Extensions, where it can be turned off."
        }
    }
}

enum Registrations {
    /// In display order: LaunchServices, launchd (a declared job, or the one launchd made for an app), XPC
    /// service, app extension, Background Items. `btm` is Store.btmItems: empty until Background Items load.
    static func of(_ p: ProcInfo, btm: [String: [BTMItem]]) -> [Registration] {
        typealias Fact = Registration.Fact
        var out: [Registration] = []
        if p.lsType != nil || p.lsAppName != nil {
            out.append(Registration(kind: .launchServices, facts: [
                p.lsAppName.map { Fact(label: "Name", value: $0) },
                p.lsType.map { Fact(label: "Type", value: lsTypeText($0)) },
                p.lsTags.isEmpty ? nil : Fact(label: "State", value: p.lsTags.joined(separator: " ")),
            ].compactMap { $0 }))
        }
        let xpc = isXPCService(p.path)
        if let l = p.launchdLabel, l.hasPrefix("application.") || !xpc {
            let facts = [
                Fact(label: "Label", value: l, mono: true),
                p.launchdDomain.map { Fact(label: "Domain", value: domainText($0)) },
            ].compactMap { $0 }
            out.append(Registration(kind: l.hasPrefix("application.") ? .launchdAppJob : .launchdJob, facts: facts))
        }
        if xpc {
            out.append(Registration(kind: .xpcService, facts: [
                (p.domainOwnerName ?? bundleName(p.path)).map { Fact(label: "Ships in", value: $0) },
                p.launchdLabel.map { Fact(label: "Job label", value: $0, mono: true) },
                p.path.flatMap(xpcBundle).map { Fact(label: "Bundle", value: $0, mono: true, reveal: $0) },
            ].compactMap { $0 }))
        }
        if let e = p.extensionPoint {
            out.append(Registration(kind: .appExtension, facts: [
                Fact(label: "Kind", value: ExtensionInfo.title(e)),
                Fact(label: "Extension point", value: e, mono: true),
                p.containingAppName.map { Fact(label: "In", value: $0) },
            ].compactMap { $0 }))
        } else if SmartTree.isExtension(p) {
            out.append(Registration(kind: .appExtension, facts: p.containingAppName.map { [Fact(label: "In", value: $0)] } ?? []))
        }
        if let i = backgroundItem(p, btm) {
            let state = [i.enabled ? "enabled" : "disabled", i.allowed ? "allowed" : "not allowed"].joined(separator: ", ")
            let type = i.type.components(separatedBy: " (").first ?? i.type
            let plist = i.url.hasPrefix("/") && i.url.hasSuffix(".plist") ? i.url : nil
            out.append(Registration(kind: .backgroundItem, facts: [
                Fact(label: "Item", value: "“\(i.name)”, \(type)"),
                Fact(label: "State", value: state),
                i.developer.isEmpty || i.developer == "(null)" ? nil : Fact(label: "Developer", value: i.developer),
                i.parentBundleID.map { Fact(label: "Installed by", value: $0, mono: true) },
                plist.map { Fact(label: "Plist", value: $0, mono: true, reveal: $0) },
                Fact(label: "Identifier", value: i.identifier, mono: true),
            ].compactMap { $0 }, warning: !i.enabled || !i.allowed))
        }
        return out
    }

    /// The process's own record: by job label, else by executable path; the process's user's record first.
    static func backgroundItem(_ p: ProcInfo, _ btm: [String: [BTMItem]]) -> BTMItem? {
        guard !btm.isEmpty else { return nil }
        let found = p.launchdLabel.flatMap { btm["label:" + $0] } ?? p.path.flatMap { btm["path:" + $0] }
        guard let found else { return nil }
        return found.first { $0.uid == String(p.uid) } ?? found.first
    }

    static func isXPCService(_ path: String?) -> Bool {
        guard let path else { return false }
        return path.containsBytes(".xpc/Contents/MacOS/")
    }

    /// "/…/Bar.xpc" from its executable's path.
    private static func xpcBundle(_ path: String) -> String? {
        path.byteRange(of: ".xpc/Contents/MacOS/", backwards: true).map { String(path[..<$0.lowerBound]) + ".xpc" }
    }

    /// The bundle an XPC service ships in: "Slack" for an app's, "CascadeSets.framework" for a framework's.
    private static func bundleName(_ path: String?) -> String? {
        guard let path, let r = path.byteRange(of: "/XPCServices/", backwards: true) else { return nil }
        let bundle = (String(path[..<r.lowerBound]) as NSString).pathComponents.reversed()
            .first { $0.contains(".") && $0 != "Contents" }
        guard let bundle else { return nil }
        return bundle.hasSuffix(".app") ? String(bundle.dropLast(4)) : bundle
    }

    static func lsTypeText(_ t: String) -> String {
        switch t {
        case "Foreground": "App with a Dock icon (Foreground)"
        case "UIElement": "UI without a Dock icon (UIElement)"
        case "BackgroundOnly": "No UI (BackgroundOnly)"
        default: t
        }
    }

    static func domainText(_ d: String) -> String {
        switch d {
        case "gui": "Your login session (gui)"
        case "user": "Your user (user)"
        case "system": "The system (system)"
        default: d
        }
    }
}
