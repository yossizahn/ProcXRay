import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt

/// Reads the snapshot makes only while a column that shows them is visible (Column.reads). Costs measured
/// over ~760 processes: open files 1.6 ms, nice 1.0 ms, compressed memory 2.6 ms (own processes), power
/// assertions 1.2 ms and GPU time 2.4 ms (one call each for every process).
struct ExtraReads: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let openFiles = ExtraReads(rawValue: 1)
    static let nice = ExtraReads(rawValue: 2)
    static let assertions = ExtraReads(rawValue: 4)
    static let gpu = ExtraReads(rawValue: 8)
    static let compressed = ExtraReads(rawValue: 16)
    static let network = ExtraReads(rawValue: 64)
    /// What the helper can read for other users' processes. (A Mach port count was tried and dropped: even
    /// root got a task inspect port for 13 of 727 processes, and asking cost the helper ~11 ms per refresh.)
    static let viaHelper: ExtraReads = [.openFiles, .nice, .compressed]
}

enum ExtraRead {
    /// Open file descriptors (PROC_PIDLISTFDS). Same user, or root.
    static func openFiles(_ pid: pid_t) -> Int? {
        // Asked with no buffer, the kernel answers with room for the table's size, not the count in use.
        let need = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard need > 0 else { return nil }
        let n = Int(need) / MemoryLayout<proc_fdinfo>.size + 16
        var buf = [proc_fdinfo](repeating: proc_fdinfo(), count: n)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &buf, Int32(n * MemoryLayout<proc_fdinfo>.size))
        return got > 0 ? Int(got) / MemoryLayout<proc_fdinfo>.size : nil
    }

    /// Nice value (proc_bsdinfo). Same user, or root.
    static func nice(_ pid: pid_t) -> Int32? {
        var b = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &b, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return nil }
        return b.pbi_nice
    }

    /// Compressed memory (TASK_VM_INFO through a task *name* port, which the kernel gives for the user's
    /// own processes; root gets it for all).
    static func compressed(_ pid: pid_t) -> UInt64? {
        var t: mach_port_t = 0
        guard task_name_for_pid(mach_task_self_, pid, &t) == KERN_SUCCESS else { return nil }
        defer { mach_port_deallocate(mach_task_self_, t) }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(t, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return r == KERN_SUCCESS ? info.compressed : nil
    }

    /// Power assertion types held, per pid (IOPMCopyAssertionsByProcess). Only holders are listed.
    static func assertionsByPid() -> [pid_t: [String]] {
        var d: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&d) == kIOReturnSuccess,
              let dict = d?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [:] }
        var out: [pid_t: [String]] = [:]
        for (pid, list) in dict {
            out[pid.int32Value] = list.compactMap { $0["AssertType"] as? String }
        }
        return out
    }

    /// GPU time per pid, in nanoseconds: the sum of `accumulatedGPUTime` over the process's IOAccelerator
    /// user clients (IORegistry, readable without privileges; what Activity Monitor's GPU Time is built on).
    static func gpuNanosByPid() -> [pid_t: UInt64] {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(it) }
        var out: [pid_t: UInt64] = [:]
        while case let acc = IOIteratorNext(it), acc != 0 {
            defer { IOObjectRelease(acc) }
            var kids: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(acc, kIOServicePlane, &kids) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(kids) }
            while case let c = IOIteratorNext(kids), c != 0 {
                defer { IOObjectRelease(c) }
                // "pid 672, WindowServer"
                guard let creator = IORegistryEntryCreateCFProperty(c, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? String,
                      creator.hasPrefix("pid "),
                      let pid = pid_t(creator.dropFirst(4).prefix { $0.isNumber }),
                      let usage = IORegistryEntryCreateCFProperty(c, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? [[String: Any]] else { continue }
                let ns = usage.reduce(UInt64(0)) { $0 &+ (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
                out[pid, default: 0] &+= ns
            }
        }
        return out
    }

    /// The assertion types that keep the Mac awake, by what they keep awake.
    static func preventing(_ types: [String]) -> String? {
        let system: Set = ["PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion", "DenySystemSleep"]
        let display: Set = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]
        let s = types.contains(where: system.contains), d = types.contains(where: display.contains)
        return s && d ? "system, display" : s ? "system" : d ? "display" : nil
    }
}

/// Per-process network throughput from `nettop`. nettop spends ~5 s starting up whatever it is asked, and
/// holds its output back when writing to a pipe, so it can't be streamed: while a network column is shown,
/// one-sample runs follow each other in the background, and rates come from consecutive runs (a reading every
/// ~5 s). It sees every user's sockets without the helper. Its counts cover the sockets open at each run, so a
/// connection that closed between runs drops out; a falling count is shown as no traffic, not negative.
final class NetSampler: @unchecked Sendable {
    static let shared = NetSampler()
    struct Rate: Sendable { var inPerSec: Double; var outPerSec: Double }

    private let lock = NSLock()
    private var wanted = false
    private var running = false
    private var last: (at: Date, bytes: [pid_t: (UInt64, UInt64)])?
    private var rates: [pid_t: Rate] = [:]

    /// Called by every snapshot: starts the loop when wanted, lets it stop when not.
    func want(_ on: Bool) {
        lock.lock()
        wanted = on
        let start = on && !running
        if start { running = true }
        if !on { last = nil; rates = [:]; compared = false }
        lock.unlock()
        if start { DispatchQueue.global(qos: .utility).async { self.loop() } }
    }

    /// nil until two samples have been compared; then every process nettop listed. A process it didn't list
    /// had no sockets open, so it gets no entry and counts as no traffic.
    func current() -> [pid_t: Rate]? { lock.lock(); defer { lock.unlock() }; return compared ? rates : nil }
    private var compared = false

    private func loop() {
        while true {
            lock.lock()
            guard wanted else { running = false; lock.unlock(); return }
            lock.unlock()
            let out = Shell.run("/usr/bin/nettop", ["-P", "-x", "-L", "1", "-J", "bytes_in,bytes_out"], mergeStderr: false, timeout: 20)
            let now = Date()
            let bytes = Self.parse(out)
            lock.lock()
            if let prev = last, wanted {
                let secs = now.timeIntervalSince(prev.at)
                var r: [pid_t: Rate] = [:]
                for (pid, (i, o)) in bytes {
                    guard let (pi, po) = prev.bytes[pid], secs > 0 else { continue }
                    r[pid] = Rate(inPerSec: Double(i > pi ? i - pi : 0) / secs, outPerSec: Double(o > po ? o - po : 0) / secs)
                }
                rates = r
                compared = true
            }
            if wanted { last = (now, bytes) }
            lock.unlock()
            if bytes.isEmpty { Thread.sleep(forTimeInterval: 5) }   // nettop failed: don't spin
        }
    }

    /// "launchd.1,0,0," → pid 1: (0, 0). Some runs put a time column first ("19:54:22.701153,launchd.1,0,0,"),
    /// so the process is the first field that ends in ".<pid>" and is followed by two counts. The name may
    /// contain dots; the pid follows the last.
    static func parse(_ text: String) -> [pid_t: (UInt64, UInt64)] {
        var out: [pid_t: (UInt64, UInt64)] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            for k in 0..<max(0, f.count - 2) {
                guard let dot = f[k].lastIndex(of: "."), let pid = pid_t(f[k][f[k].index(after: dot)...]),
                      let i = UInt64(f[k + 1]), let o = UInt64(f[k + 2]) else { continue }
                out[pid] = (i, o)
                break
            }
        }
        return out
    }
}
