import SwiftUI

/// A predicate saved under a name; saved ones show as chips above the process list.
struct SavedPredicate: Codable, Hashable, Identifiable {
    var name: String
    var source: String
    /// The grouping and columns the filter switches to; nil keeps what is shown. Optional, so filters
    /// saved before these existed still decode.
    var grouping: Grouping? = nil
    var columns: [String]? = nil
    var id: String { name }

    /// The sidebar's built-in filters, which can't be deleted: Left Behind and LaunchServices Apps were
    /// sections of their own, but every row is a running process, so they are filters of this list.
    static let allProcesses = SavedPredicate(name: "All Processes", source: "", grouping: .smart)
    static let leftBehind = SavedPredicate(name: "Left Behind", source: "leftBehind", grouping: .smart)
    /// lsappinfo's coalition is the jetsam one, so that is the coalition column here.
    static let launchServicesApps = SavedPredicate(name: "LaunchServices Apps", source: "lsType", grouping: .flat,
                                                   columns: ["name", "pid", "lsType", "lsState", "jetsam", "bundleID", "arch"])
    static let builtIns = [allProcesses, leftBehind, launchServicesApps]
    static let tooltips = [
        leftBehind.name: "Processes that outlived the app that launched them; macOS keeps the app 'running in background' while these live.",
        launchServicesApps.name: "Processes LaunchServices knows as apps, with their type and state.",
    ]

    /// Puts the filter in force: its predicate, grouping and columns. A filter without columns brings back
    /// the columns that were shown before one with columns took over.
    static func apply(_ f: SavedPredicate) {
        let d = UserDefaults.standard
        d.set(f.source, forKey: "processes.predicate")
        d.set("", forKey: "processes.columnSort")
        if let g = f.grouping { d.set(g.rawValue, forKey: "grouping") }
        if let cols = f.columns {
            if d.string(forKey: userColumnsKey) == nil { d.set(ColumnPrefs.shownInOrder.joined(separator: ","), forKey: userColumnsKey) }
            ColumnPrefs.apply(cols)
        } else if let own = d.string(forKey: userColumnsKey) {
            d.removeObject(forKey: userColumnsKey)
            ColumnPrefs.apply(own.split(separator: ",").map(String.init))
        }
    }
    private static let userColumnsKey = "processes.columnsBeforeFilter"

