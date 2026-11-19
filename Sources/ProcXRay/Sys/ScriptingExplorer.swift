import Carbon
import Foundation

/// A running app's AppleScript objects, read with Apple Events the way Script Debugger's Explorer reads them:
/// `get properties of <object>` for its values, `count every <element> of <object>` for each kind of child,
/// and `get <element> i of <object>` for the children, a page at a time. The app's dictionary says which
/// classes have which elements and names every four-character code in the replies.
/// Events go to the pid (never by name or bundle id, so nothing is launched), wait at most `timeout`, and
/// never ask the app to interact. docs/automation-tab-proposal.md, phase 2.
enum ScriptingExplorer {
    static let timeout: TimeInterval = 3
    static let pageSize = 50

    // MARK: - The dictionary, indexed by code

    /// The dictionary's classes merged with their extensions and what they inherit, and a name for each code.
    struct Model: Sendable {
        struct ClassInfo: Sendable {
            var name: String
            var plural: String
            var code: FourCharCode
            var properties: [(name: String, code: FourCharCode, type: String)]
            var elements: [(name: String, plural: String, code: FourCharCode)]
        }
        private var classesByName: [String: [ScriptingDictionary.Class]] = [:]
        private var classNames: [FourCharCode: String] = [:]
        private var pluralNames: [FourCharCode: String] = [:]
        private var propertyNames: [FourCharCode: String] = [:]
        private var enumeratorNames: [FourCharCode: String] = [:]
        /// For references: `… of application "Finder"`.
        var appName: String

        init(_ d: ScriptingDictionary, appName: String) {
            self.appName = appName
            // Standard codes, for apps whose dictionary leaves them out.
            classNames = [fcc("capp"): "application", fcc("cobj"): "item", fcc("cwin"): "window", fcc("docu"): "document",
                          fcc("TEXT"): "text", fcc("utxt"): "text", fcc("long"): "integer", fcc("doub"): "real",
                          fcc("bool"): "boolean", fcc("ldt "): "date", fcc("list"): "list", fcc("reco"): "record",
                          fcc("type"): "type class", fcc("qdrt"): "bounding rectangle", fcc("furl"): "file", fcc("alis"): "alias"]
            propertyNames = [fcc("pnam"): "name", fcc("pcls"): "class", fcc("ID  "): "id", fcc("pALL"): "properties",
                             fcc("pidx"): "index", fcc("ctnr"): "container", fcc("pbnd"): "bounds", fcc("pvis"): "visible"]
            enumeratorNames = [fcc("yes "): "yes", fcc("no  "): "no", fcc("ask "): "ask"]
            for s in d.suites {
                for c in s.classes + s.records {
                    classesByName[c.name, default: []].append(c)
                    if !c.isExtension, !c.code.isEmpty {
                        classNames[fcc(c.code)] = c.name
                        pluralNames[fcc(c.code)] = c.plural.isEmpty ? c.name + "s" : c.plural
                    }
                    for p in c.properties where !p.code.isEmpty { propertyNames[fcc(p.code)] = p.name }
                }
                for e in s.enumerations { for v in e.enumerators where !v.code.isEmpty { enumeratorNames[fcc(v.code)] = v.name } }
            }
        }

        func className(_ c: FourCharCode) -> String { classNames[c] ?? "«class \(string(c))»" }
        func plural(_ c: FourCharCode) -> String { pluralNames[c] ?? className(c) + "s" }
        func propertyName(_ c: FourCharCode) -> String { propertyNames[c] ?? "«property \(string(c))»" }
        func constantName(_ c: FourCharCode) -> String {
            enumeratorNames[c] ?? classNames[c] ?? propertyNames[c] ?? "«constant \(string(c))»"
        }

