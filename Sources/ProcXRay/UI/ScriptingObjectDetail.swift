import AppKit
import SwiftUI

/// The object explorer's right pane: the selected object's class and reference, its kinds of elements as
/// buttons that open them in the outline, and its properties with each value shown by kind (text, numbers,
/// true/false, dates, constants, references to follow, files, colors, lists, records).
@MainActor @Observable
final class ObjectDetailModel {
    struct Property: Identifiable {
        var id: String { name }
        var name: String
        var type: String
        var shown: ScriptingExplorer.Shown
        /// As AppleScript writes it, for copying.
        var text: String
        /// The value is an object that has its own row under this one in the outline.
        var followable: Bool
    }
    struct ElementSummary: Identifiable {
        var id: FourCharCode { code }
        var plural: String
        var code: FourCharCode
        var count: Int?
        var error: String?
    }
    struct Object {
        var reference: String
        var className: String?
        var properties: [Property]
        var elements: [ElementSummary]
        var note: String?
    }
    enum Content {
        case message(String)
        case loading(reference: String)
        case failed(reference: String, String)
        case object(Object)
        case elements(title: String, reference: String, total: Int?, read: Int, canReadMore: Bool)
    }

    var content: Content = .message("Select an object to see its properties.")
    var follow: (String) -> Void = { _ in }
    var openElements: (FourCharCode) -> Void = { _ in }
    var readMore: () -> Void = {}
}

struct ObjectDetailView: View {
    @Bindable var model: ObjectDetailModel
    @State private var filter = ""
    @State private var hideMissing = false

