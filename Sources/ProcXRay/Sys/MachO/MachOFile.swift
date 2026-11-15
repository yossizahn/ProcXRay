import Foundation
import MachO

// A Mach-O file read from its bytes (docs/macho-inspector-proposal.md). Nothing here trusts the file: every
// offset and count is checked against the bytes before it's used, and what doesn't check out becomes an issue
// on the row it belongs to, so a damaged or hostile file still shows everything that can be read.

/// A file mapped read-only. Pages fault in as they're read, so a 467 MB executable costs what is looked at.
/// (A file truncated by someone else while mapped would fault on its missing pages; executables in use are
/// replaced, not truncated, so this is accepted.)
final class MappedFile: @unchecked Sendable {
    let path: String
    let size: Int
    let base: UnsafeRawPointer?
    let modified: Date?

    init(path: String) throws {
        self.path = path
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw MachOError.posix(errno, "open") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw MachOError.posix(errno, "fstat") }
        guard st.st_mode & S_IFMT == S_IFREG else { throw MachOError.notRegular }
        size = Int(st.st_size)
        modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        if size == 0 { base = nil; return }
        let p = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0)
        guard let p, p != MAP_FAILED else { throw MachOError.posix(errno, "mmap") }
        base = UnsafeRawPointer(p)
    }

    deinit { if let base { munmap(UnsafeMutableRawPointer(mutating: base), size) } }
}

enum MachOError: Error, CustomStringConvertible {
    case posix(Int32, String), notRegular
    var description: String {
        switch self {
        case .posix(let e, let call): return "\(call): \(String(cString: strerror(e)))"
        case .notRegular: return "Not a regular file"
        }
    }
}

/// A bounds-checked window onto the file: offsets are relative to `start`, reads past `count` return nil.
struct Bytes {
    let file: MappedFile
    let start: Int
    let count: Int
    var swapped = false

    init(file: MappedFile) { self.file = file; start = 0; count = file.size }
    private init(file: MappedFile, start: Int, count: Int, swapped: Bool) {
        self.file = file; self.start = start; self.count = count; self.swapped = swapped
    }

    func has(_ off: Int, _ n: Int) -> Bool { off >= 0 && n >= 0 && off <= count && n <= count - off }

    func sub(_ off: Int, _ n: Int) -> Bytes? {
        has(off, n) ? Bytes(file: file, start: start + off, count: n, swapped: swapped) : nil
    }
    func with(swapped s: Bool) -> Bytes { Bytes(file: file, start: start, count: count, swapped: s) }

    private func load<T: FixedWidthInteger>(_ off: Int, _: T.Type) -> T? {
        guard has(off, MemoryLayout<T>.size), let b = file.base else { return nil }
        let v = b.loadUnaligned(fromByteOffset: start + off, as: T.self)
        return swapped ? v.byteSwapped : v
    }
    func u8(_ off: Int) -> UInt8? { guard has(off, 1), let b = file.base else { return nil }; return b.load(fromByteOffset: start + off, as: UInt8.self) }
    func u16(_ off: Int) -> UInt16? { load(off, UInt16.self) }
    func u32(_ off: Int) -> UInt32? { load(off, UInt32.self) }
    func u64(_ off: Int) -> UInt64? { load(off, UInt64.self) }
    func i32(_ off: Int) -> Int32? { u32(off).map { Int32(bitPattern: $0) } }
    /// Big-endian regardless of `swapped` (fat headers, archive sizes are text).
    func be32(_ off: Int) -> UInt32? { guard has(off, 4), let b = file.base else { return nil }; return UInt32(bigEndian: b.loadUnaligned(fromByteOffset: start + off, as: UInt32.self)) }
    func be64(_ off: Int) -> UInt64? { guard has(off, 8), let b = file.base else { return nil }; return UInt64(bigEndian: b.loadUnaligned(fromByteOffset: start + off, as: UInt64.self)) }

    func bytes(_ off: Int, _ n: Int) -> [UInt8]? {
        guard has(off, n), let b = file.base else { return nil }
        return Array(UnsafeRawBufferPointer(start: b + start + off, count: n))
    }

    /// A NUL-terminated string starting at `off`, read no further than `limit` bytes (or the window's end).
    /// `terminated` is false when no NUL was found in that range.
    func cString(_ off: Int, limit: Int) -> (text: String, terminated: Bool)? {
        guard has(off, 0), let b = file.base else { return nil }
        let n = min(limit, count - off)
        let p = (b + start + off).assumingMemoryBound(to: UInt8.self)
        var len = 0
        while len < n, p[len] != 0 { len += 1 }
        let text = String(decoding: UnsafeBufferPointer(start: p, count: len), as: UTF8.self)
        return (text, len < n)
    }
    /// A fixed-size char array (segment and section names: 16 bytes, NUL-padded or not).
    func fixed(_ off: Int, _ n: Int) -> String? { cString(off, limit: n)?.text }
}

// MARK: - Model

struct MachOField: Hashable {
    let label: String
    let value: String
    var note: String? = nil
    var isIssue = false
}

struct MachOSection: Identifiable, Hashable {
    let id: Int
    let name: String
    let segment: String
    let addr: UInt64
    let size: UInt64
    let offset: UInt32
    let align: UInt32
    let reloff: UInt32
    let nreloc: UInt32
    let flags: UInt32
    let reserved1: UInt32
    let reserved2: UInt32
    let reserved3: UInt32?
    var issues: [String] = []
    var type: UInt32 { flags & 0xff }
    var isZerofill: Bool { [S_ZEROFILL, S_GB_ZEROFILL, S_THREAD_LOCAL_ZEROFILL].contains(Int32(type)) }
}

struct MachOSegment: Identifiable, Hashable {
    let id: Int
    let command: Int
    let name: String
    let vmaddr: UInt64
    let vmsize: UInt64
    let fileoff: UInt64
    let filesize: UInt64
    let maxprot: Int32
    let initprot: Int32
    let flags: UInt32
    var sections: [MachOSection]
    var issues: [String] = []
}