        /// A class with its extensions and everything it inherits; nil if the dictionary doesn't have it.
        func classInfo(_ code: FourCharCode) -> ClassInfo? {
            guard let name = classNames[code], classesByName[name] != nil else { return nil }
            var props: [(String, FourCharCode, String)] = [], elems: [(String, String, FourCharCode)] = []
            var seenProps = Set<FourCharCode>(), seenElems = Set<FourCharCode>(), visited = Set<String>()
            var next: String? = name
            while let n = next, !visited.contains(n), let defs = classesByName[n] {
                visited.insert(n)
                next = nil
                for c in defs {
                    for p in c.properties where !p.code.isEmpty && seenProps.insert(fcc(p.code)).inserted {
                        props.append((p.name, fcc(p.code), p.type))
                    }
                    for e in c.elements {
                        guard let code = classesByName[e.type]?.first(where: { !$0.isExtension })?.code ?? classNames.first(where: { $0.value == e.type })?.key.string,
                              !code.isEmpty, seenElems.insert(fcc(code)).inserted else { continue }
                        elems.append((e.type, plural(fcc(code)), fcc(code)))
                    }
                    if !c.isExtension, !c.inherits.isEmpty { next = c.inherits }
                }
            }
            return ClassInfo(name: name, plural: plural(code), code: code, properties: props, elements: elems)
        }
    }

    // MARK: - Permission

    enum Permission: Equatable, Sendable {
        case allowed
        /// The user hasn't been asked yet (errAEEventWouldRequireUserConsent).
        case notAsked
        /// Denied in System Settings ▸ Privacy & Security ▸ Automation (errAEEventNotPermitted).
        case denied
        case notRunning
        case other(OSStatus)
    }

