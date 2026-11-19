import Foundation
import SQLite3

/// What an app offers to Shortcuts, Siri and Spotlight: App Intents (actions, entities, enums, App Shortcuts)
/// and the older SiriKit intents.
///
/// Two sources. Shortcuts' own action index, `~/Library/Shortcuts/ToolKit/Tools-active` (SQLite, private and
/// versioned: `Tools-prod.v80-…`), is the complete list: it includes intents an app declares in its frameworks
/// and extensions, which its own `Metadata.appintents` doesn't. The bundle's `extract.actionsdata` files (JSON)
/// fill in what the index lacks (opens the app when run, App Shortcuts with their phrases) and stand in for it
/// when the app isn't indexed or the index can't be read. docs/automation-tab-proposal.md has the measurements.
enum AppIntentsInfo {
    struct Parameter: Sendable, Equatable, Identifiable {
        var id: String { key }
        var key: String
        var name: String
        var type: String
        var description: String
    }
    struct Action: Sendable, Equatable, Identifiable {
        var id: String
        var name: String
        var summary: String
        /// "appIntent" or "siriIntent" (the index's toolType).
        var kind: String
        /// The index's visibilityFlags. 0 for every action whose metadata says isDiscoverable = false (checked
        /// against 366 actions); what the other bits (seen: 2, 3, 5, 7, 13, 15) mean isn't known.
        var visibilityFlags: Int?
        /// isDiscoverable from the bundle's metadata.
        var discoverable: Bool?
        var openAppWhenRun: Bool?
        var authenticationPolicy: String?
        var parameters: [Parameter]
        var output: String?
        /// Where it came from: "index", or the bundle-relative path of the metadata file.
        var source: String
        var hidden: Bool { visibilityFlags.map { $0 == 0 } ?? (discoverable == false) }
    }
    struct Entity: Sendable, Equatable, Identifiable {
        var id: String
        var name: String
        /// "Entity" or "Enum".
        var kind: String
        /// Entity properties, or enum cases.
        var members: [String]
    }
    struct AppShortcut: Sendable, Equatable, Identifiable {
        var id: String { action + "|" + title }
        var action: String
        var title: String
        var symbol: String?
        var phrases: [String]
    }
    struct SiriKitExtension: Sendable, Equatable, Identifiable {
        var id: String { path }
        var path: String
        var supported: [String]
        var restrictedWhileLocked: [String]
    }

    struct Reading: Sendable, Equatable {
        var actions: [Action] = []
        var entities: [Entity] = []
        var appShortcuts: [AppShortcut] = []
        var siriKit: [SiriKitExtension] = []
        var intentDefinitions: [String] = []
        /// Metadata.appintents directories found in the bundle.
        var metadataFiles: [String] = []
        /// Why the index wasn't used, if it wasn't (missing, unreadable, schema changed).
        var indexNote: String?
        var indexedActions = 0
    }

    static let indexPath = NSHomeDirectory() + "/Library/Shortcuts/ToolKit/Tools-active"

