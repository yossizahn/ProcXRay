import AppKit
import SwiftUI

/// What the app exposes to automation, read from its bundle on disk and from Shortcuts' action index: its
/// AppleScript dictionary, its Shortcuts actions (App Intents) and App Shortcuts, and its SiriKit intents.
/// Static, so it's read once per bundle and still shown after the process exits.
/// docs/automation-tab-proposal.md, phase 1.
struct AutomationTab: View {
    let proc: ProcInfo
    var exited = false

    struct Loaded: Sendable, Equatable {
        var bundle: String
        var bundleID: String?
        var declared: ScriptingDictionary.Declared
        var dictionary: ScriptingDictionary.Reading
        var intents: AppIntentsInfo.Reading
    }
    @State private var loaded: Loaded?
    @State private var query = ""
    @State private var showHidden = false
    /// Bumped by Reload, which also drops the cached reading.
    @State private var reload = 0

    private static let cache = Cache()
    final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: Loaded] = [:]
        func get(_ k: String) -> Loaded? { lock.withLock { map[k] } }
        func set(_ k: String, _ v: Loaded) { lock.withLock { map[k] = v } }
        func remove(_ k: String) { _ = lock.withLock { map.removeValue(forKey: k) } }
    }

    var body: some View {
        if let bundle = proc.bundlePath {
            let l = loaded?.bundle == bundle ? loaded : nil
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField("Filter", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    Toggle("Show hidden", isOn: $showHidden).controlSize(.small)
                        .help("Commands, classes and actions the app marks hidden: not in Script Editor's dictionary view, or offered neither in Shortcuts nor to Siri")
                    Spacer()
                    if l != nil {
                        Button("Reload") { Self.cache.remove(bundle); loaded = nil; reload += 1 }
                            .controlSize(.small)
                    }
                }
                .padding(10)
                Divider()
                ScrollView {
                    if let l {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            DictionaryCard(l: l, proc: proc, exited: exited, query: query, showHidden: showHidden)
                            IntentsCard(r: l.intents, bundle: bundle, query: query, showHidden: showHidden)
                            if !l.intents.siriKit.isEmpty || !l.intents.intentDefinitions.isEmpty {
                                SiriKitCard(r: l.intents, bundle: bundle, query: query)
                            }
                        }
                        .padding(10)
                    } else {
                        Text("Reading…").foregroundStyle(.secondary).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .task(id: "\(bundle)|\(reload)") {
                guard loaded?.bundle != bundle else { return }
                if let c = Self.cache.get(bundle) { loaded = c; return }
                let r = await Task.detached { () -> Loaded in
                    let id = Bundle(path: bundle)?.bundleIdentifier
                    return Loaded(bundle: bundle, bundleID: id, declared: ScriptingDictionary.declared(bundle: bundle),
                                  dictionary: ScriptingDictionary.read(bundle: bundle),
                                  intents: AppIntentsInfo.read(bundle: bundle, bundleID: id))
                }.value
                Self.cache.set(bundle, r)
                if !Task.isCancelled { loaded = r }
            }
        } else {
            Text("Not part of an app bundle: nothing here is scriptable or offered to Shortcuts.")
                .foregroundStyle(.secondary).padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// Case-insensitive match of the filter against any of the strings.
private func matches(_ q: String, _ s: [String]) -> Bool {
    q.isEmpty || s.contains { $0.localizedCaseInsensitiveContains(q) }
}

private let mono = Font.system(.body, design: .monospaced)
private let monoSmall = Font.system(.callout, design: .monospaced)

private struct Badge: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text).font(.caption).padding(.horizontal, 5).padding(.vertical, 1)
            .foregroundStyle(color).background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - AppleScript dictionary

private struct DictionaryCard: View {
    let l: AutomationTab.Loaded
    let proc: ProcInfo
    let exited: Bool
    let query: String
    let showHidden: Bool

    var body: some View {
        let d = l.declared
        let trailing: String? = if case .dictionary(let s) = l.dictionary {
            "\(s.suites.count) suites · \(s.commandCount) commands · \(s.classCount) classes"
        } else { nil }
        Card(title: "Scripting dictionary (sdef)", systemImage: "applescript", trailing: trailing) {
            FactGrid(rows: [
                FactRow("Scriptable (NSAppleScriptEnabled)", .text(d.enabled.map { $0 ? "Yes" : "No" } ?? "Not set"), "Info.plist NSAppleScriptEnabled",
                        help: "Whether the app declares AppleScript support. Apps can be scriptable without it (an 'aete' resource, or a dictionary named by OSAScriptingDefinition alone)."),
                FactRow("Dictionary file (OSAScriptingDefinition)", d.sdefFile.map { .path($0) } ?? .text(d.sdefName.map { "\($0) (not in Resources)" } ?? "Not set"),
                        "Info.plist OSAScriptingDefinition"),
            ])
            switch l.dictionary {
            case .none(let why):
                Text(why).foregroundStyle(.secondary)
                Text("Apps without a dictionary still answer the standard events: open, print, quit, activate.")
                    .font(.callout).foregroundStyle(.secondary)
            case .dictionary(let s):
                HStack(spacing: 8) {
                    Button("Explore Live Objects…") {
                        let name = ((l.bundle as NSString).lastPathComponent as NSString).deletingPathExtension
                        ScriptingExplorerWindow.show(pid: proc.pid, name: name, dictionary: s)
                    }
                    .disabled(exited)
                    Text(exited ? "The process has exited." : "Asks the running app for its windows, documents and other objects, and their properties, with Apple Events. macOS asks once for permission (Automation).")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(s.suites.filter { showHidden || !$0.hidden }) { SuiteView(suite: $0, query: query, showHidden: showHidden) }
            }
        }
    }
}

private struct SuiteView: View {
    let suite: ScriptingDictionary.Suite
    let query: String
    let showHidden: Bool

    var body: some View {
        let cmds = suite.commands.filter { (showHidden || !$0.hidden) && matches(query, [$0.name, $0.description] + $0.parameters.map(\.name)) }
        let classes = suite.classes.filter { (showHidden || !$0.hidden) && matches(query, [$0.name, $0.description] + $0.properties.map(\.name) + $0.elements.map(\.type)) }
        let records = suite.records.filter { (showHidden || !$0.hidden) && matches(query, [$0.name] + $0.properties.map(\.name)) }
        let enums = suite.enumerations.filter { (showHidden || !$0.hidden) && matches(query, [$0.name] + $0.enumerators.map(\.name)) }
        let shown = cmds.count + classes.count + records.count + enums.count
        if shown > 0 || matches(query, [suite.name]) {
            let counts = [(cmds.count, "command"), (classes.count, "class"), (records.count, "record type"), (enums.count, "enumeration")]
                .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : $0.1.hasSuffix("s") ? "es" : "s")" }.joined(separator: " · ")
            Collapsible(title: "\(suite.name)  \(suite.code.isEmpty ? "" : "‘\(suite.code)’")" + (counts.isEmpty ? "" : "   —  \(counts)"),
                        startsOpen: !query.isEmpty) {
                VStack(alignment: .leading, spacing: 8) {
                    if !suite.description.isEmpty { Text(suite.description).foregroundStyle(.secondary) }
                    if !cmds.isEmpty { section("Commands") { ForEach(cmds) { CommandView(c: $0, showHidden: showHidden) } } }
                    if !classes.isEmpty { section("Classes") { ForEach(classes) { ClassView(c: $0, showHidden: showHidden) } } }
                    if !records.isEmpty { section("Record types") { ForEach(records) { ClassView(c: $0, showHidden: showHidden) } } }
                    if !enums.isEmpty { section("Enumerations") { ForEach(enums) { EnumView(e: $0) } } }
                }
                .padding(.leading, 14)
            }
        }
    }

    @ViewBuilder private func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 6) { c() }
    }
}