struct MachODylib: Identifiable, Hashable {
    enum Kind: String { case load = "load", weak = "weak", reexport = "re-export", upward = "upward", lazy = "lazy" }
    let id: Int
    let command: Int
    let kind: Kind
    let path: String
    let timestamp: UInt32
    let current: UInt32
    let compat: UInt32
    /// dylib_use_command flags, when the command uses that form.
    let useFlags: UInt32?
    /// The two-level-namespace library ordinal symbols bind against (1-based, in load-command order).
    let ordinal: Int
    var isWeak: Bool { kind == .weak || (useFlags ?? 0) & 0x01 != 0 }
}

struct MachOBuild: Hashable {
    let command: String
    let platform: UInt32?
    let minos: UInt32
    let sdk: UInt32
    let tools: [(tool: UInt32, version: UInt32)]
    static func == (a: Self, b: Self) -> Bool { a.command == b.command && a.platform == b.platform && a.minos == b.minos && a.sdk == b.sdk && a.tools.map(\.tool) == b.tools.map(\.tool) && a.tools.map(\.version) == b.tools.map(\.version) }
    func hash(into h: inout Hasher) { h.combine(command); h.combine(platform); h.combine(minos); h.combine(sdk) }
}

struct MachOBlob: Hashable {
    let name: String
    let command: Int
    let offset: UInt64
    let size: UInt64
}

struct MachOLoadCommand: Identifiable, Hashable {
    let id: Int
    let offset: Int
    let cmd: UInt32
    let size: UInt32
    let name: String
    var summary: String = ""
    var fields: [MachOField] = []
    var issues: [String] = []
    /// The command's bytes (for the commands no decoder knows, and for "Show bytes").
    var raw: [UInt8] = []
}

struct MachOImage {
    let offset: Int           // the slice's offset in the file
    let size: Int
    let magic: UInt32
    let is64: Bool
    let swapped: Bool
    let cputype: Int32
    let cpusubtype: Int32
    let filetype: UInt32
    let ncmds: UInt32
    let sizeofcmds: UInt32
    let flags: UInt32
    var commands: [MachOLoadCommand] = []
    var segments: [MachOSegment] = []
    var dylibs: [MachODylib] = []
    var idDylib: MachODylib?
    var rpaths: [(command: Int, path: String)] = []
    var dylinker: String?
    var dyldEnvironment: [String] = []
    var uuid: UUID?
    var builds: [MachOBuild] = []
    var sourceVersion: UInt64?
    var targetTriple: String?
    var entry: (kind: String, fileoff: UInt64?, address: UInt64?, stack: UInt64?)?
    var encryption: (offset: UInt32, size: UInt32, id: UInt32)?
    var blobs: [MachOBlob] = []
    var symtab: (symoff: UInt32, nsyms: UInt32, stroff: UInt32, strsize: UInt32)?
    var dysymtab: [String: UInt32] = [:]
    var subFramework: String?
    var subUmbrellas: [String] = []
    var subClients: [String] = []
    var subLibraries: [String] = []
    var linkerOptions: [[String]] = []
    var filesetEntries: [(id: String, vmaddr: UInt64, fileoff: UInt64)] = []
    var issues: [String] = []

    var archName: String { MachONames.arch(cputype, cpusubtype) }
    func section(_ seg: String, _ sect: String) -> MachOSection? {
        segments.first { $0.name == seg }?.sections.first { $0.name == sect }
    }
    var allSections: [MachOSection] { segments.flatMap(\.sections) }
}

struct MachOSlice: Identifiable {
    let id: Int
    let title: String
    let offset: Int
    let size: Int
    /// From the fat header: cputype, cpusubtype, align. Nil for a thin file or an archive member.
    let fat: (cputype: Int32, cpusubtype: Int32, align: UInt32)?
    let member: String?
    let image: MachOImage?
    /// Why there's no image (not a Mach-O, a member that isn't one, a damaged header).
    let note: String?
    var runsHere = false
}

struct MachOFile {
    enum Container: String { case thin = "Mach-O", fat = "Universal (fat)", fat64 = "Universal (fat64)", archive = "Static archive", fatArchive = "Universal static archive" }
    let path: String
    let size: Int
    let modified: Date?
    let container: Container?
    var slices: [MachOSlice]
    var issues: [String]
    let millis: Double
    let mapped: MappedFile?

    var defaultSlice: Int { slices.firstIndex(where: \.runsHere) ?? slices.firstIndex { $0.image != nil } ?? 0 }
}

// MARK: - Parsing

enum MachOParser {
    static let arMagic: [UInt8] = Array("!<arch>\n".utf8)

    /// The first bytes say whether this is something the inspector reads: a Mach-O (either width and byte
    /// order), a fat header (Java class files share 0xcafebabe; they have a version ≥ 45 where fat has a small
    /// slice count), or a static archive.
    static func looksLikeMachO(_ head: [UInt8]) -> Bool {
        guard head.count >= 8 else { return false }
        let be = UInt32(head[0]) << 24 | UInt32(head[1]) << 16 | UInt32(head[2]) << 8 | UInt32(head[3])
        switch be {
        case 0xfeedface, 0xfeedfacf, 0xcefaedfe, 0xcffaedfe: return true
        case 0xcafebabe, 0xcafebabf:
            let n = UInt32(head[4]) << 24 | UInt32(head[5]) << 16 | UInt32(head[6]) << 8 | UInt32(head[7])
            return n >= 1 && n <= 32
        default: return Array(head.prefix(8)) == arMagic
        }
    }

