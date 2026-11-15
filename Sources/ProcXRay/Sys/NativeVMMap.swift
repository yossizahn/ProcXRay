import Darwin
import Foundation

/// `vmmap --summary` read straight from the target's task port (only when SIP allows task ports; see NativeMach for why the helper
/// has one). The output is vmmap's text layout, so VmmapParser, its views and the Raw switch work unchanged.
///
/// How regions get vmmap's names, measured by joining a native walk with `vmmap -v` on macOS 27.2:
///   - a range inside a loaded image's segment is that segment ("__TEXT", "__DATA_CONST"…), from dyld's process info;
///   - a shared-cache range no loaded image covers is "unused …"; the summary keeps only dirty or swapped ones, as
///     "unused but dirty shlib __DATA";
///   - anything else is named by its VM user tag and share mode (`tagNames`).
/// Not reproduced: splits that need libmalloc's view of a region ("Malloc Small (empty)", "Malloc Metadata metadata")
/// fold into their base row; "page table in kernel" is left out (no public source for it).
enum NativeVMMap {
    /// One leaf VM region (submaps descended into).
    struct Leaf: Codable {
        var start: UInt64, end: UInt64
        var tag: UInt32
        var share: UInt8
        var prot: Int32, maxProt: Int32
        /// In pages.
        var resident: UInt32, dirty: UInt32, swapped: UInt32
        var objectID: UInt32
        var depth: UInt32
        var path: String?
    }

    /// A segment of a loaded image, from dyld's process info.
    struct Segment: Codable {
        var start: UInt64, end: UInt64
        var name: String
        var path: String
    }

    static func controlPort(_ pid: pid_t) -> mach_port_t? {
        guard getuid() == 0, SystemSecurity.current.allows(.taskForPid) else { return nil }
        var t: mach_port_t = 0
        return task_for_pid(mach_task_self_, pid, &t) == KERN_SUCCESS ? t : nil
    }

