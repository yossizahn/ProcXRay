import Darwin
import Foundation

/// Names for the frames of a traced process's syscall stacks, without a task port for it (so with SIP on too).
///   - Frames in the dyld shared cache: every process maps the cache at the same address, so they are looked up
///     in this process's own copy (CoreSymbolication on our task, which also knows the cache's local symbols).
///     A library this process never loaded isn't known to that: dyld's list of the cache's libraries
///     (dyld_shared_cache_iterate_text) names it, and CoreSymbolication reads it from the cache by its path at
///     its unslid address. Measured on a Finder trace: 116 of 448 distinct frames were in such libraries
///     (DesktopServicesPriv, Accounts, FileProvider...); that lookup named all but a few.
///   - Anything else: the helper sends the mapped file behind each frame (StackRegion, from
///     PROC_PIDREGIONPATHINFO), and the file is symbolicated from its path, slid by where its __TEXT starts.
///     Checked on a test program: leaf+28 and main+116, as its own addresses said.
/// Frames after the first are return addresses: they are looked up one byte back (the call instruction) but
/// their offset is printed as is, as `sample` does.
final class StackSymbols: @unchecked Sendable {
    struct Frame: Sendable {
        let image: String
        let symbol: String?
        let offset: UInt64
        let address: UInt64
        /// The OS's code (the shared cache, /System, /usr/lib) rather than the process's own, or what it ships
        /// (its executable, its bundle's frameworks); nil when the frame's image isn't known.
        var system: Bool? = nil

        /// "stat + 8 (libsystem_kernel.dylib)", or "deep + 0x47c" without a symbol.
        var text: String {
            if let symbol { return "\(symbol) + \(offset)  (\(image))" }
            return image.isEmpty ? "0x" + String(address, radix: 16) : "\(image) + 0x" + String(offset, radix: 16)
        }
        var short: String { symbol.map { "\($0)  (\(image))" } ?? text }
    }

    private let lock = NSLock()
    private var regions: [StackRegion] = []
    private var files: [String: CS.Symbolicator?] = [:]
    private var cache: [UInt64: Frame] = [:]
    private lazy var own = CS.Symbolicator(task: mach_task_self_)
    private lazy var cacheImages = SharedCacheImages()
    private let sharedCache = SharedCache.range

    /// Regions for the images dyld reported loading (SyscallDecoder's "load image" records): the image's __TEXT,
    /// from its load address and its file's segment size. Names frames without asking the process, so also after
    /// it exited (a short-lived program launched with Launch and Trace, whose frames the helper couldn't look up in
    /// time). Images in the shared cache are named from it already.
    func addLoadedImages(_ recs: [SyscallRecord]) {
        var new: [StackRegion] = []
        for r in recs where r.isLibraryCall && r.name == "load image" {
            guard let start = r.args?.first, let path = r.paths.first, !sharedCache.contains(start) else { continue }
            lock.lock(); let known = loadedImages.contains(path); loadedImages.insert(path); lock.unlock()
            guard !known else { continue }
            let file = MachOParser.load(path: path)
            guard file.slices.indices.contains(file.defaultSlice),
                  let text = file.slices[file.defaultSlice].image?.segments.first(where: { $0.name == "__TEXT" }) else { continue }
            new.append(StackRegion(start: start, size: text.vmsize, path: path))
        }
        add(new)
    }
    private var loadedImages: Set<String> = []

    func add(_ new: [StackRegion]) {
        guard !new.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        regions += new
        regions.sort { $0.start < $1.start }
    }

    func frame(_ addr: UInt64, isReturn: Bool) -> Frame {
        let key = isReturn ? addr | 1 << 63 : addr
        lock.lock(); defer { lock.unlock() }
        if let f = cache[key] { return f }
        let look = isReturn && addr > 0 ? addr - 1 : addr
        var f = Frame(image: "", symbol: nil, offset: 0, address: addr)
        if sharedCache.contains(addr) {
            if let s = own?.lookup(look), !s.image.isEmpty {
                f = Frame(image: s.image, symbol: s.name, offset: addr - s.start, address: addr, system: true)
            } else if let img = cacheImages.image(addr) {
                let unslid = addr - cacheImages.slide
                let image = (img.path as NSString).lastPathComponent
                f = Frame(image: image, symbol: nil, offset: unslid - img.start, address: addr, system: true)
                if let sym = symbolicator(img.path, cache: true), let s = sym.lookup(unslid - (addr - look)) {
                    f = Frame(image: image, symbol: s.name, offset: unslid - s.start, address: addr, system: true)
                }
            }
        } else if let r = region(addr), !r.path.isEmpty {
            let image = (r.path as NSString).lastPathComponent
            let system = Self.systemPaths.contains { r.path.hasPrefix($0) }
            f = Frame(image: image, symbol: nil, offset: addr - r.start, address: addr, system: system)
            if let sym = symbolicator(r.path), let s = sym.lookup(sym.base + (look - r.start)) {
                f = Frame(image: image, symbol: s.name, offset: sym.base + (addr - r.start) - s.start, address: addr, system: system)
            }
        }
        cache[key] = f
        return f
    }