    static let key = "processes.savedPredicates"
    /// Persisted as a JSON array; "" or anything unreadable is none.
    static func parse(_ s: String) -> [SavedPredicate] {
        (try? JSONDecoder().decode([SavedPredicate].self, from: Data(s.utf8))) ?? []
    }
    static func encode(_ list: [SavedPredicate]) -> String {
        (try? JSONEncoder().encode(list)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

/// The filter predicate row under the chips, shown while its button has it open or a predicate is on. What's
/// typed applies as soon as it parses; while it doesn't, the list keeps the last one that did and the row says
/// what's wrong.
struct PredicateBar: View {
    @Environment(Store.self) var store
    /// The predicate in force: only ever blank or one that parses.
    @Binding var applied: String
    @Binding var open: Bool
    /// SavedPredicate.encode
    @Binding var saved: String
    @State private var draft: String?
    @State private var error: PredicateError?
    @State private var showHelp = false
    @State private var showSave = false
    @State private var saveName = ""
    @FocusState private var focused: Bool

    private var text: Binding<String> {
        Binding(get: { draft ?? applied }, set: { draft = $0; check($0) })
    }

    /// The saved filter the predicate in force is, if any.
    private var savedAs: SavedPredicate? { SavedPredicate.parse(saved).first { $0.source == applied } }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary).font(.system(size: 11))
            TextField("Predicate", text: text, prompt: Text("cpu > 5 and not sandboxed"))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .focused($focused)
                .onSubmit { focused = false }
                .onExitCommand { clear() }
                .accessibilityLabel("Filter predicate")
            status
            saveButton
            Button { showHelp.toggle() } label: { Image(systemName: "questionmark.circle") }
                .buttonStyle(.borderless)
                .help("Syntax and field names")
                .popover(isPresented: $showHelp, arrowEdge: .bottom) {
                    PredicateHelp { name in
                        let cur = draft ?? applied
                        text.wrappedValue = cur.isEmpty || cur.hasSuffix(" ") || cur.hasSuffix("(") ? cur + name : cur + " " + name
                    }
                }
            Button { clear() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help(applied.isEmpty ? "Close the predicate row" : "Turn the predicate off and close the row (esc)")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .onAppear { if applied.isEmpty { focused = true } }
        // A saved filter's chip changed the predicate: show it, not what was being typed.
        .onChange(of: applied) { _, new in
            if draft.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) != new { draft = nil; error = nil }
        }
    }

    private func clear() {
        draft = nil; error = nil
        applied = ""
        open = false
    }

    @ViewBuilder private var saveButton: some View {
        let s = savedAs
        Button {
            saveName = s?.name ?? ""
            showSave = true
        } label: { Image(systemName: s == nil ? "bookmark" : "bookmark.fill") }
            .buttonStyle(.borderless)
            .disabled(applied.isEmpty || error != nil)
            .help(s.map { "Saved as “\($0.name)”" } ?? "Save this predicate as a chip")
            .popover(isPresented: $showSave, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Save as a chip").font(.headline)
                    Text(applied).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(3).frame(maxWidth: 300, alignment: .leading)
                    TextField("Name", text: $saveName, prompt: Text("Name"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                        .onSubmit(save)
                    let name = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let taken = SavedPredicate.parse(saved).contains { $0.name == name && $0.source != applied }
                    if taken { Text("Replaces the saved filter of that name.").font(.system(size: 11)).foregroundStyle(.secondary) }
                    HStack {
                        Spacer()
                        Button("Cancel") { showSave = false }.keyboardShortcut(.cancelAction)
                        Button(taken ? "Replace" : "Save", action: save).keyboardShortcut(.defaultAction).disabled(name.isEmpty)
                    }
                }
                .padding(12)
            }
    }

    /// Saves the predicate in force under the name typed. The same predicate saved before is renamed; a
    /// filter already under that name is replaced in its place.
    private func save() {
        let name = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !applied.isEmpty else { return }
        var list = SavedPredicate.parse(saved).filter { $0.source != applied || $0.name == name }
        let item = SavedPredicate(name: name, source: applied)
        if let i = list.firstIndex(where: { $0.name == name }) { list[i] = item } else { list.append(item) }
        saved = SavedPredicate.encode(list)
        showSave = false
    }

    @ViewBuilder private var status: some View {
        if let error {
            Label(error.message, systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: 320, alignment: .leading)
                .help("At character \(error.offset + 1): \(error.message)" + (applied.isEmpty ? "" : ". The list still uses the last predicate that worked: \(applied)"))
        } else if let p = store.predicate(applied) {
            let now = Date()
            let n = store.procs.values.reduce(0) { $0 + (p.test($1, now) ? 1 : 0) }
            Text(verbatim: "\(n) match").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                .help("Processes that pass the predicate, before the search")
        }
    }

    private func check(_ s: String) {
        do {
            _ = try PredicateFields.compile(s, store: store)
            error = nil
            applied = s.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let e as PredicateError {
            error = e
        } catch {}
    }
}

/// The syntax and every field, grouped as the columns are. Clicking a field adds it to the predicate.
struct PredicateHelp: View {
    let insert: (String) -> Void

    private static let examples = [
        "cpu > 5 and not apple and not sandboxed",
        "mem > 500MB or name ~ chrome",
        "team in (UBF8T346G9, EQHXZ8M8AV) and started < 5m",
        "path == \"/Applications/*\" and not hardened",
        "machDeadNames > 1000 or openFiles > 500",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Predicate").font(.headline)
                Text("""
                **and**, **or**, **not** (or &&, ||, !) and parentheses. Compare with **== != < <= > >=**, **~** (contains), \
                **!~**, **matches** (regular expression), **in (a, b, …)**; also **not in**, **not matches**. \
                A field alone is true when it has a value that isn't 0 or blank: **sandboxed**, **not hardened**.
                Text ignores case; ***** and **?** are wildcards in ==. Bare words need no quotes: **user == root**.
                Units: 500MB, 1.5GB (1024-based, as shown), 10s, 5m, 2h, 1d, 3k, 2M. **started < 5m** means started in \
                the last 5 minutes. A value that couldn't be read (—) fails every comparison, so **not sandboxed** \
                includes unknowns but **sandboxed == no** doesn't.
                Fields whose columns are hidden are read anyway while the predicate uses them.
                """)
                .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Self.examples, id: \.self) { e in
                        Text(e).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                }
                ForEach(Column.Section.allCases, id: \.self) { section in
                    let cols = Column.all.filter { $0.section == section && $0.id != "context" }
                    if !cols.isEmpty { group(section.title, cols.map { ($0.id, $0.fullTitle, $0.tooltip) }) }
                }
                group("Other", PredicateFields.extras.map { ($0.name, $0.help, $0.help) })
            }
            .padding(14)
        }
        .frame(width: 460, height: 460)
    }

    private func group(_ title: String, _ fields: [(id: String, title: String, tooltip: String)]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(fields, id: \.id) { f in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button(f.id) { insert(f.id) }
                        .buttonStyle(.link)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 130, alignment: .leading)
                    Text(f.title + unitNote(f.id)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .help(f.tooltip)
            }
        }
    }

    @MainActor private func unitNote(_ id: String) -> String {
        switch PredicateFields.unit(id) {
        case .bytes: " · size"
        case .nanos: " · time"
        case .age: " · age"
        case .plain: ""
        }
    }
}