    static func load(path: String) -> MachOFile {
        let t0 = DispatchTime.now().uptimeNanoseconds
        func ms() -> Double { Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 }
        let mf: MappedFile
        do { mf = try MappedFile(path: path) } catch {
            return MachOFile(path: path, size: 0, modified: nil, container: nil, slices: [], issues: ["\(error)"], millis: ms(), mapped: nil)
        }
        let all = Bytes(file: mf)
        var issues: [String] = []
        var slices: [MachOSlice] = []
        var container: MachOFile.Container?
        let magic = all.be32(0) ?? 0

        if magic == 0xcafebabe || magic == 0xcafebabf {
            let is64 = magic == 0xcafebabf
            container = is64 ? .fat64 : .fat
            let n = Int(all.be32(4) ?? 0)
            let entry = is64 ? 32 : 20
            if n == 0 || n > 64 { issues.append("Fat header claims \(n) slices") }
            for i in 0..<min(n, 64) {
                let o = 8 + i * entry
                guard all.has(o, entry) else { issues.append("Fat header entry \(i) runs past the end of the file"); break }
                let ct = Int32(bitPattern: all.be32(o)!), cs = Int32(bitPattern: all.be32(o + 4)!)
                let off = is64 ? all.be64(o + 8)! : UInt64(all.be32(o + 8)!)
                let sz = is64 ? all.be64(o + 16)! : UInt64(all.be32(o + 12)!)
                let align = all.be32(is64 ? o + 24 : o + 16)!
                let title = MachONames.arch(ct, cs)
                guard off <= UInt64(mf.size), sz <= UInt64(mf.size) - off, let b = all.sub(Int(off), Int(sz)) else {
                    slices.append(MachOSlice(id: slices.count, title: title, offset: Int(clamping: off), size: Int(clamping: sz), fat: (ct, cs, align), member: nil, image: nil,
                                             note: "Slice at 0x\(mhex(off)), size \(sz), runs past the end of the file (\(mf.size) bytes)"))
                    continue
                }
                if align < 32, off % (UInt64(1) << align) != 0 { issues.append("\(title) slice at 0x\(mhex(off)) isn't aligned to 2^\(align)") }
                if b.bytes(0, 8) == arMagic {
                    container = .fatArchive
                    for m in archiveMembers(b, base: Int(off), issues: &issues) {
                        slices.append(slice(id: slices.count, title: "\(title) · \(m.name)", bytes: m.bytes, fat: (ct, cs, align), member: m.name))
                    }
                } else {
                    slices.append(slice(id: slices.count, title: title, bytes: b, fat: (ct, cs, align), member: nil))
                    if let img = slices.last?.image, img.cputype != ct || img.cpusubtype != cs {
                        issues.append("Fat header says \(title), the slice's own header says \(img.archName)")
                    }
                }
            }
            // Overlapping slices.
            let ranges = slices.filter { $0.member == nil }.map { ($0.offset, $0.offset + $0.size, $0.title) }.sorted { $0.0 < $1.0 }
            for (a, b) in zip(ranges, ranges.dropFirst()) where b.0 < a.1 { issues.append("Slices \(a.2) and \(b.2) overlap") }
        } else if all.bytes(0, 8) == arMagic {
            container = .archive
            for m in archiveMembers(all, base: 0, issues: &issues) {
                slices.append(slice(id: slices.count, title: m.name, bytes: m.bytes, fat: nil, member: m.name))
            }
        } else {
            let s = slice(id: 0, title: "", bytes: all, fat: nil, member: nil)
            if s.image != nil {
                container = .thin
                slices = [MachOSlice(id: 0, title: s.image!.archName, offset: 0, size: mf.size, fat: nil, member: nil, image: s.image, note: nil)]
            } else {
                issues.append(s.note ?? "Not a Mach-O file")
            }
        }

        // The slice the kernel (executables) or dyld (libraries) would pick on this Mac: dyld's own answer.
        if slices.count > 1 || container == .fat || container == .fat64 {
            var best: UInt64?
            _ = DyldMachO.bestSlice(path) { off in best = off }
            if let best { for i in slices.indices where slices[i].member == nil && UInt64(slices[i].offset) == best { slices[i].runsHere = true } }
        } else if slices.count == 1 {
            var best = false
            _ = DyldMachO.bestSlice(path) { _ in best = true }
            slices[0].runsHere = best
        }
        return MachOFile(path: path, size: mf.size, modified: mf.modified, container: container, slices: slices, issues: issues, millis: ms(), mapped: mf)
    }

    private static func slice(id: Int, title: String, bytes: Bytes, fat: (Int32, Int32, UInt32)?, member: String?) -> MachOSlice {
        let (img, note) = image(bytes)
        return MachOSlice(id: id, title: title.isEmpty ? (img?.archName ?? "?") : title, offset: bytes.start, size: bytes.count,
                          fat: fat, member: member, image: img, note: note)
    }

    // MARK: Archives

    struct Member { let name: String; let bytes: Bytes }

    /// ar(5) members: 60-byte headers, BSD `#1/<len>` long names, the symbol table (`__.SYMDEF…`) skipped.
    static func archiveMembers(_ b: Bytes, base: Int, issues: inout [String]) -> [Member] {
        var out: [Member] = []
        var o = 8
        while o + 60 <= b.count {
            guard let hdr = b.bytes(o, 60) else { break }
            guard hdr[58] == 0x60, hdr[59] == 0x0a else { issues.append("Archive member header at 0x\(mhex(UInt64(base + o))) is damaged"); break }
            let field = { (a: Int, n: Int) in String(decoding: hdr[a..<(a + n)], as: UTF8.self).trimmingCharacters(in: .whitespaces) }
            var name = field(0, 16)
            guard let size = Int(field(48, 10)), size >= 0, b.has(o + 60, size) else {
                issues.append("Archive member \(name) at 0x\(mhex(UInt64(base + o))) has a bad size"); break
            }
            var dataOff = o + 60, dataSize = size
            if name.hasPrefix("#1/"), let n = Int(name.dropFirst(3)), n <= size {
                name = b.cString(dataOff, limit: n)?.text ?? name
                dataOff += n; dataSize -= n
            } else if name.hasSuffix("/") { name.removeLast() }
            if !name.hasPrefix("__.SYMDEF"), let m = b.sub(dataOff, dataSize) { out.append(Member(name: name, bytes: m)) }
            o += 60 + size + (size & 1)
            if out.count > 100_000 { issues.append("More than 100,000 archive members; stopped"); break }
        }
        return out
    }