    /// Whether this process may send Apple Events to `pid`. `ask` shows the system's consent prompt when the
    /// user hasn't been asked; it blocks until they answer.
    static func permission(_ pid: pid_t, ask: Bool) -> Permission {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        guard let desc = target.aeDesc else { return .other(-1) }
        switch AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask) {
        case noErr: return .allowed
        case -1744: return .notAsked     // errAEEventWouldRequireUserConsent
        case -1743: return .denied       // errAEEventNotPermitted
        case -600: return .notRunning    // procNotFound
        case let e: return .other(e)
        }
    }

    // MARK: - Events

    struct Failure: Error, Sendable {
        var code: Int
        var message: String?
        var text: String {
            let name: String = switch code {
            case -1728: "Can't get that (errAENoSuchObject)"
            case -1708: "The app doesn't understand that (errAEEventNotHandled)"
            case -1743: "Not permitted (errAEEventNotPermitted): allow it in System Settings ▸ Privacy & Security ▸ Automation"
            case -1744: "Needs permission (errAEEventWouldRequireUserConsent)"
            case -1712: "The app didn't answer in time (errAETimeout)"
            case -600, -609: "The app isn't running (procNotFound)"
            case -1700: "Can't convert the value (errAECoercionFail)"
            case -10000: "The app's handler failed (errAEEventFailed)"
            case -1719: "Invalid index (errAEIllegalIndex)"
            default: "Error \(code)"
            }
            return message.map { "\(name): \($0)" } ?? name
        }
    }

    static func send(_ pid: pid_t, _ eventClass: String, _ eventID: String, direct: NSAppleEventDescriptor,
                     params: [(AEKeyword, NSAppleEventDescriptor)] = []) -> Result<NSAppleEventDescriptor, Failure> {
        let ev = NSAppleEventDescriptor.appleEvent(withEventClass: fcc(eventClass), eventID: fcc(eventID),
                                                   targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
                                                   returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        ev.setParam(direct, forKeyword: keyDirectObject)
        for (k, v) in params { ev.setParam(v, forKeyword: k) }
        do {
            let reply = try ev.sendEvent(options: [.waitForReply, .neverInteract], timeout: timeout)
            if let e = reply.paramDescriptor(forKeyword: keyErrorNumber), e.int32Value != 0 {
                return .failure(Failure(code: Int(e.int32Value), message: reply.paramDescriptor(forKeyword: keyErrorString)?.stringValue))
            }
            return .success(reply.paramDescriptor(forKeyword: keyDirectObject) ?? .null())
        } catch let e as NSError {
            return .failure(Failure(code: e.code, message: e.userInfo["NSAppleEventDescriptorErrorStringKey"] as? String))
        }
    }

    static func get(_ pid: pid_t, _ spec: NSAppleEventDescriptor) -> Result<NSAppleEventDescriptor, Failure> {
        send(pid, "core", "getd", direct: spec)
    }

    /// `count every <element> of <container>`. Apps take this event in different shapes: the container with
    /// the class in `kocl` (Cocoa Scripting, Finder), or an every-specifier; as a last resort, get every
    /// element and count the list.
    static func count(_ pid: pid_t, _ container: NSAppleEventDescriptor, _ element: FourCharCode) -> Result<Int, Failure> {
        let kocl = AEKeyword(fcc("kocl"))
        var r = send(pid, "core", "cnte", direct: container, params: [(kocl, NSAppleEventDescriptor(typeCode: element))])
        if case .success(let n) = r, n.descriptorType != typeNull { return .success(Int(n.int32Value)) }
        if case .failure(let f) = r, [-1743, -1744, -600, -609, -1712].contains(f.code) { return .failure(f) }
        r = send(pid, "core", "cnte", direct: every(element, of: container), params: [(kocl, NSAppleEventDescriptor(typeCode: fcc("cobj")))])
        if case .success(let n) = r, n.descriptorType != typeNull { return .success(Int(n.int32Value)) }
        r = send(pid, "core", "cnte", direct: every(element, of: container))
        if case .success(let n) = r, n.descriptorType != typeNull { return .success(Int(n.int32Value)) }
        return get(pid, every(element, of: container)).map { $0.descriptorType == typeAEList ? $0.numberOfItems : ($0.descriptorType == typeNull ? 0 : 1) }
    }

    // MARK: - Object specifiers

    /// The application itself: a specifier's outermost container.
    static let application = NSAppleEventDescriptor.null()

    static func specifier(want: FourCharCode, form: FourCharCode, data: NSAppleEventDescriptor, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let r = NSAppleEventDescriptor.record()
        r.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: AEKeyword(keyAEDesiredClass))
        r.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        r.setDescriptor(data, forKeyword: AEKeyword(keyAEKeyData))
        r.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        return r.coerce(toDescriptorType: typeObjectSpecifier) ?? r
    }
    static func property(_ code: FourCharCode, of c: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        specifier(want: fcc("prop"), form: OSType(formPropertyID), data: NSAppleEventDescriptor(typeCode: code), of: c)
    }
    static func element(_ code: FourCharCode, index: Int, of c: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        specifier(want: code, form: OSType(formAbsolutePosition), data: NSAppleEventDescriptor(int32: Int32(index)), of: c)
    }
    static func every(_ code: FourCharCode, of c: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let all = NSAppleEventDescriptor(descriptorType: typeAbsoluteOrdinal, bytes: [fcc("all ")], length: 4)!
        return specifier(want: code, form: OSType(formAbsolutePosition), data: all, of: c)
    }

    // MARK: - Reading an object

    struct Value {
        var name: String
        var code: FourCharCode
        var text: String
        /// The value is another object: it can be explored.
        var reference: NSAppleEventDescriptor?
        var failed = false
    }
    struct ElementKind {
        var name: String
        var plural: String
        var code: FourCharCode
        var count: Result<Int, Failure>
    }
    struct Contents {
        var classCode: FourCharCode?
        var className: String?
        var properties: [Value] = []
        var elements: [ElementKind] = []
        /// When `properties of` failed and the properties were read one by one.
        var propertiesNote: String?
        /// Nothing could be read: not permitted, the app quit or didn't answer.
        var failure: Failure?
    }

    /// Everything about one object: its properties (all at once, or one by one if the app doesn't do
    /// `properties`) and how many of each kind of element it has.
    static func contents(_ pid: pid_t, _ spec: NSAppleEventDescriptor, model: Model) -> Contents {
        var out = Contents()
        var known: FourCharCode? = spec.descriptorType == typeNull ? fcc("capp") : specClass(spec)
        let all = get(pid, property(fcc("pALL"), of: spec))
        switch all {
        case .success(let rec) where rec.isRecordDescriptor || rec.descriptorType == typeAERecord:
            for i in stride(from: 1, through: rec.numberOfItems, by: 1) {
                let key = rec.keywordForDescriptor(at: i)
                guard let v = rec.atIndex(i) else { continue }
                if key == fcc("pcls"), v.descriptorType == typeType, model.classInfo(v.typeCodeValue) != nil { known = v.typeCodeValue }
                out.properties.append(Value(name: model.propertyName(key), code: key, text: describe(v, model),
                                            reference: v.descriptorType == typeObjectSpecifier ? v : nil))
            }
            // In the dictionary's order, not the reply's.
            if let c = known, let info = model.classInfo(c) {
                let order = Dictionary(info.properties.enumerated().map { ($0.element.code, $0.offset) }, uniquingKeysWith: { a, _ in a })
                out.properties.sort { (order[$0.code] ?? .max, $0.name) < (order[$1.code] ?? .max, $1.name) }
            }
        case .failure(let f) where [-1743, -1744, -600, -609, -1712].contains(f.code):
            // Not allowed, gone or hung: every other event would fail the same way.
            out.failure = f
            return out
        case .success, .failure:
            if case .failure(let f) = all { out.propertiesNote = "“properties” failed (\(f.text)), so they were read one by one." }
            for p in known.flatMap({ model.classInfo($0) })?.properties.prefix(80) ?? [] {
                switch get(pid, property(p.code, of: spec)) {
                case .success(let v):
                    if p.code == fcc("pcls"), v.descriptorType == typeType, model.classInfo(v.typeCodeValue) != nil { known = v.typeCodeValue }
                    out.properties.append(Value(name: p.name, code: p.code, text: describe(v, model),
                                                reference: v.descriptorType == typeObjectSpecifier ? v : nil))
                case .failure(let f):
                    out.properties.append(Value(name: p.name, code: p.code, text: f.text, failed: true))
                }
            }
        }
        out.classCode = known
        out.className = known.map(model.className)
        for e in known.flatMap({ model.classInfo($0) })?.elements ?? [] {
            out.elements.append(ElementKind(name: e.name, plural: e.plural, code: e.code, count: count(pid, spec, e.code)))
        }
        return out
    }

    struct Child {
        var index: Int
        /// The reference the app returned (usually by id), or by index if it returned none.
        var spec: NSAppleEventDescriptor
        var name: String?
        var failure: Failure?
    }

    /// Elements `from`…`from + pageSize - 1` (1-based) of one kind, with their names when they have one.
    static func children(_ pid: pid_t, _ container: NSAppleEventDescriptor, _ code: FourCharCode, from: Int, upTo total: Int?) -> [Child] {
        var out: [Child] = []
        let last = from + pageSize - 1
        for i in from...(total.map { min($0, last) } ?? last) {
            let byIndex = element(code, index: i, of: container)
            switch get(pid, byIndex) {
            case .success(let r):
                let spec = r.descriptorType == typeObjectSpecifier ? r : byIndex
                var name: String?
                if case .success(let n) = get(pid, property(fcc("pnam"), of: spec)), n.descriptorType != typeNull { name = n.stringValue }
                out.append(Child(index: i, spec: spec, name: name))
            case .failure(let f):
                // No count: read until the index runs out.
                if total == nil { return out }
                out.append(Child(index: i, spec: byIndex, failure: f))
            }
        }
        return out
    }

    // MARK: - Describing values

    static func specClass(_ d: NSAppleEventDescriptor) -> FourCharCode? {
        guard d.descriptorType == typeObjectSpecifier, let r = d.coerce(toDescriptorType: typeAERecord),
              let want = r.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue else { return nil }
        if want == fcc("prop") { return nil }
        return want
    }

    /// A value as AppleScript would show it.
    static func describe(_ d: NSAppleEventDescriptor, _ m: Model, depth: Int = 0) -> String {
        let t = d.descriptorType
        switch t {
        case typeNull: return "missing value"
        case typeUnicodeText, typeUTF8Text, fcc("TEXT"), typeUTF16ExternalRepresentation, typeStyledText, fcc("intl"):
            return "\"" + (d.stringValue ?? "") + "\""
        case typeTrue: return "true"
        case typeFalse: return "false"
        case typeBoolean: return d.booleanValue ? "true" : "false"
        case typeSInt16, typeSInt32, typeUInt16, typeUInt32: return String(d.int32Value)
        case typeSInt64, typeUInt64:
            return d.coerce(toDescriptorType: typeIEEE64BitFloatingPoint).map { String(Int64($0.doubleValue)) } ?? "?"
        case typeIEEE32BitFloatingPoint, typeIEEE64BitFloatingPoint: return String(d.doubleValue)
        case typeLongDateTime: return d.dateValue.map { "date \"\($0.formatted(date: .abbreviated, time: .standard))\"" } ?? "date"
        case typeType: return d.typeCodeValue == fcc("msng") ? "missing value" : m.className(d.typeCodeValue)
        case typeEnumerated: return m.constantName(d.enumCodeValue)
        case typeAbsoluteOrdinal: return m.constantName(d.typeCodeValue)
        case typeObjectSpecifier: return reference(d, m)
        case typeFileURL, typeAlias, fcc("bmrk"), fcc("fsrf"), fcc("fss "):
            return d.fileURLValue.map { "file \"\($0.path)\"" } ?? "file"
        case typeAEList:
            if depth > 2 { return "{…}" }
            let n = d.numberOfItems
            let items = (0..<min(n, 20)).compactMap { d.atIndex($0 + 1) }.map { describe($0, m, depth: depth + 1) }
            return "{" + items.joined(separator: ", ") + (n > 20 ? ", … \(n - 20) more" : "") + "}"
        case fcc("QDpt"):
            // A QuickDraw point: v, h. AppleScript shows {h, v}.
            let v = d.data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            return v.count == 2 ? "{\(v[1]), \(v[0])}" : "point"
        case fcc("qdrt"):
            // Apple Event data is in the host's byte order.
            let v = d.data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            return v.count == 4 ? "{\(v[1]), \(v[0]), \(v[3]), \(v[2])}" : "rectangle"
        default:
            if d.isRecordDescriptor || t == typeAERecord {
                if depth > 2 { return "{…}" }
                let items = (0..<min(d.numberOfItems, 20)).compactMap { i -> String? in
                    guard let v = d.atIndex(i + 1) else { return nil }
                    return m.propertyName(d.keywordForDescriptor(at: i + 1)) + ":" + describe(v, m, depth: depth + 1)
                }
                return "{" + items.joined(separator: ", ") + "}"
            }
            let hex = d.data.prefix(16).map { String(format: "%02X", $0) }.joined()
            return "«data \(string(t))\(hex)\(d.data.count > 16 ? "…" : "")»"
        }
    }

    /// An object specifier as an AppleScript reference: `window id 3315 of application "Reminders"`.
    static func reference(_ d: NSAppleEventDescriptor, _ m: Model) -> String {
        guard d.descriptorType == typeObjectSpecifier, let r = d.coerce(toDescriptorType: typeAERecord) else {
            return d.descriptorType == typeNull ? "application \"\(m.appName)\"" : describe(d, m)
        }
        let want = r.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue ?? 0
        let form = r.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue ?? 0
        let seld = r.forKeyword(AEKeyword(keyAEKeyData)) ?? .null()
        let cls = m.className(want)
        let head: String
        switch form {
        case OSType(formPropertyID): head = m.propertyName(seld.typeCodeValue)
        case OSType(formAbsolutePosition):
            if seld.descriptorType == typeAbsoluteOrdinal {
                let o = seld.typeCodeValue
                head = o == fcc("all ") ? "every \(cls)" : o == fcc("firs") ? "first \(cls)" : o == fcc("last") ? "last \(cls)"
                    : o == fcc("midd") ? "middle \(cls)" : o == fcc("any ") ? "some \(cls)" : "\(cls) \(string(o))"
            } else {
                head = "\(cls) \(seld.int32Value)"
            }
        case OSType(formName): head = "\(cls) \"\(seld.stringValue ?? "")\""
        case OSType(formUniqueID): head = "\(cls) id \(describe(seld, m))"
        case OSType(formRange): head = "\(m.plural(want)) (a range)"
        case OSType(formTest), OSType(formWhose): head = "\(m.plural(want)) whose …"
        case OSType(formRelativePosition): head = "\(cls) \(seld.enumCodeValue == fcc("prev") ? "before" : "after")"
        default: head = "\(cls) («form \(string(form))» \(describe(seld, m)))"
        }
        guard let from = r.forKeyword(AEKeyword(keyAEContainer)), from.descriptorType != fcc("ccnt") else { return head }
        return head + " of " + reference(from, m)
    }
}

// MARK: - Four-character codes

/// A four-character code from its sdef spelling (Mac Roman, so codes like '»' work).
func fcc(_ s: String) -> FourCharCode {
    let bytes = Array(s.data(using: .macOSRoman) ?? Data(s.utf8))
    guard bytes.count == 4 else { return 0 }
    return bytes.reduce(0) { $0 << 8 | FourCharCode($1) }
}

private func string(_ c: FourCharCode) -> String { c.string }

extension FourCharCode {
    var string: String {
        let b = [UInt8(self >> 24 & 0xff), UInt8(self >> 16 & 0xff), UInt8(self >> 8 & 0xff), UInt8(self & 0xff)]
        return String(data: Data(b), encoding: .macOSRoman) ?? String(format: "%08X", self)
    }
}
