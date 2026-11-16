import AppKit
import SwiftUI

/// The column manager: pick the process table's columns, put them in order, and keep named sets of them.
/// Every change applies at once, to every window (ColumnPrefs.apply).
struct ColumnManager: View {
    static let id = "column-manager"
    /// Kept by View ▸ Columns, so the AppKit header menu can open the window.
    static var openWindow: OpenWindowAction?
    static func open() {
        openWindow?(id: id)
        NSApp.activate()
    }

    // Read so the view redraws when the table, a menu or another window changes them.
    @AppStorage(ColumnPrefs.key) private var shownRaw = ColumnPrefs.defaultShown
    @AppStorage(ColumnPrefs.orderKey) private var orderRaw = ""
    @AppStorage(ColumnPrefs.setsKey) private var setsRaw = ""

    @State private var search = ""
    @State private var availableSelection: Set<String> = []
    @State private var shownSelection: Set<String> = []
    @State private var naming = false
    @State private var newSetName = ""

    private var shown: [String] {
        _ = (shownRaw, orderRaw)
        return ColumnPrefs.shownInOrder
    }
    private var sets: [ColumnPrefs.Layout] { ColumnPrefs.decodeSets(setsRaw) }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                availableList
                VStack(spacing: 8) {
                    Spacer()
                    Button { add(availableSelection) } label: { Image(systemName: "chevron.right").frame(width: 16) }
                        .help("Show the selected columns")
                        .disabled(availableSelection.isEmpty)
                    Button { remove(shownSelection) } label: { Image(systemName: "chevron.left").frame(width: 16) }
                        .help("Hide the selected columns")
                        .disabled(shownSelection.subtracting(["name"]).isEmpty)
                    Spacer()
                }
                shownList
            }
            setsBar
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 440)
        .alert("Save Column Set", isPresented: $naming) {
            TextField("Name", text: $newSetName)
            Button("Save") {
                let name = newSetName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, name != ColumnPrefs.defaultLayout.name { ColumnPrefs.saveSet(named: name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the shown columns in their order. A set with the same name is replaced.")
        }
    }

    // MARK: Lists

    private var availableList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Available").font(.headline)
            TextField("Filter", text: $search).textFieldStyle(.roundedBorder)
            let shownSet = Set(shown)
            List(selection: $availableSelection) {
                ForEach(Column.Section.allCases, id: \.self) { section in
                    let cols = Column.all.filter { $0.section == section && !shownSet.contains($0.id) && matches($0) }
                    if !cols.isEmpty {
                        SwiftUI.Section {
                            ForEach(cols) { c in Text(c.title).help(c.tooltip).tag(c.id) }
                        } header: {
                            Text(section.title)
                        }
                    }
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Show") { add(ids) }
            } primaryAction: { add($0) }
        }
    }

    private var shownList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Shown, left to right").font(.headline)
            List(selection: $shownSelection) {
                ForEach(shown, id: \.self) { id in
                    if let c = Column.byID[id] {
                        Text(c.title).help(c.tooltip).tag(id)
                    }
                }
                .onMove { from, to in
                    var ids = shown
                    ids.move(fromOffsets: from, toOffset: to)
                    ColumnPrefs.apply(ids)
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Hide") { remove(ids) }.disabled(ids.subtracting(["name"]).isEmpty)
            } primaryAction: { remove($0) }
            HStack {
                Button { move(by: -1) } label: { Image(systemName: "arrow.up") }
                    .help("Move the selected columns left")
                Button { move(by: 1) } label: { Image(systemName: "arrow.down") }
                    .help("Move the selected columns right")
                Spacer()
                Text("Drag to reorder").font(.caption).foregroundStyle(.secondary)
            }
            .disabled(shownSelection.isEmpty)
        }
    }

    // MARK: Sets

    private var setsBar: some View {
        HStack {
            Menu("Apply Set") {
                ForEach([ColumnPrefs.defaultLayout] + sets) { s in
                    Button(s.name) { ColumnPrefs.apply(s.columns) }
                }
            }
            .fixedSize()
            Button("Save as Set…") {
                newSetName = matchingSet?.name ?? ""
                naming = true
            }
            Menu("Delete Set") {
                ForEach(sets) { s in Button(s.name) { ColumnPrefs.deleteSet(named: s.name) } }
            }
            .fixedSize()
            .disabled(sets.isEmpty)
            Spacer()
            if let m = matchingSet {
                Text("Current: \(m.name)").foregroundStyle(.secondary)
            }
        }
    }

    /// The set the shown columns are exactly, if any.
    private var matchingSet: ColumnPrefs.Layout? {
        let now = shown
        return ([ColumnPrefs.defaultLayout] + sets).first { $0.columns == now }
    }

    // MARK: Edits

    private func matches(_ c: Column) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || c.title.localizedCaseInsensitiveContains(q) || c.section.title.localizedCaseInsensitiveContains(q)
    }

    /// Adds after the last selected shown column, or at the end.
    private func add(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        var now = shown
        let new = Column.all.map(\.id).filter { ids.contains($0) && !now.contains($0) }
        let at = now.lastIndex(where: shownSelection.contains).map { $0 + 1 } ?? now.count
        now.insert(contentsOf: new, at: at)
        ColumnPrefs.apply(now)
        availableSelection = []
        shownSelection = Set(new)
    }

    private func remove(_ ids: Set<String>) {
        let drop = ids.subtracting(["name"])
        guard !drop.isEmpty else { return }
        ColumnPrefs.apply(shown.filter { !drop.contains($0) })
        shownSelection = []
    }

    /// Moves the selected columns one place left (-1) or right (+1), as a block.
    private func move(by step: Int) {
        var ids = shown
        let picked = IndexSet(ids.indices.filter { shownSelection.contains(ids[$0]) })
        guard let first = picked.first, let last = picked.last else { return }
        let to = step < 0 ? max(0, first - 1) : min(ids.count, last + 2)
        ids.move(fromOffsets: picked, toOffset: to)
        ColumnPrefs.apply(ids)
    }
}