    // MARK: Image

    static func image(_ b0: Bytes) -> (MachOImage?, String?) {
        guard let raw = b0.u32(0) else { return (nil, "Too short for a Mach-O header") }
        let is64: Bool, swapped: Bool
        switch raw {
        case MH_MAGIC: (is64, swapped) = (false, false)
        case MH_CIGAM: (is64, swapped) = (false, true)
        case MH_MAGIC_64: (is64, swapped) = (true, false)
        case MH_CIGAM_64: (is64, swapped) = (true, true)
        default: return (nil, "Not a Mach-O (magic 0x\(String(raw.bigEndian, radix: 16)))")
        }
        let b = b0.with(swapped: swapped)
        let hsize = is64 ? 32 : 28
        guard b.has(0, hsize) else { return (nil, "Header runs past the end (\(b.count) bytes)") }
        var img = MachOImage(offset: b.start, size: b.count, magic: b.u32(0)!, is64: is64, swapped: swapped,
                             cputype: b.i32(4)!, cpusubtype: b.i32(8)!, filetype: b.u32(12)!,
                             ncmds: b.u32(16)!, sizeofcmds: b.u32(20)!, flags: b.u32(24)!)
        let cmdsEnd = hsize + Int(img.sizeofcmds)
        if !b.has(hsize, Int(img.sizeofcmds)) { img.issues.append("Load commands (\(img.sizeofcmds) bytes) run past the end of the slice") }
        var o = hsize
        var ordinal = 0
        let align = is64 ? 8 : 4
        for i in 0..<Int(img.ncmds) {
            guard let cmd = b.u32(o), let size = b.u32(o + 4) else {
                img.issues.append("Load command \(i) at 0x\(mhex(UInt64(o))) is past the end of the slice; stopped at \(i) of \(img.ncmds)"); break
            }
            var lc = MachOLoadCommand(id: i, offset: o, cmd: cmd, size: size, name: MachONames.loadCommand(cmd))
            if size < 8 {
                lc.issues.append("cmdsize \(size) is smaller than a load command header; stopped")
                img.commands.append(lc); img.issues.append("Load command \(i) has cmdsize \(size); the rest can't be found"); break
            }
            if Int(size) % align != 0 { lc.issues.append("cmdsize \(size) isn't a multiple of \(align)") }
            if o + Int(size) > cmdsEnd { lc.issues.append("Runs \(o + Int(size) - cmdsEnd) bytes past sizeofcmds") }
            if let c = b.sub(o, Int(size)) ?? b.sub(o, b.count - o) {
                lc.raw = c.bytes(0, min(c.count, 4096)) ?? []
                decode(&lc, c, &img, ordinal: &ordinal)
            } else {
                lc.issues.append("Past the end of the slice")
            }
            img.commands.append(lc)
            o += Int(size)
        }
        if o != cmdsEnd, img.commands.count == Int(img.ncmds) {
            img.issues.append("Load commands add up to \(o - hsize) bytes, the header says \(img.sizeofcmds)")
        }
        validate(&img, b)
        return (img, nil)
    }

    // MARK: Load commands

    private static func lcStr(_ c: Bytes, at fieldOff: Int, _ lc: inout MachOLoadCommand, _ what: String = "name") -> String? {
        guard let off = c.u32(fieldOff) else { lc.issues.append("Too short for its \(what)"); return nil }
        guard Int(off) < c.count else { lc.issues.append("\(what) offset \(off) is outside the command (\(c.count) bytes)"); return nil }
        guard let s = c.cString(Int(off), limit: c.count - Int(off)) else { return nil }
        if !s.terminated { lc.issues.append("\(what) isn't NUL-terminated inside the command") }
        return s.text
    }

    private static func need(_ c: Bytes, _ n: Int, _ lc: inout MachOLoadCommand) -> Bool {
        if c.count < n { lc.issues.append("\(c.count) bytes; this command needs at least \(n)"); return false }
        return true
    }