    func frames(_ stack: [UInt64]) -> [Frame] {
        stack.enumerated().map { frame($1, isReturn: $0 > 0) }
    }

    /// The first frame outside the syscall stubs' library: the code that made the call.
    func caller(_ stack: [UInt64]) -> String {
        for (i, a) in stack.enumerated() {
            let f = frame(a, isReturn: i > 0)
            if f.image != "libsystem_kernel.dylib" { return f.short }
        }
        return stack.isEmpty ? "" : frame(stack[0], isReturn: false).short
    }

    /// Images outside the shared cache that are still the OS's: dyld, a few libraries, plug-ins.
    static let systemPaths = ["/System/", "/usr/lib/", "/usr/libexec/", "/Library/Apple/"]

    /// The OS function the process's own code called to make this call, and the call site in that code: walking
    /// out from the trap, the last system frame before the first of the process's own. BetterDisplay polls with
    /// "IOServiceGetMatchingServices (IOKit)" from "BetterDisplay + 0xa29068": one call there is a dozen messages
    /// to the kernel (io_service_get_matching_services_bin, io_iterator_next…) that say little on their own.
    ///   - nil when the process's code made the trap itself (no system frame between), or a frame on the way
    ///     isn't known (the walk can't tell whose it is).
    ///   - nil when the system frame is a run loop the process handed its thread to (`handOvers`): what runs in
    ///     there is the framework's own work, not a call the process made.
    ///   - A tail call shows the function it jumped to: CGSessionCopyCurrentDictionary is
    ///     "SLSessionCopyCurrentDictionary (SkyLight)", IORegistryEntryCreateCFProperty is
    ///     "IORegistryEntrySearchCFProperty (IOKit)". Still the right name, one level down.
    func entry(_ stack: [UInt64]) -> (api: Frame, site: Frame)? {
        var api: Frame?
        for (i, a) in stack.enumerated() {
            let f = frame(a, isReturn: i > 0)
            guard let system = f.system else { return nil }
            if system {
                if f.image != "libsystem_kernel.dylib" || api != nil { api = f }
                continue
            }
            guard let api, !Self.handOvers.contains(api.symbol ?? "") else { return nil }
            return (api, f)
        }
        return nil
    }

    /// Functions a program calls to give its thread to a run loop for good (or for a modal session).
    static let handOvers: Set<String> = [
        "-[NSApplication run]", "NSApplicationMain", "-[NSApplication runModalForWindow:]", "-[NSApplication runModalSession:]",
        "CFRunLoopRun", "CFRunLoopRunInMode", "CFRunLoopRunSpecific", "dispatch_main", "UIApplicationMain", "static App.main()",
        "-[NSRunLoop(NSRunLoop) run]", "-[NSRunLoop(NSRunLoop) runMode:beforeDate:]", "-[NSRunLoop(NSRunLoop) runUntilDate:]",
        "-[NSRunLoop(NSRunLoop) acceptInputForMode:beforeDate:]",
    ]

    /// What set a call off: the outermost callout on its stack (a dispatch source firing, a run-loop timer, a
    /// message arriving) and the process's code it called, as "dispatch source · BetterDisplay + 0x3883dc", with
    /// the next frame of that code in `inner`. A Swift closure goes through a thunk that every closure of its shape
    /// shares: both of BetterDisplay's timers enter at + 0x3883dc and part at the next frame (+ 0xcf5ec, + 0xd12d10),
    /// so SyscallActivity tries the outer name first and the inner one when that mixes two rhythms.
    ///   - No code of the process's inside the callout: the function the callout called ("incoming message ·
    ///     mshMIGPerform  (HIServices)", another app's Accessibility request).
    ///   - No callout: a thread's own loop, by its entry in the process's code ("thread · …"); a worker thread
    ///     waking a run loop for a dispatch timer is "timer delivery". Otherwise nil.
    func trigger(_ stack: [UInt64]) -> (outer: String, inner: String)? {
        let frames = frames(stack)
        for k in frames.indices.reversed() {
            guard let kind = Self.callouts[frames[k].symbol ?? ""] else { continue }
            var i = k - 1
            while i >= 0, frames[i].system != false { i -= 1 }
            guard i >= 0 else { return k > 0 ? (kind + " · " + frames[k - 1].short, "") : nil }
            let inner = i > 0 && frames[i - 1].system == false ? frames[i - 1].text : ""
            return (kind + " · " + frames[i].text, inner)
        }
        if frames.contains(where: { $0.symbol == "_pthread_start" }),
           let i = frames.lastIndex(where: { $0.system == false }) {
            return ("thread · " + frames[i].text, i > 0 && frames[i - 1].system == false ? frames[i - 1].text : "")
        }
        if frames.contains(where: { $0.symbol == "_dispatch_event_loop_drain_timers" }),
           !frames.contains(where: { $0.system == false }) {
            return (Self.timerDelivery, "")
        }
        return nil
    }

