import Darwin
import Foundation

/// `sample <pid> 0 1` (one sample of every thread's stack) read from the target's task port (only when SIP allows task ports; see
/// NativeMach). Printed in sample's call-graph layout, so SampleParser, ThreadDetails.mergeSample and the Raw switch
/// work unchanged.
///
/// Each thread's stack: its registers (thread_get_state) and the frame-pointer chain read out of its stack, the
/// target suspended meanwhile (as sample does), pointer-authentication bits stripped. Symbols come from
/// CoreSymbolication, the private framework sample, spindump and Instruments symbolicate with.
enum NativeSample {
    static func text(_ pid: pid_t) -> String? {
        guard let task = NativeVMMap.controlPort(pid) else { return nil }
        defer { mach_port_deallocate(mach_task_self_, task) }
        let t0 = Date()
        guard let stacks = capture(task) else { return nil }
        let sym = Symbolicator(task: task)
        var name = [CChar](repeating: 0, count: 256)
        proc_name(pid, &name, UInt32(name.count))
        var out = "Analysis of sampling \(String(cString: name)) (pid \(pid)) every 1 millisecond\n"
        out += "Analysis Tool: Proc X-Ray (native, task port)\n"
        out += "Call graph:\n"
        let sorted = stacks.sorted(by: { $0.id < $1.id })
        for (i, s) in sorted.enumerated() {
            out += "    1 \(s.header)\n"
            // Outermost frame first, each one level deeper; sample draws "+" while another thread follows.
            let glyph = i < sorted.count - 1 ? "+" : " "
            for (depth, addr) in s.frames.reversed().enumerated() {
                let pad = String(repeating: "  ", count: depth)
                out += "    \(glyph) \(pad)1 \(sym.describe(addr, isReturn: depth < s.frames.count - 1))\n"
            }
        }
        out += String(format: "\n(native task-port read in %.0f ms)\n", -t0.timeIntervalSinceNow * 1000)
        return out
    }

    struct Stack {
        var id: UInt64
        var header: String
        /// Innermost first: the pc, then return addresses.
        var frames: [UInt64]
    }

    /// Every thread's stack, read with the target suspended.
    static func capture(_ task: mach_port_t) -> [Stack]? {
        var token: task_suspension_token_t = 0
        guard task_suspend2(task, &token) == KERN_SUCCESS else { return nil }
        defer { task_resume2(token) }
        var threads: thread_act_array_t?
        var n: mach_msg_type_number_t = 0
        guard task_threads(task, &threads, &n) == KERN_SUCCESS, let threads else { return nil }
        defer {
            for i in 0..<Int(n) { mach_port_deallocate(mach_task_self_, threads[i]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), vm_size_t(n) * vm_size_t(MemoryLayout<thread_act_t>.stride))
        }
        // task_threads lists threads in creation order: the first is the process's main thread.
        return (0..<Int(n)).compactMap { stack(threads[$0], task: task, isMain: $0 == 0) }
    }

    static let addressMask: UInt64 = (1 << 47) - 1