    var body: some View {
        switch model.content {
        case .message(let s):
            Text(s).foregroundStyle(.secondary).padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .loading(let ref):
            VStack(alignment: .leading, spacing: 12) {
                AEReferenceBox(reference: ref)
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Asking the app…").foregroundStyle(.secondary) }
            }
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .failed(let ref, let why):
            VStack(alignment: .leading, spacing: 12) {
                AEReferenceBox(reference: ref)
                Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .object(let o):
            object(o)
        case let .elements(title, ref, total, read, canReadMore):
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary)
                    Text(title).font(.title3.weight(.semibold))
                    if let total { Text("\(total)").font(.title3).foregroundStyle(.secondary).monospacedDigit() }
                }
                AEReferenceBox(reference: ref)
                Text(total.map { "\(read) of \($0) read. The app is asked \(ScriptingExplorer.pageSize) at a time." } ?? "\(read) read. The app didn't say how many there are.")
                    .foregroundStyle(.secondary)
                if canReadMore { Button("Read \(ScriptingExplorer.pageSize) More") { model.readMore() } }
            }
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder private func object(_ o: ObjectDetailModel.Object) -> some View {
        let props = o.properties.filter { p in
            (!hideMissing || !p.shown.isMissing) && (filter.isEmpty || p.name.localizedCaseInsensitiveContains(filter) || p.text.localizedCaseInsensitiveContains(filter))
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: Self.symbol(o.className ?? ""))
                        .font(.system(size: 26)).foregroundStyle(.tint).frame(width: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(o)).font(.title3.weight(.semibold)).lineLimit(2)
                        if let c = o.className { Text(c).foregroundStyle(.secondary) }
                    }
                }
                AEReferenceBox(reference: o.reference)

                if !o.elements.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Contains").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                            ForEach(o.elements) { e in AEElementChip(e: e) { model.openElements(e.code) } }
                        }
                    }
                }

                if let note = o.note {
                    Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Properties").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        Text("\(o.properties.count)").font(.subheadline).foregroundStyle(.tertiary)
                        Spacer()
                        Toggle("Hide missing values", isOn: $hideMissing).toggleStyle(.checkbox).controlSize(.small)
                        TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 140)
                    }
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 7) {
                        ForEach(props) { p in
                            GridRow {
                                Text(p.name).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                                    .help(p.type.isEmpty ? p.name : "\(p.name): \(p.type)")
                                AEValueView(shown: p.shown, follow: p.followable ? { model.follow(p.name) } : nil)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .contextMenu {
                                Button("Copy Value") { ProcessCommands.copy(p.text) }
                                Button("Copy Name") { ProcessCommands.copy(p.name) }
                                if p.followable { Button("Open in Outline") { model.follow(p.name) } }
                            }
                        }
                    }
                    if props.isEmpty {
                        Text(o.properties.isEmpty ? "No properties." : "No property matches.").foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The object's name when it has one, else its reference's first part.
    private func title(_ o: ObjectDetailModel.Object) -> String {
        if let n = o.properties.first(where: { $0.name == "name" }), case .text(let s) = n.shown, !s.isEmpty { return s }
        return o.reference.components(separatedBy: " of ").first ?? o.reference
    }

    /// A symbol for a class, by the words in its name.
    static func symbol(_ cls: String) -> String {
        let c = cls.lowercased()
        let table: [(String, String)] = [
            ("application", "app.badge"), ("window", "macwindow"), ("tab", "rectangle.topthird.inset.filled"),
            ("document", "doc.text"), ("disk", "internaldrive"), ("folder", "folder"), ("trash", "trash"),
            ("desktop", "menubar.dock.rectangle"), ("container", "folder"), ("alias", "arrowshape.turn.up.right"),
            ("file", "doc"), ("track", "music.note"), ("playlist", "music.note.list"), ("account", "person.crop.circle"),
            ("reminder", "checklist"), ("list", "list.bullet"), ("note", "note.text"), ("calendar", "calendar"),
            ("event", "calendar.badge.clock"), ("contact", "person"), ("person", "person"), ("message", "envelope"),
            ("mailbox", "tray"), ("attachment", "paperclip"), ("paragraph", "text.alignleft"), ("text", "textformat"),
            ("image", "photo"), ("photo", "photo"), ("album", "rectangle.stack"), ("options", "slider.horizontal.3"),
            ("preferences", "gearshape"), ("setting", "gearshape"),
        ]
        return table.first { c.contains($0.0) }?.1 ?? "cube"
    }
}

private struct AEReferenceBox: View {
    let reference: String
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(reference).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { ProcessCommands.copy(reference) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy the AppleScript reference")
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct AEElementChip: View {
    let e: ObjectDetailModel.ElementSummary
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: ObjectDetailView.symbol(e.plural)).foregroundStyle(.secondary).frame(width: 16)
                Text(e.plural).lineLimit(1)
                Spacer(minLength: 4)
                if let n = e.count {
                    Text("\(n)").monospacedDigit().foregroundStyle(n == 0 ? .tertiary : .secondary)
                } else {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(e.count == 0)
        .help(e.error ?? (e.count == 0 ? "None" : "Show them in the outline"))
    }
}

/// One value, shown by kind. `follow` is set for a reference the outline has a row for.
private struct AEValueView: View {
    let shown: ScriptingExplorer.Shown
    var follow: (() -> Void)? = nil

    var body: some View {
        switch shown {
        case .text(let s):
            if s.isEmpty {
                Text("empty text").italic().foregroundStyle(.tertiary)
            } else {
                Text(s).textSelection(.enabled).lineLimit(8)
            }
        case .number(let n):
            Text(n).font(.body.monospacedDigit()).foregroundStyle(.blue).textSelection(.enabled)
        case .bool(let b):
            HStack(spacing: 4) {
                Image(systemName: b ? "checkmark.circle.fill" : "circle").foregroundStyle(b ? Color.green : Color.secondary)
                Text(b ? "true" : "false").foregroundStyle(b ? .primary : .secondary)
            }
        case .date(let d):
            HStack(spacing: 6) {
                Text(d.formatted(date: .abbreviated, time: .standard)).textSelection(.enabled)
                Text(d, style: .relative).foregroundStyle(.tertiary) + Text(d < .now ? " ago" : "").foregroundStyle(.tertiary)
            }
        case .constant(let c):
            Text(c).font(.callout).padding(.horizontal, 7).padding(.vertical, 1)
                .foregroundStyle(.purple).background(.purple.opacity(0.12), in: Capsule())
        case .reference(let r, _):
            if let follow {
                Button(action: follow) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "arrow.right.circle.fill")
                        Text(r).multilineTextAlignment(.leading).lineLimit(3)
                    }
                }
                .buttonStyle(.link)
                .help("Open in the outline")
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "arrow.right.circle").foregroundStyle(.secondary)
                    Text(r).textSelection(.enabled).lineLimit(3)
                }
            }
        case .file(let p):
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "doc").foregroundStyle(.secondary)
                Text(p).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                RevealButton(path: p)
            }
        case .missing:
            Text("missing value").italic().foregroundStyle(.tertiary)
        case let .color(r, g, b, raw):
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(Color(red: r, green: g, blue: b))
                    .frame(width: 22, height: 14)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
                Text(raw).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        case let .list(items, more):
            AEListValue(items: items, more: more)
        case .record(let fields):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(fields.enumerated()), id: \.offset) { _, f in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(f.0).foregroundStyle(.secondary)
                        AEValueView(shown: f.1)
                    }
                }
            }
            .padding(6)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
        case .geometry(let g):
            Text(g).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        case .other(let s):
            Text(s).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
        case .error(let e):
            Label(e, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
        }
    }
}

/// Short lists of simple values inline, longer ones folded under a count.
private struct AEListValue: View {
    let items: [ScriptingExplorer.Shown]
    let more: Int
    @State private var open = false

    var body: some View {
        if items.isEmpty {
            Text("empty list").italic().foregroundStyle(.tertiary)
        } else if items.count <= 4, items.allSatisfy(\.isSimple) {
            HStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, v in AEValueView(shown: v) }
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Button { open.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).rotationEffect(.degrees(open ? 90 : 0))
                        Text("\(items.count + more) items")
                    }
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                if open {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, v in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(minWidth: 18, alignment: .trailing)
                            AEValueView(shown: v)
                        }
                    }
                    if more > 0 { Text("… \(more) more").foregroundStyle(.tertiary) }
                }
            }
        }
    }
}

extension ScriptingExplorer.Shown {
    var isMissing: Bool { if case .missing = self { true } else { false } }
    var isSimple: Bool {
        switch self {
        case .number, .bool, .constant, .missing, .geometry: true
        case .text(let s): s.count < 24
        default: false
        }
    }
}
