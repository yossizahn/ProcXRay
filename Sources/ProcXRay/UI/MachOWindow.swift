import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The binary inspector window (docs/macho-inspector-proposal.md): one per file, tabs down the side, the
// slice picker in the toolbar. Everything shown is decoded from the file's bytes by MachOParser.

struct MachORef: Codable, Hashable {
    var path: String
    /// The main executable, when opened as one of a process's libraries; resolves @executable_path.
    var executable: String?
}

enum MachOTab: String, CaseIterable, Identifiable {
    case summary = "Summary"
    case commands = "Load Commands"
    case segments = "Segments"
    case libraries = "Libraries"
    var id: String { rawValue }
    /// The sidebar's label ("Load Commands" doesn't fit beside its count).
    var title: String { self == .commands ? "Commands" : rawValue }
    var symbol: String {
        switch self {
        case .summary: "doc.text.magnifyingglass"
        case .commands: "list.bullet.rectangle"
        case .segments: "square.stack.3d.up"
        case .libraries: "books.vertical"
        }
    }
}

struct MachOWindow: View {
    static let id = "binary"
    @Binding var ref: MachORef?
    @State private var file: MachOFile?
    @State private var slice = 0
    @AppStorage("machoTab") private var tab: MachOTab = .summary
    @State private var search = ""
    /// A file opened with the app that isn't a Mach-O (this window was made for it).
    @State private var rejected: String?
    @Environment(\.openWindow) private var openWindow
    @State private var host = HostWindow.Box()
    /// The paths open in a window now.
    @MainActor static var open: Set<String> = []