    private static func decode(_ lc: inout MachOLoadCommand, _ c: Bytes, _ img: inout MachOImage, ordinal: inout Int) {
        let F = MachONames.self
        func add(_ l: String, _ v: String, _ note: String? = nil) { lc.fields.append(MachOField(label: l, value: v, note: note)) }
        let cmd = lc.cmd
        switch cmd {
        case UInt32(LC_SEGMENT), UInt32(LC_SEGMENT_64):
            let w = cmd == UInt32(LC_SEGMENT_64)
            let hs = w ? 72 : 56, ss = w ? 80 : 68
            guard need(c, hs, &lc) else { return }
            let name = c.fixed(8, 16) ?? ""
            let vmaddr = w ? c.u64(24)! : UInt64(c.u32(24)!), vmsize = w ? c.u64(32)! : UInt64(c.u32(28)!)
            let fileoff = w ? c.u64(40)! : UInt64(c.u32(32)!), filesize = w ? c.u64(48)! : UInt64(c.u32(36)!)
            let p = w ? 56 : 40
            let maxprot = c.i32(p)!, initprot = c.i32(p + 4)!, nsects = c.u32(p + 8)!, flags = c.u32(p + 12)!
            var seg = MachOSegment(id: img.segments.count, command: lc.id, name: name, vmaddr: vmaddr, vmsize: vmsize, fileoff: fileoff,
                                   filesize: filesize, maxprot: maxprot, initprot: initprot, flags: flags, sections: [])
            lc.summary = "\(name)  \(F.prot(initprot))  \(F.size(vmsize))"
            add("Name", name)
            add("VM address", "0x" + mhex(vmaddr)); add("VM size", F.sizeExact(vmsize))
            add("File offset", "0x" + mhex(fileoff)); add("File size", F.sizeExact(filesize))
            add("Max protection", F.prot(maxprot)); add("Initial protection", F.prot(initprot))
            add("Sections", "\(nsects)")
            add("Flags", F.bits(flags, F.segmentFlags))
            if hs + Int(nsects) * ss > c.count { lc.issues.append("\(nsects) sections need \(hs + Int(nsects) * ss) bytes; the command has \(c.count)") }
            for i in 0..<Int(min(nsects, UInt32((c.count - hs) / ss))) {
                let s = hs + i * ss
                let sec = MachOSection(
                    id: img.allSections.count + i, name: c.fixed(s, 16) ?? "", segment: c.fixed(s + 16, 16) ?? "",
                    addr: w ? c.u64(s + 32)! : UInt64(c.u32(s + 32)!), size: w ? c.u64(s + 40)! : UInt64(c.u32(s + 36)!),
                    offset: c.u32(s + (w ? 48 : 40))!, align: c.u32(s + (w ? 52 : 44))!, reloff: c.u32(s + (w ? 56 : 48))!,
                    nreloc: c.u32(s + (w ? 60 : 52))!, flags: c.u32(s + (w ? 64 : 56))!, reserved1: c.u32(s + (w ? 68 : 60))!,
                    reserved2: c.u32(s + (w ? 72 : 64))!, reserved3: w ? c.u32(s + 76)! : nil)
                seg.sections.append(sec)
            }
            img.segments.append(seg)

        case UInt32(LC_SYMTAB):
            guard need(c, 24, &lc) else { return }
            let t = (c.u32(8)!, c.u32(12)!, c.u32(16)!, c.u32(20)!)
            img.symtab = t
            lc.summary = "\(F.count(t.1)) symbols, \(F.size(UInt64(t.3))) of strings"
            add("Symbol table offset", "0x" + mhex(UInt64(t.0))); add("Symbols", F.count(t.1))
            add("String table offset", "0x" + mhex(UInt64(t.2))); add("String table size", F.sizeExact(UInt64(t.3)))
            img.blobs.append(MachOBlob(name: "Symbol table", command: lc.id, offset: UInt64(t.0), size: UInt64(t.1) * (img.is64 ? 16 : 12)))
            img.blobs.append(MachOBlob(name: "String table", command: lc.id, offset: UInt64(t.2), size: UInt64(t.3)))

        case UInt32(LC_DYSYMTAB):
            guard need(c, 80, &lc) else { return }
            let names = ["ilocalsym", "nlocalsym", "iextdefsym", "nextdefsym", "iundefsym", "nundefsym", "tocoff", "ntoc", "modtaboff", "nmodtab",
                         "extrefsymoff", "nextrefsyms", "indirectsymoff", "nindirectsyms", "extreloff", "nextrel", "locreloff", "nlocrel"]
            let labels = ["First local symbol", "Local symbols", "First defined external", "Defined externals", "First undefined", "Undefined symbols",
                          "Table of contents offset", "Table of contents entries", "Module table offset", "Modules",
                          "External references offset", "External references", "Indirect symbols offset", "Indirect symbols",
                          "External relocations offset", "External relocations", "Local relocations offset", "Local relocations"]
            for (i, n) in names.enumerated() {
                let v = c.u32(8 + i * 4)!
                img.dysymtab[n] = v
                add(labels[i], n.hasSuffix("off") ? "0x" + mhex(UInt64(v)) : F.count(v))
            }
            lc.summary = "\(F.count(img.dysymtab["nlocalsym"]!)) local, \(F.count(img.dysymtab["nextdefsym"]!)) exported, \(F.count(img.dysymtab["nundefsym"]!)) undefined"
            if let n = img.dysymtab["nindirectsyms"], n > 0 { img.blobs.append(MachOBlob(name: "Indirect symbols", command: lc.id, offset: UInt64(img.dysymtab["indirectsymoff"]!), size: UInt64(n) * 4)) }
            if let n = img.dysymtab["nextrel"], n > 0 { img.blobs.append(MachOBlob(name: "External relocations", command: lc.id, offset: UInt64(img.dysymtab["extreloff"]!), size: UInt64(n) * 8)) }
            if let n = img.dysymtab["nlocrel"], n > 0 { img.blobs.append(MachOBlob(name: "Local relocations", command: lc.id, offset: UInt64(img.dysymtab["locreloff"]!), size: UInt64(n) * 8)) }

        case UInt32(LC_LOAD_DYLIB), UInt32(LC_ID_DYLIB), LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, UInt32(LC_LAZY_LOAD_DYLIB), LC_LOAD_UPWARD_DYLIB:
            guard need(c, 24, &lc) else { return }
            let nameoff = c.u32(8)!, ts = c.u32(12)!, cur = c.u32(16)!, compat = c.u32(20)!
            let isUse = ts == 0x1a741800 && nameoff == 28 && c.count >= 28
            let useFlags: UInt32? = isUse ? c.u32(24) : nil
            let path = lcStr(c, at: 8, &lc) ?? ""
            let kind: MachODylib.Kind
            switch cmd {
            case LC_LOAD_WEAK_DYLIB: kind = .weak
            case LC_REEXPORT_DYLIB: kind = .reexport
            case LC_LOAD_UPWARD_DYLIB: kind = .upward
            case UInt32(LC_LAZY_LOAD_DYLIB): kind = .lazy
            default: kind = .load
            }
            let isID = cmd == UInt32(LC_ID_DYLIB)
            if !isID { ordinal += 1 }
            let d = MachODylib(id: isID ? -1 : img.dylibs.count, command: lc.id, kind: kind, path: path, timestamp: isUse ? 0 : ts,
                               current: cur, compat: compat, useFlags: useFlags, ordinal: isID ? 0 : ordinal)
            if isID { img.idDylib = d } else { img.dylibs.append(d) }
            lc.summary = path
            add(isID ? "Install name" : "Path", path)
            add("Current version", F.version(cur)); add("Compatibility version", F.version(compat))
            if let useFlags {
                add("Form", "dylib_use_command (marker 0x1a741800)")
                add("Use flags", F.bits(useFlags, F.dylibUseFlags))
            } else {
                add("Timestamp", ts <= 2 ? "\(ts)" : "\(ts) (\(F.date(TimeInterval(ts))))")
            }
            if !isID { add("Library ordinal", "\(ordinal)", "Symbols bound from this library name it by this number") }

        case UInt32(LC_LOAD_DYLINKER), UInt32(LC_ID_DYLINKER), UInt32(LC_DYLD_ENVIRONMENT):
            let s = lcStr(c, at: 8, &lc) ?? ""
            lc.summary = s
            if cmd == UInt32(LC_DYLD_ENVIRONMENT) { img.dyldEnvironment.append(s); add("Variable", s) }
            else { if cmd == UInt32(LC_LOAD_DYLINKER) { img.dylinker = s }; add("Path", s) }

        case LC_RPATH:
            let s = lcStr(c, at: 8, &lc, "path") ?? ""
            img.rpaths.append((lc.id, s))
            lc.summary = s
            add("Path", s)

        case UInt32(LC_UUID):
            guard need(c, 24, &lc), let u = c.bytes(8, 16) else { return }
            let uuid = UUID(uuid: (u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7], u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15]))
            img.uuid = uuid
            lc.summary = uuid.uuidString
            add("UUID", uuid.uuidString)