/// `name ‘code’` and the description, the header of every dictionary item.
private struct ItemHeader: View {
    let name: String
    let code: String
    var kind: String? = nil
    var hidden = false
    let description: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(verbatim: name).font(mono.weight(.semibold)).textSelection(.enabled)
                if !code.isEmpty { Text(verbatim: "‘\(code)’").font(monoSmall).foregroundStyle(.tertiary).textSelection(.enabled) }
                if let kind { Text(kind).font(.callout).foregroundStyle(.secondary) }
                if hidden { Badge(text: "Hidden (hidden)") }
            }
            if !description.isEmpty { Text(description).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
        }
    }
}

private struct TypedRow: View {
    let label: String
    let t: ScriptingDictionary.Typed
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: label).font(monoSmall).frame(minWidth: 120, alignment: .leading)
            Text(verbatim: t.type).font(monoSmall).foregroundStyle(.blue)
            if t.optional { Text("optional").font(.caption).foregroundStyle(.secondary) }
            switch t.access {
            case "r": Badge(text: "Read-only (r)")
            case "w": Badge(text: "Write-only (w)")
            default: EmptyView()
            }
            if t.hidden { Badge(text: "Hidden") }
            if !t.description.isEmpty { Text(t.description).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
        }
        .textSelection(.enabled)
    }
}