    static func leaves(_ task: mach_port_t, pid: pid_t) -> [Leaf] {
        var out: [Leaf] = []
        var addr: mach_vm_address_t = 0
        var depth: natural_t = 0
        while true {
            var size: mach_vm_size_t = 0
            var info = vm_region_submap_info_data_64_t()
            var count = mach_msg_type_number_t(MemoryLayout<vm_region_submap_info_data_64_t>.size / MemoryLayout<natural_t>.size)
            let r = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    mach_vm_region_recurse(task, &addr, &size, &depth, $0, &count)
                }
            }
            guard r == KERN_SUCCESS else { break }
            if info.is_submap != 0 { depth += 1; continue }
            out.append(Leaf(start: addr, end: addr + size, tag: info.user_tag, share: info.share_mode,
                            prot: info.protection, maxProt: info.max_protection,
                            resident: info.pages_resident, dirty: info.pages_dirtied, swapped: info.pages_swapped_out,
                            objectID: info.object_id, depth: depth, path: filePath(pid, addr)))
            addr += size
        }
        return out
    }

    /// The file mapped at exactly `addr`. PROC_PIDREGIONPATHINFO answers for the region at *or after* the
    /// address, so a region without a file would otherwise borrow the next mapped file's path.
    static func filePath(_ pid: pid_t, _ addr: UInt64) -> String? {
        var info = proc_regionwithpathinfo()
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, addr, &info, size) == size,
              info.prp_prinfo.pri_address <= addr, addr < info.prp_prinfo.pri_address + info.prp_prinfo.pri_size else { return nil }
        let p = withUnsafeBytes(of: info.prp_vip.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return p.isEmpty ? nil : p
    }

    // dyld's process-info SPI (libdyld exports it; dyld_process_info.h is not in the SDK). What vmmap, heap and
    // symbols use to list another task's images and their segments.
    private typealias CreateFn = @convention(c) (mach_port_t, UInt64, UnsafeMutablePointer<kern_return_t>?) -> OpaquePointer?
    private typealias ReleaseFn = @convention(c) (OpaquePointer?) -> Void
    private typealias ImageBlock = @convention(block) (UInt64, UnsafePointer<UInt8>?, UnsafePointer<CChar>?) -> Void
    private typealias ForEachImageFn = @convention(c) (OpaquePointer?, ImageBlock) -> Void
    private typealias SegmentBlock = @convention(block) (UInt64, UInt64, UnsafePointer<CChar>?) -> Void
    private typealias ForEachSegmentFn = @convention(c) (OpaquePointer?, UInt64, SegmentBlock) -> Void
    private static let lib = dlopen(nil, RTLD_NOW)
    private static let create = dlsym(lib, "_dyld_process_info_create").map { unsafeBitCast($0, to: CreateFn.self) }
    private static let release = dlsym(lib, "_dyld_process_info_release").map { unsafeBitCast($0, to: ReleaseFn.self) }
    private static let forEachImage = dlsym(lib, "_dyld_process_info_for_each_image").map { unsafeBitCast($0, to: ForEachImageFn.self) }
    private static let forEachSegment = dlsym(lib, "_dyld_process_info_for_each_segment").map { unsafeBitCast($0, to: ForEachSegmentFn.self) }

    static func segments(_ task: mach_port_t) -> [Segment] {
        guard let create, let release, let forEachImage, let forEachSegment else { return [] }
        var kr: kern_return_t = 0
        guard let info = create(task, 0, &kr) else { return [] }
        defer { release(info) }
        var images: [(UInt64, String)] = []
        forEachImage(info) { header, _, path in images.append((header, path.map { String(cString: $0) } ?? "")) }
        var out: [Segment] = []
        for (header, path) in images {
            forEachSegment(info, header) { addr, size, name in
                // __PAGEZERO is reserved address space, not memory.
                guard size > 0, let name, String(cString: name) != "__PAGEZERO" else { return }
                out.append(Segment(start: addr, end: addr + size, name: String(cString: name), path: path))
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    // MARK: Summary

    /// One row of the REGION TYPE table, or a malloc zone's totals.
    struct Totals {
        var virtual: UInt64 = 0, resident: UInt64 = 0, dirty: UInt64 = 0, swapped: UInt64 = 0
        var volatile: UInt64 = 0, nonvol: UInt64 = 0, empty: UInt64 = 0
        var count = 0
        mutating func add(_ o: Totals) {
            virtual += o.virtual; resident += o.resident; dirty += o.dirty; swapped += o.swapped
            volatile += o.volatile; nonvol += o.nonvol; empty += o.empty; count += o.count
        }
    }

    static let pageSize = UInt64(vm_kernel_page_size)
    static let sharedRegion = SHARED_REGION_BASE_ARM64..<(SHARED_REGION_BASE_ARM64 + SHARED_REGION_SIZE_ARM64)
    static let protWrite = VM_PROT_WRITE

    /// vmmap's summary text for `pid`, or nil when there's no task port (SIP on, not root, or the process is gone).
    static func summary(_ pid: pid_t, zones: Bool = true) -> String? {
        guard let task = controlPort(pid) else { return nil }
        defer { mach_port_deallocate(mach_task_self_, task) }
        let t0 = Date()
        let leaves = leaves(task, pid: pid)
        guard !leaves.isEmpty else { return nil }
        let segs = segments(task)

        var rows: [String: Totals] = [:]
        var libRO = (total: UInt64(0), resident: UInt64(0))
        var writable = Totals()
        for l in leaves {
            // Reserved address space with nothing behind it (commpage, GPU carveout): not in vmmap's summary.
            if l.tag == 0 && l.prot == 0 && l.path == nil { continue }
            // Likewise malloc's inaccessible reservations; its guard pages are single pages (measured on logd).
            if l.tag == 1 && l.prot == 0 && l.end - l.start > 4 * pageSize { continue }
            for p in pieces(l, task: task, segs: segs) {
                var t = p.totals
                if p.unused {
                    // Shared-cache data of images this process didn't load. vmmap lists only their dirty segments;
                    // without those images' segment list, count the dirty and swapped bytes themselves.
                    guard t.dirty + t.swapped > 0 else { continue }
                    t.virtual = t.dirty + t.swapped
                    t.resident = t.dirty
                    rows["unused but dirty shlib __DATA", default: Totals()].add(t)
                    continue
                }
                purgeable(task, l, into: &t)
                rows[p.name, default: Totals()].add(t)
                // Both lines measured against vmmap on 86 processes: "Writable regions" is writable memory other than
                // image segments and mapped files (84 within 2 %), "ReadOnly portion of Libraries" is __TEXT plus
                // __LINKEDIT (82; resident 86 of 86).
                if !p.segment && p.name != "mapped file" && l.prot & protWrite != 0 { writable.add(t) }
                if p.name == "__TEXT" || p.name == "__LINKEDIT" { libRO.total += t.virtual; libRO.resident += t.resident }
            }
        }

        var out = header(pid, task: task)
        out += "\n"
        let roRest = libRO.total - min(libRO.resident, libRO.total)
        out += "ReadOnly portion of Libraries: Total=\(size(libRO.total)) resident=\(size(libRO.resident))(\(pct(libRO.resident, libRO.total))%) "
            + "swapped_out_or_unallocated=\(size(roRest))(\(pct(roRest, libRO.total))%)\n"
        let written = writable.dirty + writable.swapped
        let unallocated = writable.virtual - min(writable.virtual, writable.resident + writable.swapped)
        out += "Writable regions: Total=\(size(writable.virtual)) written=\(size(written))(\(pct(written, writable.virtual))%) "
            + "resident=\(size(writable.resident))(\(pct(writable.resident, writable.virtual))%) "
            + "swapped_out=\(size(writable.swapped))(\(pct(writable.swapped, writable.virtual))%) "
            + "unallocated=\(size(unallocated))(\(pct(unallocated, writable.virtual))%)\n\n"

        let w = max(34, (rows.keys.map(\.count).max() ?? 0) + 1)
        func pad(_ s: String) -> String { s.padding(toLength: w, withPad: " ", startingAt: 0) }
        out += pad("") + " VIRTUAL RESIDENT    DIRTY  SWAPPED VOLATILE   NONVOL    EMPTY   REGION \n"
        out += pad("REGION TYPE") + "    SIZE     SIZE     SIZE     SIZE     SIZE     SIZE     SIZE    COUNT (non-coalesced) \n"
        out += pad("===========") + " ======= ========    =====  ======= ========   ======    =====  ======= \n"
        var total = Totals()
        for (name, t) in rows.sorted(by: { order($0.key, $1.key) }) {
            total.add(t)
            let note = name.hasPrefix("Malloc") ? "         see MALLOC ZONE table below" : ""
            out += pad(name) + cols(t) + note + "\n"
        }
        out += pad("===========") + " ======= ========    =====  ======= ========   ======    =====  ======= \n"
        out += pad("TOTAL") + cols(total) + "\n"
        var unreserved = total
        let reserved = rows.filter { $0.key.hasSuffix("(reserved)") }
        for (_, t) in reserved {
            unreserved.virtual -= t.virtual; unreserved.resident -= t.resident; unreserved.dirty -= t.dirty
            unreserved.swapped -= t.swapped; unreserved.count -= t.count
        }
        if !reserved.isEmpty { out += pad("TOTAL, minus reserved VM space") + cols(unreserved) + "\n" }

        if zones { out += zoneTable(task, pid: pid) }
        out += String(format: "\n(native task-port read in %.0f ms)\n", -t0.timeIntervalSinceNow * 1000)
        return out
    }

    /// vmmap sorts names case-sensitively, so capitalised types come before "__TEXT" and "mapped file".
    static func order(_ a: String, _ b: String) -> Bool { a.compare(b, options: .literal) == .orderedAscending }

    struct Piece {
        var name: String
        var totals: Totals
        var unused = false
        var segment = false
    }

    /// A region split at image segment boundaries: one piece per segment it overlaps, and the gaps between them.
    static func pieces(_ l: Leaf, task: mach_port_t, segs: [Segment]) -> [Piece] {
        let inCache = sharedRegion.contains(l.start)
        // Segments overlapping [start, end).
        var lo = 0, hi = segs.count
        while lo < hi { let m = (lo + hi) / 2; if segs[m].end <= l.start { lo = m + 1 } else { hi = m } }
        var spans: [(start: UInt64, end: UInt64, seg: Segment?)] = []
        var cursor = l.start
        var i = lo
        while i < segs.count, segs[i].start < l.end {
            let s = max(segs[i].start, l.start), e = min(segs[i].end, l.end)
            if s > cursor { spans.append((cursor, s, nil)) }
            if e > max(s, cursor) { spans.append((max(s, cursor), e, segs[i])) }
            cursor = max(cursor, e)
            i += 1
        }
        if cursor < l.end { spans.append((cursor, l.end, nil)) }

        func piece(_ seg: Segment?, _ t: Totals) -> Piece {
            if let seg { return Piece(name: seg.name, totals: t, segment: true) }
            if inCache && l.path == nil && (l.tag == 0 || l.tag == 35) { return Piece(name: "unused", totals: t, unused: true) }
            return Piece(name: tagName(l), totals: t)
        }
        if spans.count == 1 && !(spans[0].seg == nil && inCache && l.path == nil && (l.tag == 0 || l.tag == 35)) {
            let t = Totals(virtual: l.end - l.start, resident: UInt64(l.resident) * pageSize, dirty: UInt64(l.dirty) * pageSize,
                           swapped: UInt64(l.swapped) * pageSize, count: 1)
            return [piece(spans[0].seg, t)]
        }
        // Several pieces: count their pages one by one. Shared-cache segments aren't page-aligned (some are a few
        // bytes), so each piece gets the bytes of each page it overlaps, as vmmap counts them; whole pages would
        // count a page shared by many small segments once per segment.
        let pages = pageStates(task, l.start, l.end)
        return spans.map { sp in
            var t = Totals(virtual: sp.end - sp.start, count: 1)
            if let pages {
                var k = Int((sp.start - l.start) / pageSize)
                while k < pages.count {
                    let ps = l.start + UInt64(k) * pageSize
                    guard ps < sp.end else { break }
                    let overlap = min(sp.end, ps + pageSize) - max(sp.start, ps)
                    let d = pages[k]
                    if d & VM_PAGE_QUERY_PAGE_PRESENT != 0 { t.resident += overlap; if d & VM_PAGE_QUERY_PAGE_DIRTY != 0 { t.dirty += overlap } }
                    if d & VM_PAGE_QUERY_PAGE_PAGED_OUT != 0 { t.swapped += overlap }
                    k += 1
                }
            }
            return piece(sp.seg, t)
        }
    }

    /// Per-page disposition (VM_PAGE_QUERY_PAGE_*) for [start, end).
    static func pageStates(_ task: mach_port_t, _ start: UInt64, _ end: UInt64) -> [Int32]? {
        var n = mach_vm_size_t((end - start) / pageSize)
        guard n > 0 else { return [] }
        var buf = [Int32](repeating: 0, count: Int(n))
        let r = buf.withUnsafeMutableBufferPointer {
            mach_vm_page_range_query(task, start, end - start, mach_vm_address_t(UInt(bitPattern: $0.baseAddress)), &n)
        }
        return r == KERN_SUCCESS ? Array(buf.prefix(Int(n))) : nil
    }

    /// Purgeable objects: resident bytes by state, and the whole size of emptied ones.
    static func purgeable(_ task: mach_port_t, _ l: Leaf, into t: inout Totals) {
        guard l.tag != 0 || l.path == nil, l.prot != 0 else { return }
        var state: Int32 = 0
        guard mach_vm_purgable_control(task, l.start, VM_PURGABLE_GET_STATE, &state) == KERN_SUCCESS else { return }
        switch state & VM_PURGABLE_STATE_MASK {
        case VM_PURGABLE_VOLATILE: t.volatile += t.resident
        case VM_PURGABLE_EMPTY: t.empty += t.virtual
        case VM_PURGABLE_NONVOLATILE: t.nonvol += t.resident
        default: break
        }
    }

    /// vmmap's name for a region that isn't an image segment.
    static func tagName(_ l: Leaf) -> String {
        if l.path != nil { return "mapped file" }
        let shared = l.share == SM_SHARED || l.share == SM_TRUESHARED || l.share == SM_SHARED_ALIASED
        let base: String
        switch l.tag {
        case 0: base = shared ? "shared memory" : "Untagged"
        case 1: base = l.prot == 0 ? "Malloc Guard Page" : "Malloc Metadata"
        case 30: base = l.prot == 0 ? "Stack Guard" : "Stack"
        case 240...255: base = "App-Specific Tag \(l.tag - 239)"
        default: base = tagNames[l.tag] ?? "VM_MEMORY_\(l.tag)"
        }
        // Address space set aside but not yet backed (share mode empty, yet accessible).
        return l.share == SM_EMPTY && l.prot != 0 ? base + " (reserved)" : base
    }

    /// VM_MEMORY_* user tag → vmmap's region type, measured: `vmmap -v` of 86 processes on macOS 27.2 joined by
    /// address with the native walk (`--native-vm-regions`). Tags not seen there print as vmmap prints an unknown
    /// tag, "VM_MEMORY_<n>". 0, 1, 30 and 240…255 are named in `tagName`.
    static let tagNames: [UInt32: String] = [
        2: "Malloc Small", 3: "Malloc Large", 7: "Malloc Tiny", 11: "Malloc Nano", 20: "Mach Message", 21: "IOKit",
        22: "Deferred Reclaim", 31: "Guard", 41: "Foundation", 42: "CoreGraphics", 43: "CoreServices", 45: "CoreData",
        46: "CoreData Object IDs", 51: "CoreAnimation", 52: "CG Image", 53: "WebKit Malloc", 54: "CG Raster Data",
        57: "CG Backing Stores", 60: "Dyld Private Memory", 62: "SQLite Page Cache", 63: "JS VM Reservations",
        70: "Image IO", 73: "OS Alloc Once", 74: "Dispatch Continuations", 75: "Accelerate Framework",
        76: "CoreUI Image Data", 78: "Activity Tracing", 87: "Skywalk Networking", 88: "IOSurface", 100: "IOAccelerator",
        104: "ColorSync"]

    // MARK: Malloc zones

    /// Remote reads made for libmalloc's introspection, freed when the analysis ends. A C reader can't capture
    /// state, so this is static and zone analysis runs one at a time (`zoneLock`).
    nonisolated(unsafe) fileprivate static var reads: [(vm_address_t, vm_size_t)] = []
    private static let zoneLock = NSLock()

    /// vmmap's MALLOC ZONE table. libmalloc does the work: malloc_get_all_zones finds the target's zones, and each
    /// zone's introspection (code in libsystem_malloc, which sits in the shared cache at the same address in every
    /// process, so the target's pointer is callable here) enumerates its regions and counts its allocations,
    /// reading the target through `reader`. The target is suspended meanwhile, as vmmap does, since a running
    /// process changes these structures under the reader.
    static func zoneTable(_ task: mach_port_t, pid: pid_t) -> String {
        guard pid != getpid() else { return "" }
        zoneLock.lock()
        defer { zoneLock.unlock() }
        var token: task_suspension_token_t = 0
        guard task_suspend2(task, &token) == KERN_SUCCESS else { return "" }
        defer { task_resume2(token) }
        defer {
            for (a, s) in reads { vm_deallocate(mach_task_self_, a, s) }
            reads = []
        }
        var addrs: UnsafeMutablePointer<vm_address_t>?
        var n: UInt32 = 0
        guard malloc_get_all_zones(task, zoneReader, &addrs, &n) == KERN_SUCCESS, let addrs, n > 0 else { return "" }

        // Three passes, in this order: each zone's regions, then their pages, then libmalloc's statistics. The
        // statistics walk reads the heap, which decompresses the target's compressed pages; measured afterwards,
        // they'd all count as resident and none as swapped.
        var found: [(addr: vm_address_t, name: String, intro: malloc_introspection_t, version: UInt32, ranges: [vm_range_t])] = []
        for i in 0..<Int(n) {
            let za = addrs[i]
            var local: UnsafeMutableRawPointer?
            guard zoneReader(task, za, vm_size_t(MemoryLayout<malloc_zone_t>.size), &local) == KERN_SUCCESS, let local else { continue }
            let zone = local.loadUnaligned(as: malloc_zone_t.self)
            guard let intro = introspection(UInt(bitPattern: zone.introspect)) else { continue }
            let box = RangeBox()
            if let en = intro.enumerator {
                _ = withExtendedLifetime(box) {
                    en(task, Unmanaged.passUnretained(box).toOpaque(), UInt32(MALLOC_PTR_REGION_RANGE_TYPE), za, zoneReader, zoneRecorder)
                }
            }
            found.append((za, remoteString(task, UInt(bitPattern: zone.zone_name)) ?? "Zone", intro, zone.version, box.ranges))
        }
        var zones: [(name: String, t: Totals, count: Int, allocated: UInt64)] = []
        for z in found {
            var t = Totals()
            // libmalloc reports a region as several ranges; vmmap counts contiguous runs.
            var lastEnd: UInt64 = .max
            for r in z.ranges.sorted(by: { $0.address < $1.address }) {
                let a = UInt64(r.address), e = a + UInt64(r.size)
                if a != lastEnd { t.count += 1 }
                lastEnd = e
                t.virtual += UInt64(r.size)
                let ps = a & ~(pageSize - 1), pe = (e + pageSize - 1) & ~(pageSize - 1)
                // Nano and large reservations can be huge and untouched: skip the page walk past 4 GiB.
                guard pe - ps <= 4 << 30, let pages = pageStates(task, ps, pe) else { continue }
                for d in pages {
                    if d & VM_PAGE_QUERY_PAGE_PRESENT != 0 { t.resident += pageSize; if d & VM_PAGE_QUERY_PAGE_DIRTY != 0 { t.dirty += pageSize } }
                    if d & VM_PAGE_QUERY_PAGE_PAGED_OUT != 0 { t.swapped += pageSize }
                }
            }
            zones.append((z.name + "_0x" + String(z.addr, radix: 16), t, 0, 0))
        }
        for (i, z) in found.enumerated() {
            var stats = malloc_statistics_t()
            if z.version >= 12, let ts = z.intro.task_statistics { ts(task, z.addr, zoneReader, &stats) }
            zones[i].count = Int(stats.blocks_in_use)
            zones[i].allocated = UInt64(stats.size_in_use)
        }
        guard !zones.isEmpty else { return "" }

        func row(_ name: String, _ t: Totals, _ count: Int, _ allocated: UInt64) -> String {
            let touched = t.dirty + t.swapped
            let frag = touched > allocated ? touched - allocated : 0
            return name.padding(toLength: 42, withPad: " ", startingAt: 0)
                + [t.virtual, t.resident, t.dirty, t.swapped].map { size($0).leftPad(10) }.joined(separator: " ")
                + String(count).leftPad(11) + size(allocated).leftPad(11) + size(frag).leftPad(11)
                + "\(pct(frag, touched))%".leftPad(8) + String(t.count).leftPad(8) + "\n"
        }
        var out = "\n" + String(repeating: " ", count: 42) + "   VIRTUAL   RESIDENT      DIRTY    SWAPPED ALLOCATION      BYTES DIRTY+SWAP          REGION\n"
        out += "MALLOC ZONE".padding(toLength: 42, withPad: " ", startingAt: 0) + "      SIZE       SIZE       SIZE       SIZE      COUNT  ALLOCATED  FRAG SIZE  % FRAG   COUNT\n"
        let rule = "===========".padding(toLength: 42, withPad: " ", startingAt: 0) + "   =======  =========  =========  =========  =========  =========  =========  ======  ======\n"
        out += rule
        var total = Totals(), count = 0, allocated: UInt64 = 0
        for z in zones.sorted(by: { $0.t.virtual > $1.t.virtual }) {
            out += row(z.name, z.t, z.count, z.allocated)
            total.add(z.t); count += z.count; allocated += z.allocated
        }
        out += rule + row("TOTAL", total, count, allocated)
        return out
    }

    /// The target zone's introspection table, as this process sees it at the same address. Checked before anything
    /// in it is called: it must lie in an image of the shared cache (libsystem_malloc, or a framework with its own
    /// zone such as AttributeGraph), which sits at the same address in every process. A zone whose code is in the
    /// app itself has nothing callable here and is skipped.
    private static func introspection(_ remote: UInt) -> malloc_introspection_t? {
        let addr = remote & ((1 << 47) - 1)   // strip arm64e pointer authentication bits
        guard addr != 0, let p = UnsafeRawPointer(bitPattern: addr) else { return nil }
        var info = Dl_info()
        guard sharedRegion.contains(UInt64(addr)), dladdr(p, &info) != 0, info.dli_fname != nil,
              let base = info.dli_fbase, sharedRegion.contains(UInt64(UInt(bitPattern: base))) else { return nil }
        return p.assumingMemoryBound(to: malloc_introspection_t.self).pointee
    }

    /// A C string in the target, read up to 256 bytes.
    private static func remoteString(_ task: mach_port_t, _ addr: UInt) -> String? {
        let a = addr & ((1 << 47) - 1)
        guard a != 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: 256)
        var got: mach_vm_size_t = 0
        guard buf.withUnsafeMutableBytes({ mach_vm_read_overwrite(task, mach_vm_address_t(a), 256, mach_vm_address_t(UInt(bitPattern: $0.baseAddress)), &got) }) == KERN_SUCCESS
            || buf.withUnsafeMutableBytes({ mach_vm_read_overwrite(task, mach_vm_address_t(a), 32, mach_vm_address_t(UInt(bitPattern: $0.baseAddress)), &got) }) == KERN_SUCCESS
        else { return nil }
        let s = String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    // MARK: Header and formatting

    static func header(_ pid: pid_t, task: mach_port_t) -> String {
        var name = [CChar](repeating: 0, count: 256)
        proc_name(pid, &name, UInt32(name.count))
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        proc_pidpath(pid, &path, UInt32(path.count))
        var out = "Process:         \(String(cString: name)) [\(pid)]\n"
        out += "Path:            \(String(cString: path))\n"
        if let p = Native.process(pid) {
            var pn = [CChar](repeating: 0, count: 256)
            proc_name(p.ppid, &pn, UInt32(pn.count))
            out += "Parent Process:  \(String(cString: pn)) [\(p.ppid)]\n"
        }
        out += "Target Type:     live task\n"
        out += "Analysis Tool:   Proc X-Ray (native, task port)\n\n"
        var ri = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &ri) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        } == 0
        if ok {
            out += "Physical footprint:         \(size(ri.ri_phys_footprint))\n"
            out += "Physical footprint (peak):  \(size(ri.ri_lifetime_max_phys_footprint))\n"
        }
        return out + "----\n"
    }

    static func cols(_ t: Totals) -> String {
        [t.virtual, t.resident, t.dirty, t.swapped, t.volatile, t.nonvol, t.empty].map { size($0).leftPad(8) }.joined(separator: " ")
            .prepending(" ") + String(t.count).leftPad(9) + " "
    }

    /// vmmap's sizes: K up to 9999K, then M, then G, one decimal.
    static func size(_ b: UInt64) -> String {
        let k = Double(b) / 1024
        if k < 10000 { return "\(Int(k.rounded()))K" }
        let m = k / 1024
        if m < 1024 { return String(format: "%.1fM", m) }
        return String(format: "%.1fG", m / 1024)
    }

    static func pct(_ a: UInt64, _ b: UInt64) -> Int { b > 0 ? Int((Double(a) * 100 / Double(b)).rounded()) : 0 }
}