        case UInt32(LC_BUILD_VERSION):
            guard need(c, 24, &lc) else { return }
            let plat = c.u32(8)!, minos = c.u32(12)!, sdk = c.u32(16)!, n = c.u32(20)!
            var tools: [(UInt32, UInt32)] = []
            if 24 + Int(n) * 8 > c.count { lc.issues.append("\(n) tools need \(24 + Int(n) * 8) bytes; the command has \(c.count)") }
            for i in 0..<Int(min(n, UInt32((c.count - 24) / 8))) { tools.append((c.u32(24 + i * 8)!, c.u32(28 + i * 8)!)) }
            img.builds.append(MachOBuild(command: lc.name, platform: plat, minos: minos, sdk: sdk, tools: tools.map { (tool: $0.0, version: $0.1) }))
            lc.summary = "\(F.platform(plat)) \(F.version(minos)), SDK \(F.version(sdk))"
            add("Platform", F.platform(plat)); add("Minimum OS", F.version(minos)); add("SDK", F.version(sdk))
            for t in tools { add("Tool", "\(F.tool(t.0)) \(F.version(t.1))") }

        case UInt32(LC_VERSION_MIN_MACOSX), UInt32(LC_VERSION_MIN_IPHONEOS), UInt32(LC_VERSION_MIN_TVOS), UInt32(LC_VERSION_MIN_WATCHOS):
            guard need(c, 16, &lc) else { return }
            let v = c.u32(8)!, sdk = c.u32(12)!
            let plat: UInt32 = cmd == UInt32(LC_VERSION_MIN_MACOSX) ? 1 : cmd == UInt32(LC_VERSION_MIN_IPHONEOS) ? 2 : cmd == UInt32(LC_VERSION_MIN_TVOS) ? 3 : 4
            img.builds.append(MachOBuild(command: lc.name, platform: plat, minos: v, sdk: sdk, tools: []))
            lc.summary = "\(F.platform(plat)) \(F.version(v)), SDK \(F.version(sdk))"
            add("Platform", F.platform(plat)); add("Minimum OS", F.version(v)); add("SDK", sdk == 0 ? "not recorded" : F.version(sdk))

        case UInt32(LC_SOURCE_VERSION):
            guard need(c, 16, &lc) else { return }
            let v = c.u64(8)!
            img.sourceVersion = v
            lc.summary = F.sourceVersion(v)
            add("Version", F.sourceVersion(v))

        case LC_MAIN:
            guard need(c, 24, &lc) else { return }
            let off = c.u64(8)!, stack = c.u64(16)!
            img.entry = ("LC_MAIN", off, nil, stack)
            lc.summary = "entry at file offset 0x\(mhex(off))"
            add("Entry offset", "0x" + mhex(off), "File offset of main(), from the start of __TEXT")
            add("Stack size", stack == 0 ? "default" : F.sizeExact(stack))

        case UInt32(LC_UNIXTHREAD), UInt32(LC_THREAD):
            var o = 8
            var states = 0
            while o + 8 <= c.count, states < 16 {
                let flavor = c.u32(o)!, count = c.u32(o + 4)!
                let body = o + 8
                guard c.has(body, Int(count) * 4) else { lc.issues.append("Thread state flavor \(flavor) (\(count) words) runs past the command"); break }
                add("Flavor", F.threadFlavor(img.cputype, flavor), "\(count) words")
                if let pc = threadPC(img.cputype, flavor, c, body) {
                    add("Entry (pc)", "0x" + mhex(pc))
                    if cmd == UInt32(LC_UNIXTHREAD) { img.entry = ("LC_UNIXTHREAD", nil, pc, nil) }
                    lc.summary = "pc 0x\(mhex(pc))"
                }
                o = body + Int(count) * 4; states += 1
            }

        case UInt32(LC_CODE_SIGNATURE), UInt32(LC_SEGMENT_SPLIT_INFO), UInt32(LC_FUNCTION_STARTS), UInt32(LC_DATA_IN_CODE),
             UInt32(LC_DYLIB_CODE_SIGN_DRS), UInt32(LC_LINKER_OPTIMIZATION_HINT), LC_DYLD_EXPORTS_TRIE, LC_DYLD_CHAINED_FIXUPS,
             0x36, 0x37, 0x38, 0x3a:
            guard need(c, 16, &lc) else { return }
            let off = c.u32(8)!, size = c.u32(12)!
            img.blobs.append(MachOBlob(name: MachONames.blobName(cmd), command: lc.id, offset: UInt64(off), size: UInt64(size)))
            lc.summary = "\(F.size(UInt64(size))) at 0x\(mhex(UInt64(off)))"
            add("Data offset", "0x" + mhex(UInt64(off))); add("Data size", F.sizeExact(UInt64(size)))