    private static func stack(_ th: thread_act_t, task: mach_port_t, isMain: Bool) -> Stack? {
        var id = thread_identifier_info_data_t()
        var c = mach_msg_type_number_t(MemoryLayout<thread_identifier_info_data_t>.size / MemoryLayout<natural_t>.size)
        guard withUnsafeMutablePointer(to: &id, { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) {
            thread_info(th, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &c) } }) == KERN_SUCCESS else { return nil }
        var st = arm_thread_state64_t()
        c = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        guard withUnsafeMutablePointer(to: &st, { $0.withMemoryRebound(to: natural_t.self, capacity: Int(c)) {
            thread_get_state(th, ARM_THREAD_STATE64, $0, &c) } }) == KERN_SUCCESS else { return nil }
        let pc = st.__pc & addressMask, lr = st.__lr & addressMask
        var frames = [pc]
        var returns: [UInt64] = []
        var fp = st.__fp & addressMask
        var seen: Set<UInt64> = []
        while fp != 0, fp & 7 == 0, returns.count < 512, seen.insert(fp).inserted {
            var pair = (UInt64(0), UInt64(0))
            var got: mach_vm_size_t = 0
            guard withUnsafeMutableBytes(of: &pair, { mach_vm_read_overwrite(task, fp, 16, mach_vm_address_t(UInt(bitPattern: $0.baseAddress)), &got) }) == KERN_SUCCESS else { break }
            let ret = pair.1 & addressMask
            guard ret != 0 else { break }
            returns.append(ret)
            let next = pair.0 & addressMask
            guard next > fp else { break }   // stacks grow down: callers' frames are at higher addresses
            fp = next
        }
        // A leaf function (one that calls nothing, such as a syscall trap) saves no frame: its caller is only in lr.
        // sample sometimes leaves this frame out: of 154 workqueue threads parked in __workq_kernreturn it showed
        // _pthread_wqthread for 114 and dropped it for 40 (start_wqthread → __workq_kernreturn, a call that doesn't
        // exist). The frame is real, so it is always kept here.
        if lr != 0, lr != pc, returns.first != lr { frames.append(lr) }
        frames += returns
        return Stack(id: id.thread_id, header: header(th, id: id, task: task, isMain: isMain), frames: frames)
    }

    // MARK: Thread header

    private struct QueueOffsets {
        var version: UInt16, label: UInt16, labelSize: UInt16, flags: UInt16, flagsSize: UInt16
        var serialnum: UInt16, serialnumSize: UInt16, width: UInt16, widthSize: UInt16
    }
    private static let queueOffsets: QueueOffsets? = dlsym(dlopen(nil, RTLD_NOW), "dispatch_queue_offsets")
        .map { $0.load(as: QueueOffsets.self) }

    /// "Thread_2647   DispatchQueue_1: com.apple.main-thread  (serial)", "Thread_2747: com.apple.dock.animation"
    /// (the thread's name), or "Thread_119509". A main thread not on a queue (a daemon parked in dispatch_main) is
    /// "Thread_1900: Main Thread   DispatchQueue_<multiple>", as sample prints it (65 of 65 such threads measured).
    private static func header(_ th: thread_act_t, id: thread_identifier_info_data_t, task: mach_port_t, isMain: Bool) -> String {
        var h = "Thread_\(id.thread_id)"
        if id.dispatch_qaddr != 0, let o = queueOffsets, let q = readWord(task, id.dispatch_qaddr), q != 0,
           let labelPtr = readWord(task, q + UInt64(o.label)), let full = readString(task, labelPtr) {
            let label = String(full.prefix(126))   // sample cuts queue labels at 126 characters
            let serial = readWord(task, q + UInt64(o.serialnum)).map { $0 & (o.serialnumSize == 4 ? 0xFFFF_FFFF : .max) } ?? 0
            let width = readWord(task, q + UInt64(o.width)).map { $0 & (o.widthSize == 2 ? 0xFFFF : o.widthSize == 4 ? 0xFFFF_FFFF : .max) } ?? 1
            return h + "   DispatchQueue_\(serial): \(label)  (\(width > 1 ? "concurrent" : "serial"))"
        }
        if isMain { return h + ": Main Thread   DispatchQueue_<multiple>" }
        var ext = thread_extended_info_data_t()
        var c = mach_msg_type_number_t(MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<natural_t>.size)
        if withUnsafeMutablePointer(to: &ext, { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) {
            thread_info(th, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &c) } }) == KERN_SUCCESS {
            let name = withUnsafeBytes(of: ext.pth_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            if !name.isEmpty { h += ": \(name)" }
        }
        return h
    }

    static func readWord(_ task: mach_port_t, _ addr: UInt64) -> UInt64? {
        var v: UInt64 = 0
        var got: mach_vm_size_t = 0
        let r = withUnsafeMutableBytes(of: &v) { mach_vm_read_overwrite(task, addr & addressMask, 8, mach_vm_address_t(UInt(bitPattern: $0.baseAddress)), &got) }
        return r == KERN_SUCCESS ? v & addressMask : nil
    }

    static func readString(_ task: mach_port_t, _ addr: UInt64) -> String? {
        var buf = [UInt8](repeating: 0, count: 128)
        var got: mach_vm_size_t = 0
        for size in [128, 32] as [mach_vm_size_t] {
            if buf.withUnsafeMutableBytes({ mach_vm_read_overwrite(task, addr & addressMask, size, mach_vm_address_t(UInt(bitPattern: $0.baseAddress)), &got) }) == KERN_SUCCESS {
                let s = String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
                return s.isEmpty ? nil : s
            }
        }
        return nil
    }

    // MARK: Symbols

    /// CoreSymbolication, through dlsym. Its handles (CSTypeRef) are a 16-byte struct of two pointers, passed and
    /// returned by value; vm_range_t (two 64-bit integers) has the same size and register assignment on arm64, so
    /// it stands in for one in these function types. CSRange is { location, length }: vm_range_t's layout too.
    final class Symbolicator {
        private typealias Ref = vm_range_t
        private typealias CreateFn = @convention(c) (task_t) -> Ref
        private typealias AtTimeFn = @convention(c) (Ref, mach_vm_address_t, UInt64) -> Ref
        private typealias NameFn = @convention(c) (Ref) -> UnsafePointer<CChar>?
        private typealias RangeFn = @convention(c) (Ref) -> vm_range_t
        private typealias BaseFn = @convention(c) (Ref) -> mach_vm_address_t
        private typealias ReleaseFn = @convention(c) (Ref) -> Void

        private static let lib = dlopen("/System/Library/PrivateFrameworks/CoreSymbolication.framework/CoreSymbolication", RTLD_NOW)
        private static func fn<T>(_ name: String, _: T.Type) -> T? { dlsym(lib, name).map { unsafeBitCast($0, to: T.self) } }
        private static let create = fn("CSSymbolicatorCreateWithTask", CreateFn.self)
        private static let symbolAt = fn("CSSymbolicatorGetSymbolWithAddressAtTime", AtTimeFn.self)
        private static let ownerAt = fn("CSSymbolicatorGetSymbolOwnerWithAddressAtTime", AtTimeFn.self)
        private static let symbolName = fn("CSSymbolGetName", NameFn.self)
        private static let symbolRange = fn("CSSymbolGetRange", RangeFn.self)
        private static let ownerName = fn("CSSymbolOwnerGetName", NameFn.self)
        private static let ownerBase = fn("CSSymbolOwnerGetBaseAddress", BaseFn.self)
        private static let release = fn("CSRelease", ReleaseFn.self)
        /// kCSNow: the target as it is now.
        private static let now: UInt64 = 0x8000_0000_0000_0000

        private let ref: Ref?
        private var cache: [UInt64: String] = [:]

        init(task: mach_port_t) {
            let r = Self.create?(task)
            ref = r.flatMap { $0.address == 0 && $0.size == 0 ? nil : $0 }
        }
        deinit { if let ref { Self.release?(ref) } }

        /// sample's frame text. A return address is looked up one byte back (the call instruction, which a
        /// call at the very end of a function would otherwise put in the next one) but printed as it is.
        func describe(_ addr: UInt64, isReturn: Bool) -> String {
            if let c = cache[addr] { return c }
            let look = isReturn && addr > 0 ? addr - 1 : addr
            var s = "???  [0x\(String(addr, radix: 16))]"
            if let ref, let symbolAt = Self.symbolAt, let ownerAt = Self.ownerAt {
                let owner = ownerAt(ref, look, Self.now)
                let lib = owner.address == 0 && owner.size == 0 ? nil : Self.ownerName?(owner).map { String(cString: $0) }
                let sym = symbolAt(ref, look, Self.now)
                if sym.address != 0 || sym.size != 0, let n = Self.symbolName?(sym), let range = Self.symbolRange?(sym) {
                    s = "\(String(cString: n))  (in \(lib ?? "???")) + \(addr - UInt64(range.address))  [0x\(String(addr, radix: 16))]"
                } else if let lib {
                    let base = Self.ownerBase?(owner) ?? 0
                    s = "???  (in \(lib))  load address 0x\(String(base, radix: 16)) + 0x\(String(addr - base, radix: 16))  [0x\(String(addr, radix: 16))]"
                }
            }
            cache[addr] = s
            return s
        }
    }
}
