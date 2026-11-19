import Carbon
import Foundation

/// An app's AppleScript dictionary (sdef), read from the bundle on disk. `OSACopyScriptingDefinitionFromURL`
/// returns it whatever form the app ships (an .sdef, an old 'aete' resource, .scriptSuite/.scriptTerminology),
/// as sdef XML; xi:include elements (most Cocoa apps pull in CocoaStandard.sdef) are resolved by the parser.
struct ScriptingDictionary: Sendable, Equatable {
    struct Typed: Sendable, Equatable {
        var name: String
        var code: String
        var type: String
        var description: String
        var hidden = false
        var optional = false
        /// Properties: "r", "w" or "rw" (the default).
        var access = "rw"
    }
    struct Command: Sendable, Equatable, Identifiable {
        var id: String { "\(suite)|\(name)|\(code)" }
        var suite: String
        var name: String
        var code: String
        var description: String
        var hidden: Bool
        var direct: Typed?
        var parameters: [Typed]
        var result: Typed?
    }
    struct Class: Sendable, Equatable, Identifiable {
        var id: String { "\(suite)|\(name)|\(code)|\(isExtension)" }
        var suite: String
        var name: String
        var code: String
        var plural: String
        var inherits: String
        var description: String
        var hidden: Bool
        /// A class-extension: adds properties and elements to a class defined elsewhere (`name` is the class extended).
        var isExtension: Bool
        var properties: [Typed]
        /// Element class names, with access.
        var elements: [(type: String, access: String)]
        var respondsTo: [String]
        static func == (a: Class, b: Class) -> Bool {
            a.id == b.id && a.properties == b.properties && a.elements.map(\.type) == b.elements.map(\.type)
        }
    }
    struct Enumeration: Sendable, Equatable, Identifiable {
        var id: String { "\(suite)|\(name)|\(code)" }
        var suite: String
        var name: String
        var code: String
        var description: String
        var hidden: Bool
        var enumerators: [Typed]
    }
    struct Suite: Sendable, Equatable, Identifiable {
        var id: String { "\(name)|\(code)" }
        var name: String
        var code: String
        var description: String
        var hidden: Bool
        var commands: [Command] = []
        var classes: [Class] = []
        var enumerations: [Enumeration] = []
        /// record-type: a structured value, shown like a class with properties only.
        var records: [Class] = []
    }

    var suites: [Suite]

    var commandCount: Int { suites.reduce(0) { $0 + $1.commands.count } }
    var classCount: Int { suites.reduce(0) { $0 + $1.classes.count } }

    /// The bundle's declaration, from its Info.plist.
    struct Declared: Sendable, Equatable {
        /// NSAppleScriptEnabled.
        var enabled: Bool?
        /// OSAScriptingDefinition, resolved to a path when it names a file in Resources.
        var sdefFile: String?
        var sdefName: String?
    }

    enum Reading: Sendable, Equatable {
        case dictionary(ScriptingDictionary)
        /// The app has no dictionary (errOSACorruptTerminology -192 and friends), or it didn't parse.
        case none(String)
    }

    static func declared(bundle path: String) -> Declared {
        let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any] ?? [:]
        let name = info["OSAScriptingDefinition"] as? String
        var file: String?
        if let name {
            let p = path + "/Contents/Resources/" + name
            if FileManager.default.fileExists(atPath: p) { file = p }
        }
        let enabled: Bool? = switch info["NSAppleScriptEnabled"] {
        case let b as Bool: b
        case let s as String: ["yes", "true", "1"].contains(s.lowercased())
        default: nil
        }
        return Declared(enabled: enabled, sdefFile: file, sdefName: name)
    }

    static func read(bundle path: String) -> Reading {
        var out: Unmanaged<CFData>?
        let err = OSACopyScriptingDefinitionFromURL(URL(fileURLWithPath: path) as CFURL, 0, &out)
        guard err == noErr, let data = out?.takeRetainedValue() as Data? else {
            return .none(err == -192 ? "No scripting dictionary." : "No scripting dictionary (OSACopyScriptingDefinitionFromURL: \(err)).")
        }
        do {
            return .dictionary(try parse(data))
        } catch {
            return .none("The dictionary didn't parse: \(error.localizedDescription)")
        }
    }

    static func parse(_ data: Data) throws -> ScriptingDictionary {
        let doc = try XMLDocument(data: data, options: [.documentXInclude])
        var suites: [Suite] = []
        for s in try doc.nodes(forXPath: "/dictionary/suite").compactMap({ $0 as? XMLElement }) {
            let sn = s.attr("name")
            var suite = Suite(name: sn, code: s.attr("code"), description: s.attr("description"), hidden: s.isHidden)
            for e in s.children?.compactMap({ $0 as? XMLElement }) ?? [] {
                switch e.name {
                case "command", "event":
                    suite.commands.append(Command(
                        suite: sn, name: e.attr("name"), code: e.attr("code"), description: e.attr("description"), hidden: e.isHidden,
                        direct: e.elements(forName: "direct-parameter").first.map { typed($0) },
                        parameters: e.elements(forName: "parameter").map { typed($0) },
                        result: e.elements(forName: "result").first.map { typed($0) }))
                case "class", "class-extension", "record-type":
                    let ext = e.name == "class-extension"
                    let c = Class(
                        suite: sn, name: ext ? e.attr("extends") : e.attr("name"), code: e.attr("code"), plural: e.attr("plural"),
                        inherits: e.attr("inherits"), description: e.attr("description"), hidden: e.isHidden, isExtension: ext,
                        properties: e.elements(forName: "property").map { typed($0) },
                        elements: e.elements(forName: "element").map { (type: typeName($0), access: $0.attr("access")) },
                        respondsTo: e.elements(forName: "responds-to").map { $0.attr("command").isEmpty ? $0.attr("name") : $0.attr("command") })
                    if e.name == "record-type" { suite.records.append(c) } else { suite.classes.append(c) }
                case "enumeration":
                    suite.enumerations.append(Enumeration(
                        suite: sn, name: e.attr("name"), code: e.attr("code"), description: e.attr("description"), hidden: e.isHidden,
                        enumerators: e.elements(forName: "enumerator").map { typed($0) }))
                default: break
                }
            }
            suites.append(suite)
        }
        return ScriptingDictionary(suites: suites)
    }

    private static func typed(_ e: XMLElement) -> Typed {
        Typed(name: e.attr("name"), code: e.attr("code"), type: typeName(e), description: e.attr("description"),
              hidden: e.isHidden, optional: e.attr("optional") == "yes", access: e.attr("access").isEmpty ? "rw" : e.attr("access"))
    }

    /// The `type` attribute, or the `<type>` children ("list of file", "text or alias").
    private static func typeName(_ e: XMLElement) -> String {
        let t = e.attr("type")
        if !t.isEmpty { return t }
        let alts = e.elements(forName: "type").map { ($0.attr("list") == "yes" ? "list of " : "") + $0.attr("type") }
        return alts.joined(separator: " or ")
    }
}

private extension XMLElement {
    func attr(_ name: String) -> String { attribute(forName: name)?.stringValue ?? "" }
    var isHidden: Bool { attr("hidden") == "yes" || !elements(forName: "hidden").isEmpty }
}