        case UInt32(LC_DYLD_INFO), LC_DYLD_INFO_ONLY:
            guard need(c, 48, &lc) else { return }
            let parts = ["Rebase", "Bind", "Weak bind", "Lazy bind", "Export"]
            var sum: [String] = []
            for (i, p) in parts.enumerated() {
                let off = c.u32(8 + i * 8)!, size = c.u32(12 + i * 8)!
                add("\(p) info", size == 0 ? "none" : "\(F.sizeExact(UInt64(size))) at 0x\(mhex(UInt64(off)))")
                if size > 0 { img.blobs.append(MachOBlob(name: "\(p) info", command: lc.id, offset: UInt64(off), size: UInt64(size))); sum.append(p.lowercased()) }
            }
            lc.summary = sum.joined(separator: ", ")

        case UInt32(LC_ENCRYPTION_INFO), UInt32(LC_ENCRYPTION_INFO_64):
            guard need(c, 20, &lc) else { return }
            let off = c.u32(8)!, size = c.u32(12)!, id = c.u32(16)!
            img.encryption = (off, size, id)
            lc.summary = id == 0 ? "not encrypted" : "encrypted (cryptid \(id))"
            add("Encrypted range", "\(F.sizeExact(UInt64(size))) at 0x\(mhex(UInt64(off)))")
            add("cryptid", id == 0 ? "0 (not encrypted)" : "\(id) (encrypted: the pages are decrypted by the kernel as they load)")

        case UInt32(LC_LINKER_OPTION):
            guard need(c, 12, &lc) else { return }
            let n = c.u32(8)!
            var o = 12, opts: [String] = []
            for _ in 0..<min(n, 1000) {
                guard let s = c.cString(o, limit: c.count - o), o < c.count else { lc.issues.append("Fewer strings than the count (\(n))"); break }
                opts.append(s.text); o += s.text.utf8.count + 1
            }
            img.linkerOptions.append(opts)
            lc.summary = opts.joined(separator: " ")
            add("Options", lc.summary)

        case UInt32(LC_NOTE):
            guard need(c, 40, &lc) else { return }
            let owner = c.fixed(8, 16) ?? "", off = c.u64(24)!, size = c.u64(32)!
            lc.summary = "\(owner): \(F.size(size))"
            add("Owner", owner); add("Data", "\(F.sizeExact(size)) at 0x\(mhex(off))")
            img.blobs.append(MachOBlob(name: "Note \(owner)", command: lc.id, offset: off, size: size))

        case LC_FILESET_ENTRY:
            guard need(c, 32, &lc) else { return }
            let vm = c.u64(8)!, fo = c.u64(16)!
            let id = lcStr(c, at: 24, &lc, "entry id") ?? ""
            img.filesetEntries.append((id, vm, fo))
            lc.summary = id
            add("Entry", id); add("VM address", "0x" + mhex(vm)); add("File offset", "0x" + mhex(fo))

        case 0x39: // LC_TARGET_TRIPLE
            let s = lcStr(c, at: 8, &lc, "triple") ?? ""
            img.targetTriple = s
            lc.summary = s
            add("Triple", s)

        case UInt32(LC_SUB_FRAMEWORK), UInt32(LC_SUB_UMBRELLA), UInt32(LC_SUB_CLIENT), UInt32(LC_SUB_LIBRARY):
            let s = lcStr(c, at: 8, &lc) ?? ""
            lc.summary = s
            switch cmd {
            case UInt32(LC_SUB_FRAMEWORK): img.subFramework = s; add("Umbrella", s)
            case UInt32(LC_SUB_UMBRELLA): img.subUmbrellas.append(s); add("Sub-umbrella", s)
            case UInt32(LC_SUB_CLIENT): img.subClients.append(s); add("Allowed client", s)
            default: img.subLibraries.append(s); add("Sub-library", s)
            }

        case UInt32(LC_ROUTINES), UInt32(LC_ROUTINES_64):
            let w = cmd == UInt32(LC_ROUTINES_64)
            guard need(c, w ? 72 : 40, &lc) else { return }
            let addr = w ? c.u64(8)! : UInt64(c.u32(8)!), mod = w ? c.u64(16)! : UInt64(c.u32(12)!)
            lc.summary = "init at 0x\(mhex(addr))"
            add("Init address", "0x" + mhex(addr)); add("Init module", "\(mod)")

        case UInt32(LC_PREBOUND_DYLIB):
            let s = lcStr(c, at: 8, &lc) ?? ""
            lc.summary = s
            add("Library", s); add("Modules", c.u32(12).map { "\($0)" } ?? "?")

        case UInt32(LC_TWOLEVEL_HINTS):
            guard need(c, 16, &lc) else { return }
            lc.summary = "\(c.u32(12)!) hints"
            add("Offset", "0x" + mhex(UInt64(c.u32(8)!))); add("Hints", "\(c.u32(12)!)")

        case UInt32(LC_PREBIND_CKSUM):
            guard need(c, 12, &lc) else { return }
            lc.summary = "0x" + mhex(UInt64(c.u32(8)!))
            add("Checksum", lc.summary)

        case UInt32(LC_LOADFVMLIB), UInt32(LC_IDFVMLIB):
            let s = lcStr(c, at: 8, &lc) ?? ""
            lc.summary = s
            add("Library", s); add("Minor version", c.u32(12).map { "\($0)" } ?? "?"); add("Header address", c.u32(16).map { "0x" + mhex(UInt64($0)) } ?? "?")

        case UInt32(LC_FVMFILE):
            let s = lcStr(c, at: 8, &lc) ?? ""
            lc.summary = s
            add("File", s); add("Header address", c.u32(12).map { "0x" + mhex(UInt64($0)) } ?? "?")

        case UInt32(LC_SYMSEG):
            guard need(c, 16, &lc) else { return }
            add("Offset", "0x" + mhex(UInt64(c.u32(8)!))); add("Size", F.sizeExact(UInt64(c.u32(12)!)))

        case UInt32(LC_IDENT):
            var o = 8, parts: [String] = []
            while o < c.count, let s = c.cString(o, limit: c.count - o) { if !s.text.isEmpty { parts.append(s.text) }; o += s.text.utf8.count + 1 }
            lc.summary = parts.joined(separator: " ")
            add("Strings", lc.summary)