    static func read(bundle path: String, bundleID: String?) -> Reading {
        var r = Reading()
        let files = metadataFiles(in: path)
        r.metadataFiles = files.map { relative($0.file, to: path) }
        let fromBundle = files.map { parseMetadata($0.file, localizer: $0.bundle, appName: appName(path)) }

        if let bundleID {
            switch readIndex(bundleID: bundleID) {
            case .success(let (actions, entities)):
                r.actions = actions
                r.entities = entities
                r.indexedActions = actions.count
            case .failure(let e):
                r.indexNote = e.message
            }
        } else {
            r.indexNote = "The bundle has no identifier, so it can't be looked up in Shortcuts' index."
        }

        // Fill in from the bundle; add what the index lacks.
        let prefix = (bundleID ?? "") + "."
        var byID = Dictionary(r.actions.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        for (i, m) in fromBundle.enumerated() {
            for a in m.actions {
                let full = prefix + a.id
                if let at = byID[full] ?? byID[a.id] {
                    r.actions[at].openAppWhenRun = a.openAppWhenRun
                    r.actions[at].discoverable = a.discoverable
                    if r.actions[at].output == nil { r.actions[at].output = a.output }
                    for p in a.parameters where !r.actions[at].parameters.contains(where: { $0.key == p.key }) {
                        r.actions[at].parameters.append(p)
                    }
                } else {
                    var b = a
                    b.id = full
                    b.source = r.metadataFiles[i]
                    byID[full] = r.actions.count
                    r.actions.append(b)
                }
            }
            for e in m.entities where !r.entities.contains(where: { $0.id == prefix + e.id || $0.name == e.name }) {
                r.entities.append(e)
            }
            r.appShortcuts += m.shortcuts
        }
        r.actions.sort { ($0.hidden ? 1 : 0, $0.name.lowercased()) < ($1.hidden ? 1 : 0, $1.name.lowercased()) }
        r.entities.sort { ($0.kind, $0.name.lowercased()) < ($1.kind, $1.name.lowercased()) }

        (r.siriKit, r.intentDefinitions) = siriKit(in: path)
        return r
    }

    // MARK: - Shortcuts' index

    struct IndexError: Error { var message: String }

    private static func readIndex(bundleID: String) -> Result<([Action], [Entity]), IndexError> {
        guard FileManager.default.fileExists(atPath: indexPath) else {
            return .failure(IndexError(message: "Shortcuts' action index (~/Library/Shortcuts/ToolKit) isn't there."))
        }
        var h: OpaquePointer?
        let uri = "file:" + (indexPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? indexPath) + "?mode=ro"
        guard sqlite3_open_v2(uri, &h, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let h else {
            sqlite3_close(h)
            return .failure(IndexError(message: "Shortcuts' action index couldn't be opened."))
        }
        defer { sqlite3_close(h) }
        sqlite3_busy_timeout(h, 500)

        func rows(_ sql: String, _ binds: [String], _ each: (OpaquePointer) -> Void) -> String? {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(h, sql, -1, &st, nil) == SQLITE_OK, let st else { return String(cString: sqlite3_errmsg(h)) }
            defer { sqlite3_finalize(st) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (i, b) in binds.enumerated() { sqlite3_bind_text(st, Int32(i + 1), b, -1, transient) }
            while true {
                let rc = sqlite3_step(st)
                if rc == SQLITE_DONE { return nil }
                guard rc == SQLITE_ROW else { return String(cString: sqlite3_errmsg(h)) }
                each(st)
            }
        }
        func text(_ st: OpaquePointer, _ i: Int32) -> String? { sqlite3_column_text(st, i).map { String(cString: $0) } }

        // The app's containers: itself and its extensions (com.example.app.widgets), and tools attributed to it.
        let match = "(c.id = ?1 OR c.id LIKE ?2 OR a.id = ?1)"
        let binds = [bundleID, bundleID + ".%"]
        var tools: [Int64: Action] = [:]
        var seen: [String: Int64] = [:]
        let toolsSQL = """
            SELECT t.rowId, t.id, t.toolType, t.visibilityFlags, t.authenticationPolicy FROM Tools t
            JOIN ContainerMetadata c ON c.rowId = t.sourceContainerId
            LEFT JOIN ContainerMetadata a ON a.rowId = t.attributionContainerId
            WHERE \(match) AND t.toolType IN ('appIntent', 'siriIntent') ORDER BY t.rowId
            """
        if let e = rows(toolsSQL, binds, { st in
            let row = sqlite3_column_int64(st, 0), id = text(st, 1) ?? ""
            // One row per indexed bundle version: keep the newest.
            if let old = seen[id] { tools[old] = nil }
            seen[id] = row
            let auth = text(st, 4)
            tools[row] = Action(id: id, name: id, summary: "", kind: text(st, 2) ?? "", visibilityFlags: Int(sqlite3_column_int(st, 3)),
                                authenticationPolicy: auth == "none" ? nil : auth, parameters: [], source: "index")
        }) {
            return .failure(IndexError(message: "Shortcuts' action index has a layout this version doesn't know (\(e))."))
        }

        let locales = preferredLocales()
        func best(_ byLocale: [String: (String, String)]) -> (String, String)? {
            for l in locales { if let v = byLocale[l] { return v } }
            return byLocale.sorted { $0.key < $1.key }.first?.value
        }

        if !tools.isEmpty {
            let ids = tools.keys.map(String.init).joined(separator: ",")
            var names: [Int64: [String: (String, String)]] = [:]
            _ = rows("SELECT toolId, locale, name, descriptionSummary FROM ToolLocalizations WHERE toolId IN (\(ids))", []) { st in
                names[sqlite3_column_int64(st, 0), default: [:]][text(st, 1) ?? ""] = (text(st, 2) ?? "", text(st, 3) ?? "")
            }
            var params: [Int64: [(order: Int, key: String, names: [String: (String, String)])]] = [:]
            _ = rows("""
                SELECT p.toolId, p.key, p.sortOrder, pl.locale, pl.name, pl.description FROM Parameters p
                LEFT JOIN ParameterLocalizations pl ON pl.toolId = p.toolId AND pl.key = p.key
                WHERE p.toolId IN (\(ids))
                """, []) { st in
                let t = sqlite3_column_int64(st, 0), key = text(st, 1) ?? ""
                var list = params[t] ?? []
                var at = list.firstIndex { $0.key == key }
                if at == nil { list.append((Int(sqlite3_column_int(st, 2)), key, [:])); at = list.count - 1 }
                if let l = text(st, 3) { list[at!].names[l] = (text(st, 4) ?? key, text(st, 5) ?? "") }
                params[t] = list
            }
            var types: [String: [String: (String, String)]] = [:]
            _ = rows("""
                SELECT tpt.toolId, tpt.key, ty.rowId, d.locale, d.name FROM ToolParameterTypes tpt
                JOIN Types ty ON ty.rowId = tpt.typeId
                LEFT JOIN TypeDisplayRepresentations d ON d.typeId = ty.rowId
                WHERE tpt.toolId IN (\(ids))
                """, []) { st in
                let k = "\(sqlite3_column_int64(st, 0))|\(text(st, 1) ?? "")", raw = text(st, 2) ?? ""
                let name = text(st, 4).flatMap { $0.isEmpty ? nil : $0 } ?? raw
                types[k, default: [:]][text(st, 3) ?? ""] = (name, "")
            }
            for (row, var a) in tools {
                if let n = names[row].flatMap(best) { a.name = n.0; a.summary = n.1 }
                a.parameters = (params[row] ?? []).sorted { $0.order < $1.order }.map { p in
                    let n = best(p.names)
                    return Parameter(key: p.key, name: n?.0 ?? p.key, type: types["\(row)|\(p.key)"].flatMap(best)?.0 ?? "",
                                     description: n?.1 ?? "")
                }
                tools[row] = a
            }
        }

        // Entities (kind 2) and enums (kind 3). Kind 1 is the primitives, 4 helper types, 6 queries.
        var entities: [String: Entity] = [:]
        var typeNames: [String: [String: (String, String)]] = [:]
        _ = rows("""
            SELECT ty.rowId, ty.kind, d.locale, d.name FROM Types ty
            JOIN ContainerMetadata c ON c.rowId = ty.sourceContainerId
            LEFT JOIN ContainerMetadata a ON 0
            LEFT JOIN TypeDisplayRepresentations d ON d.typeId = ty.rowId
            WHERE \(match) AND ty.kind IN (2, 3)
            """, binds) { st in
            let id = text(st, 0) ?? ""
            if entities[id] == nil { entities[id] = Entity(id: id, name: id, kind: sqlite3_column_int(st, 1) == 3 ? "Enum" : "Entity", members: []) }
            if let l = text(st, 2), let n = text(st, 3), !n.isEmpty { typeNames[id, default: [:]][l] = (n, "") }
        }
        if !entities.isEmpty {
            let inList = entities.keys.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }.joined(separator: ",")
            var members: [String: [String: [String: (String, String)]]] = [:]   // type → member → locale → name
            _ = rows("SELECT typeId, propertyId, locale, displayName FROM EntityPropertyLocalizations WHERE typeId IN (\(inList))", []) { st in
                members[text(st, 0) ?? "", default: [:]][text(st, 1) ?? "", default: [:]][text(st, 2) ?? ""] = (text(st, 3) ?? "", "")
            }
            _ = rows("SELECT typeId, id, locale, title FROM EnumerationCases WHERE typeId IN (\(inList))", []) { st in
                members[text(st, 0) ?? "", default: [:]][text(st, 1) ?? "", default: [:]][text(st, 2) ?? ""] = (text(st, 3) ?? text(st, 1) ?? "", "")
            }
            for (id, var e) in entities {
                if let n = typeNames[id].flatMap(best) { e.name = n.0 }
                e.members = (members[id] ?? [:]).map { best($0.value)?.0 ?? $0.key }.sorted()
                entities[id] = e
            }
        }
        return .success((Array(tools.values), Array(entities.values)))
    }

    /// The index's locale names ("en", "en_GB", "he") for the user's languages, most preferred first.
    private static func preferredLocales() -> [String] {
        var out: [String] = []
        for l in Locale.preferredLanguages {
            let u = l.replacingOccurrences(of: "-", with: "_")
            out.append(u)
            if let lang = u.split(separator: "_").first { out.append(String(lang)) }
        }
        out += ["en_US", "en"]
        return out
    }

    // MARK: - The bundle's metadata

    /// Metadata.appintents/extract.actionsdata in the app, its extensions and its frameworks, each with the
    /// bundle that localizes it.
    private static func metadataFiles(in app: String) -> [(file: String, bundle: Bundle?)] {
        let fm = FileManager.default
        var bundles = [app]
        for dir in ["/Contents/PlugIns", "/Contents/Extensions", "/Contents/Frameworks"] {
            for n in (try? fm.contentsOfDirectory(atPath: app + dir))?.sorted() ?? [] { bundles.append(app + dir + "/" + n) }
        }
        var out: [(String, Bundle?)] = []
        for b in bundles {
            for res in [b + "/Contents/Resources", b + "/Resources", b + "/Versions/A/Resources"] {
                let f = res + "/Metadata.appintents/extract.actionsdata"
                if fm.fileExists(atPath: f) { out.append((f, Bundle(path: b))); break }
            }
        }
        return out
    }

    private struct Metadata { var actions: [Action] = []; var entities: [Entity] = []; var shortcuts: [AppShortcut] = [] }

    private static func parseMetadata(_ file: String, localizer: Bundle?, appName: String) -> Metadata {
        guard let data = FileManager.default.contents(atPath: file),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return Metadata() }
        func loc(_ v: Any?, table: String? = nil) -> String {
            guard let d = v as? [String: Any], let key = d["key"] as? String else { return "" }
            let s = localizer?.localizedString(forKey: key, value: key, table: table) ?? key
            return s.replacingOccurrences(of: "${applicationName}", with: appName)
        }
        var m = Metadata()
        for (id, v) in root["actions"] as? [String: Any] ?? [:] {
            guard let a = v as? [String: Any] else { continue }
            let desc = a["descriptionMetadata"] as? [String: Any]
            let params = (a["parameters"] as? [[String: Any]] ?? []).map { p in
                Parameter(key: p["name"] as? String ?? "", name: loc(p["title"]), type: valueType(p["valueType"]),
                          description: loc(p["parameterDescription"]))
            }
            let auth: String? = switch a["authenticationPolicy"] as? Int {
            case 1: "requiresAuthentication"
            case 2: "requiresLocalDeviceAuthentication"
            default: nil
            }
            m.actions.append(Action(id: a["identifier"] as? String ?? id, name: loc(a["title"]), summary: loc(desc?["descriptionText"]),
                                    kind: "appIntent", visibilityFlags: nil, discoverable: a["isDiscoverable"] as? Bool,
                                    openAppWhenRun: a["openAppWhenRun"] as? Bool, authenticationPolicy: auth, parameters: params,
                                    output: a["outputType"].map { valueType($0) }, source: ""))
        }
        for (id, v) in root["entities"] as? [String: Any] ?? [:] {
            guard let e = v as? [String: Any] else { continue }
            let props = (e["properties"] as? [[String: Any]] ?? []).map { p in
                let t = loc(p["title"]); return t.isEmpty ? (p["identifier"] as? String ?? "") : t
            }
            m.entities.append(Entity(id: e["typeName"] as? String ?? id, name: loc(e["displayTypeName"]), kind: "Entity", members: props))
        }
        for v in root["enums"] as? [[String: Any]] ?? [] {
            let cases = (v["cases"] as? [[String: Any]] ?? []).map { c in
                let t = loc((c["displayRepresentation"] as? [String: Any])?["title"]); return t.isEmpty ? (c["identifier"] as? String ?? "") : t
            }
            m.entities.append(Entity(id: v["identifier"] as? String ?? "", name: loc(v["displayTypeName"]), kind: "Enum", members: cases))
        }
        for v in root["autoShortcuts"] as? [[String: Any]] ?? [] {
            let phrases = (v["phraseTemplates"] as? [Any] ?? []).map { loc($0, table: "AppShortcuts") }
            m.shortcuts.append(AppShortcut(action: v["actionIdentifier"] as? String ?? "", title: loc(v["shortTitle"], table: "AppShortcuts"),
                                           symbol: v["systemImageName"] as? String, phrases: phrases))
        }
        return m
    }

    /// A parameter's valueType, as a name: primitives by their id (decoded from the parameter names that use
    /// them), entities and enums by type name, arrays as "list of …".
    private static func valueType(_ v: Any?) -> String {
        guard let d = v as? [String: Any], let (kind, inner) = d.first, let w = (inner as? [String: Any])?["wrapper"] as? [String: Any] else { return "" }
        switch kind {
        case "primitive":
            let names = [0: "String", 1: "Bool", 2: "Int", 7: "Double", 8: "Date", 10: "Placemark", 11: "URL", 12: "AttributedString"]
            let id = w["typeIdentifier"] as? Int ?? -1
            return names[id] ?? "primitive \(id)"
        case "intents": return (w["typeIdentifier"] as? Int) == 12 ? "IntentFile" : "intents type \(w["typeIdentifier"] ?? "?")"
        case "entity": return w["typeName"] as? String ?? "entity"
        case "linkEnumeration": return w["identifier"] as? String ?? "enum"
        case "measurement": return "Measurement"
        case "array": return "list of " + valueType(w["memberValueType"])
        default: return kind
        }
    }

    // MARK: - SiriKit

    private static func siriKit(in app: String) -> ([SiriKitExtension], [String]) {
        let fm = FileManager.default
        var exts: [SiriKitExtension] = []
        var bundles = [app]
        for n in (try? fm.contentsOfDirectory(atPath: app + "/Contents/PlugIns"))?.sorted() ?? [] { bundles.append(app + "/Contents/PlugIns/" + n) }
        for b in bundles {
            guard let info = NSDictionary(contentsOfFile: b + "/Contents/Info.plist") as? [String: Any] else { continue }
            let attrs = (info["NSExtension"] as? [String: Any])?["NSExtensionAttributes"] as? [String: Any]
            let supported = attrs?["IntentsSupported"] as? [String] ?? info["INIntentsSupported"] as? [String] ?? []
            let locked = attrs?["IntentsRestrictedWhileLocked"] as? [String] ?? []
            if !supported.isEmpty { exts.append(SiriKitExtension(path: b, supported: supported, restrictedWhileLocked: locked)) }
        }
        var defs: [String] = []
        if let e = fm.enumerator(atPath: app + "/Contents") {
            for case let p as String in e where p.hasSuffix(".intentdefinition") { defs.append(app + "/Contents/" + p) }
        }
        return (exts, defs.sorted())
    }

    private static func appName(_ path: String) -> String {
        let b = Bundle(path: path)
        return b?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? b?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    private static func relative(_ p: String, to base: String) -> String {
        p.hasPrefix(base + "/") ? String(p.dropFirst(base.count + 1)) : p
    }
}