private struct CommandView: View {
    let c: ScriptingDictionary.Command
    let showHidden: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ItemHeader(name: c.name, code: c.code, hidden: c.hidden, description: c.description)
            VStack(alignment: .leading, spacing: 1) {
                if let d = c.direct { TypedRow(label: "direct parameter", t: d) }
                ForEach(Array(c.parameters.filter { showHidden || !$0.hidden }.enumerated()), id: \.offset) { TypedRow(label: $0.element.name, t: $0.element) }
                if let r = c.result { TypedRow(label: "→ result", t: r) }
            }
            .padding(.leading, 14)
        }
    }
}

private struct ClassView: View {
    let c: ScriptingDictionary.Class
    let showHidden: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ItemHeader(name: c.name, code: c.code,
                       kind: c.isExtension ? "adds to the \(c.name) class (class-extension)" : (c.inherits.isEmpty ? nil : "inherits from \(c.inherits)"),
                       hidden: c.hidden, description: c.description)
            VStack(alignment: .leading, spacing: 1) {
                if !c.elements.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("contains").font(.callout).foregroundStyle(.secondary).frame(minWidth: 120, alignment: .leading)
                        Text(verbatim: c.elements.map { $0.type + ($0.access == "r" ? " (read-only)" : "") }.joined(separator: ", "))
                            .font(monoSmall).foregroundStyle(.blue).textSelection(.enabled)
                    }
                }
                ForEach(Array(c.properties.filter { showHidden || !$0.hidden }.enumerated()), id: \.offset) { TypedRow(label: $0.element.name, t: $0.element) }
                if !c.respondsTo.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("responds to").font(.callout).foregroundStyle(.secondary).frame(minWidth: 120, alignment: .leading)
                        Text(verbatim: c.respondsTo.joined(separator: ", ")).font(monoSmall).textSelection(.enabled)
                    }
                }
            }
            .padding(.leading, 14)
        }
    }
}

private struct EnumView: View {
    let e: ScriptingDictionary.Enumeration
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ItemHeader(name: e.name, code: e.code, hidden: e.hidden, description: e.description)
            Text(verbatim: e.enumerators.map(\.name).joined(separator: ", ")).font(monoSmall).foregroundStyle(.blue)
                .textSelection(.enabled).padding(.leading, 14)
        }
    }
}

// MARK: - App Intents

private struct IntentsCard: View {
    let r: AppIntentsInfo.Reading
    let bundle: String
    let query: String
    let showHidden: Bool