/// libmalloc's memory reader. Maps the target's pages into this process (shared, made read-only) instead of
/// copying them: libmalloc asks for whole 8 MB regions to read a little metadata at their end, and a copy (vm_read)
/// faults in, and so decompresses, every page of them; a mapping only touches the pages actually read.
fileprivate func zoneReader(_ task: task_t, _ addr: vm_address_t, _ size: vm_size_t, _ out: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> kern_return_t {
    let page = UInt64(vm_kernel_page_size)
    let start = UInt64(addr) & ~(page - 1), end = (UInt64(addr) + UInt64(size) + page - 1) & ~(page - 1)
    var local: mach_vm_address_t = 0
    var cur: vm_prot_t = 0, maxp: vm_prot_t = 0
    let r = mach_vm_remap(mach_task_self_, &local, end - start, 0, VM_FLAGS_ANYWHERE, task, start, 0, &cur, &maxp, VM_INHERIT_NONE)
    guard r == KERN_SUCCESS else { return r }
    NativeVMMap.reads.append((vm_address_t(local), vm_size_t(end - start)))
    // Shared with the target: never writable from here.
    mach_vm_protect(mach_task_self_, local, end - start, 0, VM_PROT_READ)
    out?.pointee = UnsafeMutableRawPointer(bitPattern: UInt(local + (UInt64(addr) - start)))
    return KERN_SUCCESS
}

fileprivate final class RangeBox { var ranges: [vm_range_t] = [] }
fileprivate func zoneRecorder(_ task: task_t, _ ctx: UnsafeMutableRawPointer?, _ type: UInt32, _ ranges: UnsafeMutablePointer<vm_range_t>?, _ n: UInt32) {
    guard let ctx, let ranges else { return }
    Unmanaged<RangeBox>.fromOpaque(ctx).takeUnretainedValue().ranges.append(contentsOf: UnsafeBufferPointer(start: ranges, count: Int(n)))
}

private extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
    func prepending(_ s: String) -> String { s + self }
}