        default:
            lc.summary = "\(c.count) bytes"
            let words = (0..<min((c.count - 8) / 4, 16)).compactMap { c.u32(8 + $0 * 4) }.map { "0x" + String($0, radix: 16) }
            if !words.isEmpty { add("Words", words.joined(separator: " "), "Not decoded: shown as 32-bit words after cmd and cmdsize") }
        }
    }

    /// The program counter in a thread state: where an LC_UNIXTHREAD executable starts.
    private static func threadPC(_ cpu: Int32, _ flavor: UInt32, _ c: Bytes, _ o: Int) -> UInt64? {
        switch (cpu, flavor) {
        case (CPU_TYPE_ARM64, 6): return c.u64(o + 32 * 8)            // ARM_THREAD_STATE64: x0–x28, fp, lr, sp, pc
        case (CPU_TYPE_X86_64, 4): return c.u64(o + 16 * 8)           // x86_THREAD_STATE64: … rip
        case (CPU_TYPE_X86, 1): return c.u32(o + 10 * 4).map(UInt64.init)   // i386_THREAD_STATE: … eip
        case (CPU_TYPE_ARM, 1): return c.u32(o + 15 * 4).map(UInt64.init)   // ARM_THREAD_STATE: r0–r12, sp, lr, pc
        case (CPU_TYPE_POWERPC, 1): return c.u32(o).map(UInt64.init)        // PPC_THREAD_STATE: srr0 first
        default: return nil
        }
    }

    // MARK: Cross-checks

    private static func validate(_ img: inout MachOImage, _ b: Bytes) {
        let size = UInt64(b.count)
        for i in img.segments.indices {
            let s = img.segments[i]
            if s.filesize > 0, s.fileoff > size || s.filesize > size - s.fileoff {
                img.segments[i].issues.append("File range 0x\(mhex(s.fileoff))+\(s.filesize) runs past the end of the slice (\(size) bytes)")
            }
            // A segment with no VM size is in the file but never mapped (Go's linker puts its __DWARF there):
            // its sections' addresses mean nothing, so they aren't checked against it.
            let unmapped = s.vmsize == 0 && s.filesize > 0
            if s.filesize > s.vmsize, !unmapped { img.segments[i].issues.append("File size \(s.filesize) is larger than VM size \(s.vmsize)") }
            // An object file has one unnamed segment holding every section, each naming the segment it will go to.
            let objectSegment = s.name.isEmpty && img.filetype == UInt32(MH_OBJECT)
            for j in s.sections.indices {
                let x = s.sections[j]
                var iss: [String] = []
                if x.segment != s.name, !objectSegment { iss.append("Section names segment \(x.segment), it's inside \(s.name)") }
                if !unmapped, x.addr < s.vmaddr || x.addr &+ x.size > s.vmaddr &+ s.vmsize { iss.append("Address range is outside its segment") }
                if !x.isZerofill, x.size > 0, x.offset != 0, UInt64(x.offset) + x.size > size { iss.append("File range runs past the end of the slice") }
                if x.align > 31 { iss.append("Alignment 2^\(x.align) is impossible") }
                img.segments[i].sections[j].issues = iss
            }
        }
        for bl in img.blobs where bl.size > 0 && (bl.offset > size || bl.size > size - bl.offset) {
            img.issues.append("\(bl.name) (0x\(mhex(bl.offset))+\(bl.size)) runs past the end of the slice")
            if let i = img.commands.firstIndex(where: { $0.id == bl.command }) { img.commands[i].issues.append("Data runs past the end of the slice") }
        }
        if let le = img.segments.first(where: { $0.name == "__LINKEDIT" }) {
            let lo = le.fileoff, hi = le.fileoff + le.filesize
            for bl in img.blobs where bl.size > 0 && (bl.offset < lo || bl.offset + bl.size > hi) && img.filetype != UInt32(MH_OBJECT) {
                img.issues.append("\(bl.name) isn't inside __LINKEDIT")
            }
        }
        let names = img.segments.map(\.name).filter { !$0.isEmpty }
        for n in Set(names) where names.filter({ $0 == n }).count > 1 { img.issues.append("Segment \(n) appears more than once") }
        // DriverKit extensions are MH_EXECUTE with no entry point: DriverKit's runtime loads them.
        if img.filetype == UInt32(MH_EXECUTE), img.entry == nil, !img.builds.contains(where: { $0.platform == 10 }) { img.issues.append("An executable with no entry point (no LC_MAIN or LC_UNIXTHREAD)") }
        if img.uuid == nil, img.filetype != UInt32(MH_OBJECT) { img.issues.append("No LC_UUID") }
    }
}

func mhex(_ v: UInt64) -> String { String(v, radix: 16) }

/// <mach-o/utils.h> (libdyld, macOS 13+), which Swift's MachO module doesn't include.
enum DyldMachO {
    private static let lib = dlopen(nil, RTLD_NOW)
    private typealias BestFn = @convention(c) (UnsafePointer<CChar>, @convention(block) (UnsafeRawPointer, UInt64, Int) -> Void) -> Int32
    private typealias NameFn = @convention(c) (Int32, Int32) -> UnsafePointer<CChar>?
    private static let best = dlsym(lib, "macho_best_slice").map { unsafeBitCast($0, to: BestFn.self) }
    private static let name = dlsym(lib, "macho_arch_name_for_cpu_type").map { unsafeBitCast($0, to: NameFn.self) }

    /// The slice dyld would load (a library) or the kernel would run (an executable) on this Mac; 0 or an errno.
    @discardableResult
    static func bestSlice(_ path: String, _ found: @escaping (UInt64) -> Void) -> Int32 {
        guard let best else { return ENOSYS }
        return path.withCString { p in best(p) { _, off, _ in found(off) } }
    }

    static func archName(_ type: Int32, _ subtype: Int32) -> String? { name?(type, subtype).map { String(cString: $0) } }
}