    static let timerDelivery = "timer delivery"

    /// Where the system calls into a program's code, by what it is delivering. Not the main queue's drain or a
    /// queue's block callout: they hold the timers and sources, which say more.
    static let callouts: [String: String] = [
        "_dispatch_source_latch_and_call": "dispatch source", "_dispatch_source_invoke": "dispatch source",
        "__CFRUNLOOP_IS_CALLING_OUT_TO_A_TIMER_CALLBACK_FUNCTION__": "run-loop timer",
        "__CFRUNLOOP_IS_CALLING_OUT_TO_A_SOURCE1_PERFORM_FUNCTION__": "incoming message",
        "__CFRUNLOOP_IS_CALLING_OUT_TO_A_SOURCE0_PERFORM_FUNCTION__": "run-loop source",
        "__CFRUNLOOP_IS_CALLING_OUT_TO_AN_OBSERVER_CALLBACK_FUNCTION__": "run-loop observer",
        "-[NSApplication(NSEventRouting) sendEvent:]": "event",
    ]

    /// What a trace's calls need from their stacks: the caller, the API and its call site (`entry`), and what set
    /// the call off (`trigger`).
    func attribute(_ r: inout SyscallRecord) {
        guard !r.stack.isEmpty else { return }
        r.caller = caller(r.stack)
        if let e = entry(r.stack) { r.api = e.api.short; r.site = e.site.text }
        if let t = trigger(r.stack) { r.trigger = t.outer; r.triggerInner = t.inner }
    }

    private func region(_ a: UInt64) -> StackRegion? {
        var lo = 0, hi = regions.count
        while lo < hi { let m = (lo + hi) / 2; if regions[m].start + regions[m].size <= a { lo = m + 1 } else { hi = m } }
        return lo < regions.count && regions[lo].start <= a ? regions[lo] : nil
    }

    private func symbolicator(_ path: String, cache: Bool = false) -> CS.Symbolicator? {
        if let s = files[path] { return s }
        let s = CS.Symbolicator(path: path, needsBase: !cache)
        files[path] = s
        return s
    }
}

/// CoreSymbolication through dlsym (as NativeSample.Symbolicator): handles are 16-byte structs returned in two
/// registers, for which vm_range_t stands in; CSArchitecture is { cpu_type, cpu_subtype }, eight bytes in one
/// register, so a UInt64 with the subtype in the high half.
enum CS {
    private typealias Ref = vm_range_t
    private static let lib = dlopen("/System/Library/PrivateFrameworks/CoreSymbolication.framework/CoreSymbolication", RTLD_NOW)
    private static func fn<T>(_ name: String, _: T.Type) -> T? { dlsym(lib, name).map { unsafeBitCast($0, to: T.self) } }
    private static let withTask = fn("CSSymbolicatorCreateWithTask", (@convention(c) (task_t) -> Ref).self)
    private static let withPath = fn("CSSymbolicatorCreateWithPathAndArchitecture", (@convention(c) (UnsafePointer<CChar>, UInt64) -> Ref).self)
    private static let currentArch = fn("CSArchitectureGetCurrent", (@convention(c) () -> UInt64).self)
    private static let symbolAt = fn("CSSymbolicatorGetSymbolWithAddressAtTime", (@convention(c) (Ref, mach_vm_address_t, UInt64) -> Ref).self)
    private static let ownerAt = fn("CSSymbolicatorGetSymbolOwnerWithAddressAtTime", (@convention(c) (Ref, mach_vm_address_t, UInt64) -> Ref).self)
    private static let ownerNamed = fn("CSSymbolicatorGetSymbolOwnerWithNameAtTime", (@convention(c) (Ref, UnsafePointer<CChar>, UInt64) -> Ref).self)
    private static let symbolName = fn("CSSymbolGetName", (@convention(c) (Ref) -> UnsafePointer<CChar>?).self)
    private static let symbolRange = fn("CSSymbolGetRange", (@convention(c) (Ref) -> vm_range_t).self)
    private static let ownerName = fn("CSSymbolOwnerGetName", (@convention(c) (Ref) -> UnsafePointer<CChar>?).self)
    private static let ownerBase = fn("CSSymbolOwnerGetBaseAddress", (@convention(c) (Ref) -> mach_vm_address_t).self)
    private static let release = fn("CSRelease", (@convention(c) (Ref) -> Void).self)
    private static let now: UInt64 = 0x8000_0000_0000_0000   // kCSNow
    private static func isNull(_ r: Ref) -> Bool { r.address == 0 && r.size == 0 }