    var body: some View {
        let path = ref?.path ?? ""
        NavigationSplitView {
            List(MachOTab.allCases, selection: Binding(get: { tab }, set: { if let t = $0 { tab = t } })) { t in
                HStack {
                    Label(t.title, systemImage: t.symbol)
                    Spacer()
                    if let n = count(t) { Text(verbatim: "\(n)").foregroundStyle(.secondary).monospacedDigit() }
                }
                .tag(t)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 240)
        } detail: {
            Group {
                if let file {
                    if let s = file.slices[safe: slice], let img = s.image {
                        detail(file, s, img)
                    } else if file.slices.isEmpty {
                        MachOUnreadable(file: file)
                    } else {
                        MachOUnreadable(file: file, slice: file.slices[safe: slice])
                    }
                } else if let rejected {
                    Text(verbatim: "\(rejected) isn't a Mach-O, universal or static-archive file, or a bundle with an executable.")
                        .foregroundStyle(.secondary).padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if ref == nil {
                    Text("Drop a binary here, or use File ▸ Open Binary….").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 520)
        }
        .toolbar {
            if let file, file.slices.count > 1 {
                ToolbarItem(placement: .principal) { SlicePicker(file: file, slice: $slice) }
            }
            ToolbarItem {
                Button { Reveal.reveal([path]) } label: { Label("Reveal in Finder", systemImage: Reveal.symbol) }
                    .help("Reveal in Finder")
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Filter")
        .navigationTitle(Text(verbatim: (path as NSString).lastPathComponent))
        .navigationSubtitle(Text(verbatim: (path as NSString).deletingLastPathComponent))
        .task(id: path) {
            guard !path.isEmpty else { return }
            let f = await Task.detached(priority: .userInitiated) { MachOParser.load(path: path) }.value
            file = f
            slice = f.defaultSlice
        }
        // A file opened with the app (the first, when there are several: the app delegate opens the rest).
        // While a binary window is open SwiftUI hands it the URL instead of making a window, and it opens
        // the file's own window (or brings it forward). With none open, SwiftUI makes this one for it.
        .handlesExternalEvents(preferring: ["file:"], allowing: ["file:"])
        .onOpenURL { u in
            guard u.isFileURL else { return }
            guard ref == nil else { MachOOpen.openAny(u.path, openWindow); return }
            guard let t = MachOProbe.target(u.path) else { rejected = u.path; return }
            if Self.open.contains(t) { MachOOpen.open(t, openWindow); host.window?.close() } else { ref = MachORef(path: t) }
        }
        .background(HostWindow(box: host))
        .onChange(of: ref?.path, initial: true) { old, new in
            if let old { Self.open.remove(old) }
            if let new { Self.open.insert(new) }
        }
        .onDisappear { if let p = ref?.path { Self.open.remove(p) } }
        .dropDestination(for: URL.self) { urls, _ in
            for u in urls where u.isFileURL { MachOOpen.openAny(u.path, openWindow) }
            return !urls.isEmpty
        }
        .modifier(KeepOpenWindow())
        .frame(minWidth: 760, minHeight: 480)
    }

    private func count(_ t: MachOTab) -> Int? {
        guard let img = file?.slices[safe: slice]?.image else { return nil }
        switch t {
        case .summary: return nil
        case .commands: return img.commands.count
        case .segments: return img.segments.count
        case .libraries: return img.dylibs.count
        }
    }

    @ViewBuilder private func detail(_ f: MachOFile, _ s: MachOSlice, _ img: MachOImage) -> some View {
        let q = search.trimmingCharacters(in: .whitespaces)
        switch tab {
        case .summary: MachOSummary(file: f, slice: s, image: img, select: { slice = $0 }, show: { tab = $0 })
        case .commands: MachOCommandsView(image: img, query: q)
        case .segments: MachOSegmentsView(image: img, query: q)
        case .libraries: MachOLibrariesView(path: f.path, image: img, executable: ref?.executable, query: q)
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// The NSWindow a view is in.
private struct HostWindow: NSViewRepresentable {
    final class Box { weak var window: NSWindow? }
    let box: Box
    func makeNSView(context: Context) -> NSView { Probe(box: box) }
    func updateNSView(_ v: NSView, context: Context) {}
    private final class Probe: NSView {
        let box: Box
        init(box: Box) { self.box = box; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); box.window = window }
    }
}

/// One segment per slice; a long list (an archive's members) becomes a menu.
private struct SlicePicker: View {
    let file: MachOFile
    @Binding var slice: Int
    var body: some View {
        let label = { (s: MachOSlice) in s.title + (s.runsHere ? " ✓" : "") }
        if file.slices.count <= 5 {
            Picker("Slice", selection: $slice) {
                ForEach(file.slices) { Text(verbatim: label($0)).tag($0.id) }
            }
            .pickerStyle(.segmented)
            .help("✓ is the slice this Mac would run (dyld's choice)")
        } else {
            Picker("Slice", selection: $slice) {
                ForEach(file.slices) { Text(verbatim: label($0)).tag($0.id) }
            }
            .frame(maxWidth: 320)
        }
    }
}

private struct MachOUnreadable: View {
    let file: MachOFile
    var slice: MachOSlice? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(slice == nil ? "Can't read this file as Mach-O" : "This slice isn't a Mach-O", systemImage: "exclamationmark.triangle")
                .font(.headline)
            ForEach(Array((file.issues + [slice?.note].compactMap { $0 }).enumerated()), id: \.offset) {
                Text(verbatim: $0.element).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Shared bits

private let mono = Font.system(.body, design: .monospaced)

/// Red lines for what didn't check out.
struct MachOIssues: View {
    let issues: [String]
    var body: some View {
        ForEach(Array(issues.enumerated()), id: \.offset) { _, i in
            Label { Text(verbatim: i).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                .foregroundStyle(.red).font(.callout)
        }
    }
}

private func matches(_ q: String, _ parts: [String]) -> Bool {
    q.isEmpty || parts.contains { $0.localizedCaseInsensitiveContains(q) }
}

private func hx(_ v: UInt64) -> String { "0x" + String(v, radix: 16) }

// MARK: - Summary

private struct MachOSummary: View {
    let file: MachOFile
    let slice: MachOSlice
    let image: MachOImage
    let select: (Int) -> Void
    let show: (MachOTab) -> Void

    var body: some View {
        let img = image
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                let all = file.issues + img.issues
                let nested = img.commands.reduce(0) { $0 + $1.issues.count }
                    + img.segments.reduce(0) { $0 + $1.issues.count + $1.sections.reduce(0) { $0 + $1.issues.count } }
                if !all.isEmpty || nested > 0 {
                    Card(title: "Issues", systemImage: "exclamationmark.triangle", trailing: "\(all.count + nested)") {
                        MachOIssues(issues: all)
                        if nested > 0 {
                            Text(verbatim: "\(nested) more on load commands, segments and sections; shown in red on their tabs.")
                                .foregroundStyle(.secondary).font(.callout)
                        }
                    }
                }
                Card(title: "File", systemImage: "doc") {
                    FactGrid(rows: fileRows)
                }
                if file.slices.count > 1 { slicesCard }
                Card(title: "This slice", systemImage: "cpu") { FactGrid(rows: sliceRows(img)) }
                Card(title: "At a glance", systemImage: "eye") { FactGrid(rows: glance(img)) }
                if !img.builds.isEmpty || img.sourceVersion != nil || img.targetTriple != nil || !img.linkerOptions.isEmpty {
                    Card(title: "Built for", systemImage: "hammer") { FactGrid(rows: buildRows(img)) }
                }
                Card(title: "Header flags", systemImage: "flag", trailing: hx(UInt64(img.flags))) {
                    let set = MachONames.set(img.flags, MachONames.headerFlags)
                    if set.isEmpty { Text("None.").foregroundStyle(.secondary) }
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        ForEach(Array(set.enumerated()), id: \.offset) { _, f in
                            GridRow {
                                Text(verbatim: f.0).font(mono).textSelection(.enabled)
                                Text(verbatim: f.1).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !img.filesetEntries.isEmpty {
                    Card(title: "File set entries", systemImage: "shippingbox", trailing: "\(img.filesetEntries.count)") {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                            ForEach(Array(img.filesetEntries.enumerated()), id: \.offset) { _, e in
                                GridRow {
                                    Text(verbatim: e.id).font(mono).textSelection(.enabled)
                                    Text(verbatim: "vm \(hx(e.vmaddr)) · file \(hx(e.fileoff))").font(mono).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private var fileRows: [(String, KVValue)] {
        var r: [(String, KVValue)] = [("Path", .path(file.path))]
        r.append(("Size", .text(MachONames.sizeExact(UInt64(file.size)))))
        r.append(("Kind", .text(file.container?.rawValue ?? "?")))
        if let m = file.modified { r.append(("Modified", .text(m.formatted(date: .abbreviated, time: .standard)))) }
        r.append(("Read in", .text(String(format: "%.1f ms", file.millis))))
        return r
    }

    private var slicesCard: some View {
        Card(title: "Slices", systemImage: "square.split.2x1", trailing: "\(file.slices.count)") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("Slice"); Text("Offset"); Text("Size"); Text("Align"); Text("")
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(file.slices.prefix(500)) { s in
                    GridRow {
                        Button(s.title) { select(s.id) }.buttonStyle(.link)
                            .fontWeight(s.id == slice.id ? .semibold : .regular)
                        Text(verbatim: hx(UInt64(s.offset))).font(mono)
                        Text(verbatim: MachONames.size(UInt64(s.size))).monospacedDigit()
                        Text(verbatim: s.fat.map { "2^\($0.align)" } ?? "").monospacedDigit()
                        HStack(spacing: 4) {
                            if s.runsHere { Pill(text: "runs here", color: .green).help("The slice dyld (or, for an executable, the kernel) picks on this Mac") }
                            if s.image == nil { Text(verbatim: s.note ?? "not Mach-O").foregroundStyle(.secondary).font(.callout) }
                        }
                    }
                }
            }
            if file.slices.count > 500 { Text(verbatim: "… and \(file.slices.count - 500) more (in the toolbar's menu)").foregroundStyle(.secondary).font(.caption) }
        }
    }

    private func sliceRows(_ img: MachOImage) -> [(String, KVValue)] {
        let ft = MachONames.fileType(img.filetype)
        var r: [(String, KVValue)] = [
            ("Type", .text("\(ft.1) (\(ft.0))")),
            ("Architecture", .text(img.archName)),
            ("CPU type", .text(MachONames.cpuType(img.cputype))),
            ("CPU subtype", .text(MachONames.cpuSubtype(img.cputype, img.cpusubtype))),
        ]
        if let u = img.uuid { r.append(("UUID", .text(u.uuidString))) }
        if let m = slice.member { r.append(("Archive member", .text(m))) }
        r.append(("Offset in file", .text("\(hx(UInt64(img.offset))), \(MachONames.sizeExact(UInt64(img.size)))")))
        r.append(("Header", .text("\(img.is64 ? "64-bit" : "32-bit"), \(img.swapped ? "big-endian (byte-swapped)" : "little-endian"), magic \(hx(UInt64(img.magic)))")))
        r.append(("Load commands", .text("\(img.ncmds), \(MachONames.sizeExact(UInt64(img.sizeofcmds)))")))
        if let id = img.idDylib {
            r.append(("Install name", .text(id.path)))
            r.append(("Version", .text("\(MachONames.version(id.current)) (compatibility \(MachONames.version(id.compat)))")))
        }
        return r
    }

    private func glance(_ img: MachOImage) -> [(String, KVValue)] {
        var r: [(String, KVValue)] = []
        if let e = img.entry {
            if let off = e.fileoff {
                let text = img.segments.first { $0.name == "__TEXT" }
                let addr = text.map { $0.vmaddr + off - $0.fileoff }
                r.append(("Entry point", .text("main() at file offset \(hx(off))" + (addr.map { ", address \(hx($0))" } ?? "") + " (\(e.kind))")))
                if let s = e.stack, s > 0 { r.append(("Stack size", .text(MachONames.sizeExact(s)))) }
            } else if let a = e.address {
                r.append(("Entry point", .text("\(hx(a)) (\(e.kind): initial thread state)")))
            }
        }
        let cs = img.blobs.first { $0.name == "Code signature" }
        r.append(("Code signature", .text(cs.map { "\(MachONames.size($0.size)) at \(hx($0.offset)) (decoded in a later version)" } ?? "none: not signed")))
        if let e = img.encryption { r.append(("Encryption", .text(e.id == 0 ? "not encrypted (cryptid 0)" : "encrypted: \(MachONames.size(UInt64(e.size))) at \(hx(UInt64(e.offset)))"))) }
        let objc = img.allSections.contains { $0.name == "__objc_imageinfo" || ($0.segment == "__OBJC" && $0.name == "__image_info") }
        let swift = img.allSections.contains { $0.name.hasPrefix("__swift5_") }
        r.append(("Languages", .text([objc ? "Objective-C" : nil, swift ? "Swift" : nil].compactMap { $0 }.joined(separator: ", ").ifEmpty("no Objective-C or Swift metadata"))))
        if let s = img.symtab {
            let local = img.dysymtab["nlocalsym"]
            r.append(("Symbols", .text("\(MachONames.count(s.nsyms)) in the symbol table" + (local.map { $0 == 0 ? ", no local symbols (stripped)" : ", \(MachONames.count($0)) local" } ?? ""))))
        } else {
            r.append(("Symbols", .text("no symbol table")))
        }
        let weak = img.dylibs.filter(\.isWeak).count
        r.append(("Linked libraries", .text("\(img.dylibs.count)" + (weak > 0 ? ", \(weak) weak" : ""))))
        if !img.rpaths.isEmpty { r.append(("Run paths", .text("\(img.rpaths.count)"))) }
        if !img.dyldEnvironment.isEmpty { r.append(("dyld environment", .text(img.dyldEnvironment.joined(separator: "\n")))) }
        if img.flags & 0x200000 != 0 { r.append(("Address randomization", .text("yes (MH_PIE)"))) }
        else if img.filetype == 0x2 { r.append(("Address randomization", .text("no: not position independent"))) }
        if img.flags & 0x20000 != 0 { r.append(("Stack", .text("executable (MH_ALLOW_STACK_EXECUTION)"))) }
        if img.segments.contains(where: { $0.name == "__RESTRICT" && $0.sections.contains { $0.name == "__restrict" } }) {
            r.append(("Restricted", .text("has __RESTRICT,__restrict: dyld ignores DYLD_ environment variables")))
        }
        return r
    }

    private func buildRows(_ img: MachOImage) -> [(String, KVValue)] {
        var r: [(String, KVValue)] = []
        for b in img.builds {
            let plat = b.platform.map(MachONames.platform) ?? "?"
            r.append((plat, .text("\(MachONames.version(b.minos)) or later, SDK \(b.sdk == 0 ? "not recorded" : MachONames.version(b.sdk)) (\(b.command))")))
            for t in b.tools { r.append(("Tool", .text("\(MachONames.tool(t.tool)) \(MachONames.version(t.version))"))) }
        }
        if let v = img.sourceVersion { r.append(("Source version", .text(MachONames.sourceVersion(v)))) }
        if let t = img.targetTriple { r.append(("Target triple", .text(t))) }
        for o in img.linkerOptions { r.append(("Linker option", .text(o.joined(separator: " ")))) }
        return r
    }
}

// MARK: - Load commands

private struct MachOCommandsView: View {
    let image: MachOImage
    let query: String

    var body: some View {
        let shown = image.commands.filter { c in
            matches(query, [c.name, c.summary] + c.fields.map(\.value))
        }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if shown.isEmpty { Text("No load command matches.").foregroundStyle(.secondary) }
                ForEach(shown) { c in CommandRow(command: c, base: image.offset) }
            }
            .padding(12)
        }
    }
}

private struct CommandRow: View {
    let command: MachOLoadCommand
    let base: Int
    @State private var open = false

    var body: some View {
        let c = command
        VStack(alignment: .leading, spacing: 6) {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 10)
                    Text(verbatim: "\(c.id)").monospacedDigit().foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
                    Text(verbatim: c.name).font(mono.weight(.semibold))
                    Text(verbatim: c.summary).font(mono).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if !c.issues.isEmpty { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        row("Command", "\(hx(UInt64(c.cmd)))\(c.cmd & 0x80000000 != 0 ? " (LC_REQ_DYLD: dyld refuses the file if it doesn't know it)" : "")")
                        row("At", "offset \(hx(UInt64(c.offset))) in the slice, \(c.size) bytes", help: "File offset \(hx(UInt64(base + c.offset)))")
                        ForEach(Array(c.fields.enumerated()), id: \.offset) { _, f in row(f.label, f.value, help: f.note) }
                    }
                    MachOIssues(issues: c.issues)
                }
                .padding(.leading, 50)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func row(_ l: String, _ v: String, help: String? = nil) -> some View {
        GridRow {
            Text(verbatim: l).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: v).font(mono).textSelection(.enabled)
                if v.hasPrefix("/") { RevealButton(path: v) }
                if let help { Image(systemName: "info.circle").foregroundStyle(.tertiary).help(help) }
            }
        }
    }
}

// MARK: - Segments

private struct MachOSegmentsView: View {
    let image: MachOImage
    let query: String

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(image.segments) { seg in
                    let secs = seg.sections.filter { matches(query, [$0.name, $0.segment, MachONames.sectionType($0.flags)]) }
                    if matches(query, [seg.name]) || !secs.isEmpty {
                        SegmentCard(segment: seg, sections: matches(query, [seg.name]) ? seg.sections : secs, base: image.offset)
                    }
                }
            }
            .padding(12)
        }
    }
}

private struct SegmentCard: View {
    let segment: MachOSegment
    let sections: [MachOSection]
    let base: Int

    var body: some View {
        let s = segment
        Card(title: s.name.isEmpty ? "(unnamed)" : s.name, systemImage: "square.stack.3d.up",
             trailing: "\(MachONames.prot(s.initprot)) · \(MachONames.size(s.vmsize))") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                fact("VM", "\(hx(s.vmaddr))–\(hx(s.vmaddr &+ s.vmsize)) (\(MachONames.sizeExact(s.vmsize)))")
                fact("File", "\(hx(s.fileoff))–\(hx(s.fileoff &+ s.filesize)) (\(MachONames.sizeExact(s.filesize)))",
                     help: "In the file: \(hx(UInt64(base) &+ s.fileoff))")
                fact("Protection", "initial \(MachONames.prot(s.initprot)), max \(MachONames.prot(s.maxprot))")
                if s.flags != 0 { fact("Flags", MachONames.bits(s.flags, MachONames.segmentFlags)) }
                if s.vmsize == 0, s.filesize > 0 { fact("Mapped", "no: VM size 0, the bytes are only in the file") }
            }
            MachOIssues(issues: s.issues)
            if !sections.isEmpty {
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    GridRow {
                        Text("Section"); Text("Address"); Text("Size"); Text("Offset"); Text("Align"); Text("Type")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    ForEach(sections) { x in SectionRow(section: x) }
                }
            }
        }
    }

    @ViewBuilder private func fact(_ l: String, _ v: String, help: String? = nil) -> some View {
        GridRow {
            Text(verbatim: l).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(verbatim: v).font(mono).textSelection(.enabled).help(help ?? "")
        }
    }
}

private struct SectionRow: View {
    let section: MachOSection
    var body: some View {
        let x = section
        let attrs = MachONames.sectionAttrs(x.flags)
        GridRow {
            HStack(spacing: 4) {
                Text(verbatim: x.name).font(mono)
                if !x.issues.isEmpty { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help(x.issues.joined(separator: "\n")) }
            }
            Text(verbatim: hx(x.addr)).font(mono)
            Text(verbatim: MachONames.size(x.size)).monospacedDigit().help(MachONames.sizeExact(x.size))
            Text(verbatim: x.isZerofill ? "zero-fill" : hx(UInt64(x.offset))).font(mono).foregroundStyle(x.isZerofill ? .secondary : .primary)
            Text(verbatim: "2^\(x.align)").monospacedDigit()
            Text(verbatim: MachONames.sectionType(x.flags).replacingOccurrences(of: "S_", with: ""))
                .font(mono).foregroundStyle(.secondary)
                .help((attrs.isEmpty ? "" : "Attributes: " + attrs.joined(separator: ", ") + "\n")
                      + (x.nreloc > 0 ? "\(x.nreloc) relocations at \(hx(UInt64(x.reloff)))\n" : "")
                      + "reserved1 \(x.reserved1), reserved2 \(x.reserved2)" + (x.reserved3.map { ", reserved3 \($0)" } ?? "")
                      + (x.segment.isEmpty ? "" : "\nSegment: \(x.segment)"))
        }
        .textSelection(.enabled)
    }
}

// MARK: - Libraries

private struct MachOLibrariesView: View {
    let path: String
    let image: MachOImage
    let executable: String?
    let query: String
    @State private var resolved: (ctx: MachOLibraries.Context, libs: [MachOLibraries.Resolved], rpaths: [MachOLibraries.RunPath])?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let r = resolved { content(r) } else { ProgressView() }
            }
            .padding(12)
        }
        .task(id: image.offset) {
            let img = image, p = path, e = executable
            resolved = await Task.detached(priority: .userInitiated) {
                let ctx = MachOLibraries.context(for: img, path: p, executable: e)
                return (ctx, MachOLibraries.resolve(img, ctx), MachOLibraries.runPaths(img, ctx))
            }.value
        }
    }

    @ViewBuilder private func content(_ r: (ctx: MachOLibraries.Context, libs: [MachOLibraries.Resolved], rpaths: [MachOLibraries.RunPath])) -> some View {
        let libs = r.libs.filter { matches(query, [$0.dylib.path, $0.dylib.kind.rawValue] + ($0.location.path.map { [$0] } ?? [])) }
        let cache = r.libs.filter { if case .sharedCache = $0.location { true } else { false } }.count
        let missing = r.libs.filter { $0.location == .missing }
        Card(title: "Linked libraries", systemImage: "books.vertical",
             trailing: "\(r.libs.count) · \(cache) in the shared cache" + (missing.isEmpty ? "" : " · \(missing.count) not found")) {
            if r.libs.isEmpty { Text("None.").foregroundStyle(.secondary) }
            ForEach(libs) { LibraryRow(lib: $0, executable: r.ctx.executable) }
        }
        if !r.rpaths.isEmpty {
            Card(title: "Run paths", systemImage: "point.topleft.down.to.point.bottomright.curvepath", trailing: "\(r.rpaths.count)") {
                Text("Searched in this order for @rpath/ libraries.").foregroundStyle(.secondary).font(.callout)
                ForEach(r.rpaths) { rp in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(verbatim: rp.raw).font(mono).textSelection(.enabled)
                            Text(verbatim: rp.from).font(.caption).foregroundStyle(.secondary)
                        }
                        if let e = rp.expanded {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(verbatim: "→ \(e)").font(mono).foregroundStyle(rp.exists ? Color.secondary : Color.orange).textSelection(.enabled)
                                if rp.exists { RevealButton(path: e) } else { Text("doesn't exist").font(.caption).foregroundStyle(.orange) }
                            }
                        } else {
                            Text("→ can't expand without the main executable").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        Card(title: "Loading", systemImage: "gearshape.2") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Main executable").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    if let e = r.ctx.executable {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(verbatim: e).font(mono).textSelection(.enabled)
                            if let s = r.ctx.executableSource { Text(verbatim: "(\(s))").foregroundStyle(.secondary).font(.callout) }
                            if e != path { InspectBinaryButton(path: e) }
                        }
                    } else {
                        Text("unknown: @executable_path can't be expanded").foregroundStyle(.secondary)
                    }
                }
                if let d = image.dylinker {
                    GridRow { Text("Dynamic linker").foregroundStyle(.secondary); Text(verbatim: d).font(mono).textSelection(.enabled) }
                }
                ForEach(Array(image.dyldEnvironment.enumerated()), id: \.offset) { _, v in
                    GridRow { Text("dyld environment").foregroundStyle(.secondary); Text(verbatim: v).font(mono).textSelection(.enabled) }
                }
                if let u = image.subFramework {
                    GridRow { Text("Umbrella").foregroundStyle(.secondary); Text(verbatim: u).font(mono).textSelection(.enabled) }
                }
                ForEach(Array(image.subClients.enumerated()), id: \.offset) { _, v in
                    GridRow { Text("Allowed client").foregroundStyle(.secondary); Text(verbatim: v).font(mono).textSelection(.enabled) }
                }
                ForEach(Array((image.subUmbrellas + image.subLibraries).enumerated()), id: \.offset) { _, v in
                    GridRow { Text("Sub-umbrella / library").foregroundStyle(.secondary); Text(verbatim: v).font(mono).textSelection(.enabled) }
                }
            }
            Text("Not modelled: the process's DYLD_* variables, dyld's fallback paths, and run paths inherited from intermediate libraries.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private extension MachOLibraries.Location {
    var path: String? {
        switch self {
        case .file(let p), .sharedCache(let p): p
        case .missing: nil
        }
    }
}

private struct LibraryRow: View {
    let lib: MachOLibraries.Resolved
    let executable: String?

    var body: some View {
        let d = lib.dylib
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "\(d.ordinal)").monospacedDigit().foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
                    .help("Library ordinal: imports name their library by this number")
                if d.kind != .load { Pill(text: d.kind.rawValue, color: d.isWeak ? .gray : .blue) }
                else if d.isWeak { Pill(text: "weak", color: .gray) }
                Text(verbatim: d.path).font(mono).textSelection(.enabled)
                Text(verbatim: "current \(MachONames.version(d.current)) · compatibility \(MachONames.version(d.compat))"
                     + (d.useFlags.map { " · use flags " + MachONames.bits($0, MachONames.dylibUseFlags) } ?? ""))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Spacer().frame(width: 26)
                switch lib.location {
                case .file(let p):
                    Text(verbatim: p == d.path ? "file on disk" : "→ \(p)").font(p == d.path ? .callout : mono).foregroundStyle(.secondary).textSelection(.enabled)
                    if let via = lib.viaRpath { Text(verbatim: "via \(via)").font(.caption).foregroundStyle(.tertiary) }
                    RevealButton(path: p)
                    InspectBinaryButton(path: p, executable: executable)
                case .sharedCache:
                    Text("in the dyld shared cache").font(.callout).foregroundStyle(.secondary)
                        .help("Not a file on disk: dyld maps it from the shared cache")
                case .missing:
                    Text(verbatim: d.isWeak ? "not found (weak: the program runs without it)" : "not found")
                        .font(.callout).foregroundStyle(d.isWeak ? Color.secondary : Color.red)
                        .help(lib.tried.isEmpty ? "" : "Tried:\n" + lib.tried.joined(separator: "\n"))
                }
            }
        }
        .padding(.vertical, 1)
    }
}
