import Foundation

/// `ProcXRay --macho <file>…`: the parser's view of each file as text, for checking it against otool without
/// the UI. `--macho-corpus <list> [out.tsv]`: one line per slice for every path in `list` (one per line), with
/// the parse time, for timing the reader over many files and diffing its counts against otool's.
/// `--macho-fuzz <file> <n>`: n damaged copies (random bytes changed in the headers and load commands, or the
/// file cut short), each parsed in this process: finishing at all is the result (a trap would end it).
enum MachODump {
    static func fuzz(_ path: String, _ n: Int) {
        guard let orig = FileManager.default.contents(atPath: path), orig.count > 64 else { print("can't read \(path)"); return }
        let tmp = NSTemporaryDirectory() + "pxr-fuzz-\(getpid())"
        var rng = SystemRandomNumberGenerator()
        var issues = 0, slices = 0, images = 0
        let regions = [0..<min(orig.count, 65536)] + MachOParser.load(path: path).slices
            .map { $0.offset..<min(orig.count, $0.offset + 16384) }.filter { !$0.isEmpty }
        let t0 = Date()
        for i in 0..<n {
            var d = [UInt8](orig)
            if i % 4 == 3 {
                d = Array(d.prefix(Int.random(in: 1..<d.count, using: &rng)))      // cut short
            } else {
                // Where the headers are: the file's first 64 KB (the fat header, a thin file's load commands) and
                // the first 16 KB of every slice.
                let region = regions[Int.random(in: 0..<regions.count, using: &rng)]
                for _ in 0..<Int.random(in: 1...16, using: &rng) {
                    d[Int.random(in: region, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
                }
            }
            FileManager.default.createFile(atPath: tmp, contents: Data(d))
            let f = MachOParser.load(path: tmp)
            slices += f.slices.count
            for s in f.slices {
                guard let img = s.image else { continue }
                images += 1
                issues += img.issues.count + img.commands.reduce(0) { $0 + $1.issues.count }
                let ctx = MachOLibraries.Context(loader: tmp, executable: nil, executableSource: nil, executableRpaths: [])
                _ = MachOLibraries.resolve(img, ctx)
            }
            issues += f.issues.count
        }
        try? FileManager.default.removeItem(atPath: tmp)
        print(String(format: "%d damaged copies of %@ parsed in %.1f s: %d slices, %d readable images, %d issues found, no crash",
                     n, path, -t0.timeIntervalSinceNow, slices, images, issues))
    }

    static func run(_ args: [String]) {
        for path in args {
            let f = MachOParser.load(path: path)
            print("\(path): \(f.container?.rawValue ?? "unreadable"), \(f.size) bytes, parsed in \(String(format: "%.2f", f.millis)) ms")
            for i in f.issues { print("  ! \(i)") }
            for s in f.slices {
                print("  slice \(s.title) at 0x\(mhex(UInt64(s.offset))) size \(s.size)\(s.runsHere ? " (runs here)" : "")")
                if let n = s.note { print("    \(n)") }
                guard let img = s.image else { continue }
                print("    \(MachONames.fileType(img.filetype).0), \(img.ncmds) commands, flags \(MachONames.bits(img.flags, MachONames.headerFlags))")
                for c in img.commands {
                    print("    [\(c.id)] \(c.name)  \(c.summary)")
                    for x in c.issues { print("        ! \(x)") }
                }
                for seg in img.segments {
                    print("    segment \(seg.name) \(MachONames.prot(seg.initprot)) vm 0x\(mhex(seg.vmaddr))+0x\(mhex(seg.vmsize)) file 0x\(mhex(seg.fileoff))+0x\(mhex(seg.filesize))")
                    for x in seg.issues { print("        ! \(x)") }
                    for sec in seg.sections {
                        print("      \(sec.name) 0x\(mhex(sec.addr))+0x\(mhex(sec.size)) \(MachONames.sectionType(sec.flags))")
                        for x in sec.issues { print("        ! \(x)") }
                    }
                }
                let ctx = MachOLibraries.context(for: img, path: path, executable: nil)
                for r in MachOLibraries.resolve(img, ctx) {
                    let loc: String
                    switch r.location {
                    case .file(let p): loc = "file \(p)"
                    case .sharedCache: loc = "shared cache"
                    case .missing: loc = "MISSING (tried \(r.tried.joined(separator: ", ")))"
                    }
                    print("    lib #\(r.dylib.ordinal) \(r.dylib.kind.rawValue) \(r.dylib.path) → \(loc)")
                }
                for x in img.issues { print("    ! \(x)") }
            }
        }
    }

    static func corpus(_ list: String, out: String?) {
        guard let text = try? String(contentsOfFile: list, encoding: .utf8) else { print("can't read \(list)"); return }
        let paths = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        var lines = ["path\tslice\tarch\tncmds\tparsed_cmds\tsegments\tsections\tdylibs\trpaths\tuuid\tissues\tms"]
        var total = 0.0, slowest: (Double, String) = (0, ""), files = 0, slices = 0, issues = 0
        for p in paths {
            let f = MachOParser.load(path: p)
            files += 1; total += f.millis
            if f.millis > slowest.0 { slowest = (f.millis, p) }
            if f.slices.isEmpty { lines.append("\(p)\t-\t-\t-\t-\t-\t-\t-\t-\t-\t\(f.issues.joined(separator: "; "))\t\(f.millis)") }
            for s in f.slices {
                slices += 1
                guard let img = s.image else { lines.append("\(p)\t\(s.id)\t\(s.title)\t-\t-\t-\t-\t-\t-\t-\t\(s.note ?? "")\t\(f.millis)"); continue }
                let iss = img.issues + img.commands.flatMap(\.issues) + img.segments.flatMap { $0.issues + $0.sections.flatMap(\.issues) }
                issues += iss.count
                lines.append([p, "\(s.id)", s.title, "\(img.ncmds)", "\(img.commands.count)", "\(img.segments.count)", "\(img.allSections.count)",
                              "\(img.dylibs.count)", "\(img.rpaths.count)", img.uuid?.uuidString ?? "-", iss.joined(separator: "; "), "\(f.millis)"].joined(separator: "\t"))
            }
        }
        print(String(format: "%d files, %d slices, %.1f ms total, %.3f ms mean, slowest %.2f ms (%@), %d issues", files, slices, total, total / Double(max(files, 1)), slowest.0, slowest.1, issues))
        if let out { try? (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8) }
    }
}