    /// Swift's own demangler (libswiftCore exports it); C and Objective-C names pass through.
    private static let demangle = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle").map {
        unsafeBitCast($0, to: (@convention(c) (UnsafePointer<CChar>, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?).self)
    }
    static func readable(_ name: String) -> String {
        guard name.hasPrefix("$s") || name.hasPrefix("_$s"), let demangle else { return name }
        guard let p = name.withCString({ demangle($0, strlen($0), nil, nil, 0) }) else { return name }
        defer { free(p) }
        return String(cString: p)
    }

    final class Symbolicator {
        struct Symbol { let name: String; let start: UInt64; let image: String }
        private let ref: Ref
        /// Unslid address of the file's __TEXT (0 for a task symbolicator, whose addresses are live).
        let base: UInt64

        init?(task: task_t) {
            guard let r = CS.withTask?(task), !CS.isNull(r) else { return nil }
            ref = r; base = 0
        }

        /// `needsBase`: a file on disk, looked up at its own unslid addresses (base = its __TEXT). A library in the
        /// shared cache is looked up at its unslid cache address instead, so it needs no base.
        init?(path: String, needsBase: Bool = true) {
            guard let withPath = CS.withPath, let arch = CS.currentArch?() else { return nil }
            let r = path.withCString { withPath($0, arch) }
            guard !CS.isNull(r) else { return nil }
            guard needsBase else { ref = r; base = 0; return }
            let owner = (path as NSString).lastPathComponent.withCString { CS.ownerNamed?(r, $0, CS.now) }
            guard let owner, !CS.isNull(owner), let b = CS.ownerBase?(owner) else { CS.release?(r); return nil }
            ref = r; base = b
        }

        deinit { CS.release?(ref) }

        func lookup(_ addr: UInt64) -> Symbol? {
            guard let sym = CS.symbolAt?(ref, addr, CS.now), !CS.isNull(sym),
                  let n = CS.symbolName?(sym), let range = CS.symbolRange?(sym) else { return nil }
            let owner = CS.ownerAt?(ref, addr, CS.now)
            let image = owner.flatMap { CS.isNull($0) ? nil : CS.ownerName?($0) }.map { String(cString: $0) } ?? ""
            return Symbol(name: CS.readable(String(cString: n)), start: UInt64(range.address), image: image)
        }
    }
}

/// The shared cache's libraries with their unslid __TEXT ranges (dyld_shared_cache_iterate_text, dyld's private
/// API, through dlsym), and the cache's slide in this process (that of any library in it).
final class SharedCacheImages {
    struct Image { let start: UInt64; let size: UInt64; let path: String }
    private(set) var images: [Image] = []
    private(set) var slide: UInt64 = 0

    init() {
        let any = UnsafeMutableRawPointer(bitPattern: -2)
        typealias UUIDFn = @convention(c) (UnsafeMutablePointer<UInt8>) -> Bool
        typealias IterFn = @convention(c) (UnsafePointer<UInt8>, @convention(block) (UnsafeRawPointer) -> Void) -> Int32
        guard let u = dlsym(any, "_dyld_get_shared_cache_uuid"), let it = dlsym(any, "dyld_shared_cache_iterate_text") else { return }
        var uuid = [UInt8](repeating: 0, count: 16)
        guard unsafeBitCast(u, to: UUIDFn.self)(&uuid) else { return }
        for i in 0..<_dyld_image_count() where String(cString: _dyld_get_image_name(i)).hasSuffix("/libsystem_kernel.dylib") {
            slide = UInt64(bitPattern: Int64(_dyld_get_image_vmaddr_slide(i)))
        }
        var list: [Image] = []
        // dyld_shared_cache_dylib_text_info: version, loadAddressUnslid, textSegmentSize, uuid[16], path.
        _ = unsafeBitCast(it, to: IterFn.self)(uuid) { info in
            let start = info.load(fromByteOffset: 8, as: UInt64.self), size = info.load(fromByteOffset: 16, as: UInt64.self)
            guard let p = info.load(fromByteOffset: 40, as: UnsafePointer<CChar>?.self) else { return }
            list.append(Image(start: start, size: size, path: String(cString: p)))
        }
        images = list.sorted { $0.start < $1.start }
    }

    /// The library whose __TEXT holds `addr` (a live address in the cache).
    func image(_ addr: UInt64) -> Image? {
        let a = addr &- slide
        var lo = 0, hi = images.count
        while lo < hi { let m = (lo + hi) / 2; if images[m].start + images[m].size <= a { lo = m + 1 } else { hi = m } }
        return lo < images.count && images[lo].start <= a ? images[lo] : nil
    }
}