    var body: some View {
        let actions = r.actions.filter {
            (showHidden || !$0.hidden) && matches(query, [$0.name, $0.id, $0.summary] + $0.parameters.map(\.name) + $0.schemas + $0.traits)
        }
        let hiddenCount = r.actions.filter(\.hidden).count
        let siriOnly = r.actions.filter(\.siriOnly).count
        let schemas = r.actions.filter { !$0.schemas.isEmpty }.count
        let entities = r.entities.filter { matches(query, [$0.name, $0.id] + $0.members) }
        let shortcuts = r.appShortcuts.filter { matches(query, [$0.title, $0.action] + $0.phrases) }
        Card(title: "Shortcuts actions (App Intents)", systemImage: "square.stack.3d.up",
             trailing: "\(r.actions.count) actions" + (hiddenCount > 0 ? " · \(hiddenCount) hidden" : "")
                + (siriOnly > 0 ? " · \(siriOnly) Siri only" : "") + (schemas > 0 ? " · \(schemas) Apple Intelligence" : "")
                + " · \(r.entities.count) types" + (r.appShortcuts.isEmpty ? "" : " · \(r.appShortcuts.count) App Shortcuts")) {
            sources
            if r.actions.isEmpty && r.entities.isEmpty && r.appShortcuts.isEmpty {
                Text("The app offers no actions to Shortcuts.").foregroundStyle(.secondary)
            }
            if !shortcuts.isEmpty {
                Collapsible(title: "App Shortcuts: ready-made, with Siri phrases (AppShortcutsProvider) — \(shortcuts.count)", startsOpen: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(shortcuts) { s in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: s.symbol ?? "square.on.square").foregroundStyle(.secondary).frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(s.title).font(.body.weight(.semibold))
                                        Text(verbatim: s.action).font(monoSmall).foregroundStyle(.tertiary)
                                    }
                                    ForEach(s.phrases, id: \.self) { Text("“\($0)”").font(.callout).foregroundStyle(.secondary) }
                                }
                            }
                            .textSelection(.enabled)
                        }
                    }
                    .padding(.leading, 14)
                }
            }
            if !actions.isEmpty {
                Collapsible(title: "Actions — \(actions.count)", startsOpen: true) {
                    VStack(alignment: .leading, spacing: 6) { ForEach(actions) { ActionView(a: $0) } }.padding(.leading, 14)
                }
            }
            if !entities.isEmpty {
                Collapsible(title: "Types: things the actions take and return (AppEntity, AppEnum) — \(entities.count)", startsOpen: !query.isEmpty) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(entities) { e in
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(e.name).font(.body.weight(.semibold))
                                    Badge(text: e.kind == "Enum" ? "Choice list (AppEnum)" : "Object (AppEntity)")
                                    Text(verbatim: e.id).font(monoSmall).foregroundStyle(.tertiary)
                                }
                                if !e.members.isEmpty {
                                    Text(e.members.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary)
                                }
                            }
                            .textSelection(.enabled)
                        }
                    }
                    .padding(.leading, 14)
                }
            }
        }
    }

    @ViewBuilder private var sources: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let note = r.indexNote {
                Text(note + " Showing what the bundle declares, which can miss intents in its frameworks.")
                    .font(.callout).foregroundStyle(.orange)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("From Shortcuts' action index: \(r.indexedActions) actions.").font(.callout).foregroundStyle(.secondary)
                    RevealButton(path: (AppIntentsInfo.indexPath as NSString).resolvingSymlinksInPath)
                }
            }
            if !r.metadataFiles.isEmpty {
                ForEach(r.metadataFiles, id: \.self) { f in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(verbatim: "Declared in \(f)").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        RevealButton(path: bundle + "/" + f)
                    }
                }
            }
        }
    }
}

