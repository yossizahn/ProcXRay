import Foundation

/// Where each linked library comes from, worked out the way dyld does for the paths it can see: `@rpath`
/// through the run-path list (this image's, then the main executable's), `@loader_path` from this file's
/// folder, `@executable_path` from the main executable's. A path in the dyld shared cache is found there
/// first, as dyld does for OS paths; most system libraries exist nowhere else (there is no
/// /usr/lib/libSystem.B.dylib on disk).
///
/// Not modelled: DYLD_* variables of the process, LC_DYLD_ENVIRONMENT's paths, the default fallback paths
/// (only reached for a library that is missing anyway), and run-paths inherited from intermediate libraries.
enum MachOLibraries {
    enum Location: Hashable {
        case file(String)
        case sharedCache(String)
        case missing
    }

    struct Resolved: Identifiable, Hashable {
        var id: Int { dylib.id }
        let dylib: MachODylib
        let location: Location
        /// Which run-path entry matched, for an @rpath library.
        let viaRpath: String?
        /// Every path tried, in order, for an unresolved or @rpath library.
        let tried: [String]
    }

    struct RunPath: Identifiable, Hashable {
        let id: Int
        let raw: String
        let expanded: String?
        let exists: Bool
        /// "this image" or "main executable".
        let from: String
    }

    struct Context {
        /// The file the image is in.
        let loader: String
        /// The main executable, when known, and how it was found.
        let executable: String?
        let executableSource: String?
        let executableRpaths: [String]
    }

    /// The shared cache's library paths, as this process's dyld sees them.
    static let sharedCache: Set<String> = Set(SharedCacheImages().images.map(\.path))

    static func context(for image: MachOImage, path: String, executable: String?) -> Context {
        if image.filetype == 0x2 { return Context(loader: path, executable: path, executableSource: "this file", executableRpaths: []) }
        var exe = executable, source: String? = executable == nil ? nil : "the process"
        if exe == nil, let app = enclosingApp(path), let e = Bundle(path: app)?.executablePath {
            exe = e; source = "the enclosing app (\((app as NSString).lastPathComponent))"
        }
        var rp: [String] = []
        if let exe, exe != path {
            let f = MachOParser.load(path: exe)
            if f.slices.indices.contains(f.defaultSlice), let img = f.slices[f.defaultSlice].image { rp = img.rpaths.map(\.path) }
        }
        return Context(loader: path, executable: exe, executableSource: source, executableRpaths: rp)
    }

    static func enclosingApp(_ path: String) -> String? {
        var p = path as NSString
        while p.length > 1 {
            p = p.deletingLastPathComponent as NSString
            if p.pathExtension == "app" { return p as String }
        }
        return nil
    }

    static func expand(_ s: String, _ ctx: Context) -> String? {
        let loaderDir = (ctx.loader as NSString).deletingLastPathComponent
        if s.hasPrefix("@loader_path") { return standard(loaderDir + s.dropFirst("@loader_path".count)) }
        if s.hasPrefix("@executable_path") {
            guard let e = ctx.executable else { return nil }
            return standard((e as NSString).deletingLastPathComponent + s.dropFirst("@executable_path".count))
        }
        if s.hasPrefix("@") { return nil }
        return standard(s)
    }

    private static func standard(_ s: String) -> String { (s as NSString).standardizingPath }

    static func runPaths(_ image: MachOImage, _ ctx: Context) -> [RunPath] {
        var out: [RunPath] = []
        for r in image.rpaths {
            let e = expand(r.path, ctx)
            out.append(RunPath(id: out.count, raw: r.path, expanded: e, exists: e.map(isDir) ?? false, from: "this image"))
        }
        // The main executable's run-paths: dyld searches them too, after the loader's.
        let exeCtx = Context(loader: ctx.executable ?? ctx.loader, executable: ctx.executable, executableSource: nil, executableRpaths: [])
        for r in ctx.executableRpaths where ctx.executable != ctx.loader {
            let e = expand(r, exeCtx)
            out.append(RunPath(id: out.count, raw: r, expanded: e, exists: e.map(isDir) ?? false, from: "main executable"))
        }
        return out
    }

    static func resolve(_ image: MachOImage, _ ctx: Context) -> [Resolved] {
        let rps = runPaths(image, ctx)
        return image.dylibs.map { d in
            let p = d.path
            if p.hasPrefix("@rpath/") {
                let tail = String(p.dropFirst("@rpath".count))
                var tried: [String] = []
                for r in rps {
                    guard let base = r.expanded else { tried.append(r.raw + tail + " (can't expand)"); continue }
                    let cand = standard(base + tail)
                    tried.append(cand)
                    if let loc = locate(cand) { return Resolved(dylib: d, location: loc, viaRpath: r.raw, tried: tried) }
                }
                return Resolved(dylib: d, location: .missing, viaRpath: nil, tried: tried)
            }
            guard let e = expand(p, ctx) else {
                return Resolved(dylib: d, location: .missing, viaRpath: nil, tried: [p + " (no main executable to expand it against)"])
            }
            if let loc = locate(e) { return Resolved(dylib: d, location: loc, viaRpath: nil, tried: []) }
            return Resolved(dylib: d, location: .missing, viaRpath: nil, tried: [e])
        }
    }

    /// The shared cache first, then the file, then the OS cryptex's copy (where macOS keeps some libraries).
    static func locate(_ p: String) -> Location? {
        if sharedCache.contains(p) { return .sharedCache(p) }
        if FileManager.default.fileExists(atPath: p) { return .file(p) }
        let crypt = "/System/Cryptexes/OS" + p
        if FileManager.default.fileExists(atPath: crypt) { return .file(crypt) }
        return nil
    }

    private static func isDir(_ p: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue
    }
}