private struct ActionView: View {
    let a: AppIntentsInfo.Action
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(a.name).font(.body.weight(.semibold))
                if a.hidden {
                    Badge(text: a.visibilityFlags != nil ? "Hidden from Shortcuts and Siri (visibilityFlags)" : "Hidden from Shortcuts (isDiscoverable)")
                }
                if a.siriOnly {
                    Badge(text: "Siri only, not in Shortcuts (\(a.assistantOnly == true ? "assistantOnly" : "visibilityFlags"))", color: .purple)
                }
                ForEach(a.schemas, id: \.self) { Badge(text: "Apple Intelligence schema (\($0))", color: .pink) }
                if a.schemas.isEmpty && a.assistantInvocable { Badge(text: "Siri can call it directly (AssistantIntent)", color: .purple) }
                if a.kind == "siriIntent" { Badge(text: "SiriKit intent (INIntent)", color: .purple) }
                if a.openAppWhenRun == true { Badge(text: "Opens the app (openAppWhenRun)", color: .blue) }
                if let p = a.authenticationPolicy {
                    Badge(text: p.contains("Local") ? "Needs the Mac unlocked (\(p))" : "Needs authentication (\(p))", color: .orange)
                }
                if a.source != "index" { Badge(text: "Not in Shortcuts' index", color: .orange) }
            }
            .help(help)
            Text(verbatim: a.id).font(monoSmall).foregroundStyle(.tertiary)
            if !a.summary.isEmpty { Text(a.summary).font(.callout).foregroundStyle(.secondary) }
            if !a.traits.isEmpty {
                Text("Roles: " + a.traits.map(Self.trait).joined(separator: ", ")).font(.callout).foregroundStyle(.secondary)
            }
            if !a.parameters.isEmpty || a.output != nil {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(a.parameters) { p in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(p.name.isEmpty ? p.key : p.name).font(.callout).frame(minWidth: 120, alignment: .leading)
                            if !p.type.isEmpty { Text(verbatim: p.type).font(monoSmall).foregroundStyle(.blue) }
                            if !p.description.isEmpty { Text(p.description).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                        }
                    }
                    if let o = a.output, !o.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("→ result").font(.callout).frame(minWidth: 120, alignment: .leading)
                            Text(verbatim: o).font(monoSmall).foregroundStyle(.blue)
                        }
                    }
                }
                .padding(.leading, 14)
            }
        }
        .textSelection(.enabled)
    }

    private var help: String {
        var parts: [String] = []
        if let v = a.visibilityFlags {
            var bits = [v & 1 != 0 ? "in Shortcuts" : "not in Shortcuts", v & 2 != 0 ? "offered to Siri" : "not offered to Siri"]
            if v & ~3 != 0 { bits.append("other bits 0x\(String(v & ~3, radix: 16)) not decoded") }
            parts.append("visibilityFlags \(v): " + bits.joined(separator: ", "))
        }
        parts.append(a.source == "index" ? "from Shortcuts' index" : a.source)
        return parts.joined(separator: " · ")
    }

    /// The system protocols the index names, as "friendly phrase (term)".
    private static func trait(_ t: String) -> String {
        let names = [
            "openEntity": "opens an item", "deleteEntity": "deletes items", "createEntity": "creates an item",
            "entityUpdating": "changes an item", "propertyUpdater": "changes an item", "entityGetter": "gets an item",
            "closeEntity": "closes an item", "putEntityInContainer": "moves an item", "favoriteEntity": "favorites an item",
            "urlRepresentable": "has a link", "batchable": "runs on many at once", "sideEffect": "changes things",
            "audioStarting": "starts audio", "audioRecording": "records audio", "sessionStarting": "starts a session",
            "foregroundContinuable": "can continue in the app", "progressReporting": "reports progress",
            "widgetConfiguration": "configures a widget", "controlConfiguration": "configures a control",
            "focusConfiguration": "a Focus filter", "valueSetting": "sets a value", "setValue": "sets a value",
            "changeBinarySetting": "turns a setting on or off", "search": "searches",
            "showInAppStringSearchResults": "searches in the app", "undoable": "can be undone",
            "synthesizedTool": "made by the system", "systemFrameworkIntent": "from a system framework",
            "requiresMDMChecks": "subject to device management", "longRunning": "runs long",
        ]
        return names[t].map { "\($0) (\(t))" } ?? t
    }
}

// MARK: - SiriKit

private struct SiriKitCard: View {
    let r: AppIntentsInfo.Reading
    let bundle: String
    let query: String
    var body: some View {
        Card(title: "SiriKit intents (IntentsSupported)", systemImage: "mic", trailing: "\(r.siriKit.reduce(0) { $0 + $1.supported.count })") {
            Text("The older intents framework: handled by an Intents extension, listed in its Info.plist.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(r.siriKit.filter { matches(query, $0.supported + [$0.path]) }) { e in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(verbatim: e.path == bundle ? "The app" : (e.path as NSString).lastPathComponent).font(.body.weight(.semibold))
                        RevealButton(path: e.path)
                    }
                    ForEach(e.supported, id: \.self) { i in
                        HStack(spacing: 6) {
                            Text(verbatim: i).font(monoSmall)
                            if e.restrictedWhileLocked.contains(i) { Badge(text: "Not while locked (IntentsRestrictedWhileLocked)") }
                        }
                        .padding(.leading, 14)
                    }
                }
                .textSelection(.enabled)
            }
            if !r.intentDefinitions.isEmpty {
                Text("Intent definition files (.intentdefinition)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(r.intentDefinitions, id: \.self) { p in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(verbatim: p.hasPrefix(bundle + "/") ? String(p.dropFirst(bundle.count + 1)) : p).font(monoSmall).textSelection(.enabled)
                        RevealButton(path: p)
                    }
                }
            }
        }
    }
}
