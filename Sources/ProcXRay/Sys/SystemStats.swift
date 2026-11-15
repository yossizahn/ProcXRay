import Darwin
import Foundation
import IOKit

/// Whole-machine figures for the menu bar: CPU, memory, GPU, disk and network. Each is one or two kernel or
/// IORegistry calls, no privileges needed. Counters are cumulative; `SystemStats.Rates` compares two readings.
struct SystemStats: Sendable {
    var at: UInt64 = DispatchTime.now().uptimeNanoseconds
    /// Per core: (user + system + nice, idle) ticks.
    var coreTicks: [(busy: UInt64, idle: UInt64)] = []
    var memory: Memory?
    /// IOAccelerator "Device Utilization %", the highest over the GPUs (0…100).
    var gpuPercent: Double?
    var diskRead: UInt64?, diskWritten: UInt64?
    var netIn: UInt64?, netOut: UInt64?

    struct Memory: Sendable, Hashable {
        var total: UInt64
        /// Activity Monitor's split: app (anonymous, not purgeable), wired, compressed, and cached files.
        var app: UInt64, wired: UInt64, compressed: UInt64, cached: UInt64
        /// What Activity Monitor calls Memory Used.
        var used: UInt64 { app + wired + compressed }
        var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
        /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical.
        var pressure: Int32
    }

    static func read() -> SystemStats {
        var s = SystemStats()
        s.coreTicks = cpuTicks()
        s.memory = memory()
        s.gpuPercent = gpuUtilization()
        (s.diskRead, s.diskWritten) = diskBytes()
        (s.netIn, s.netOut) = netBytes()
        return s
    }

    // MARK: Readers

    private static func cpuTicks() -> [(busy: UInt64, idle: UInt64)] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var n: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &n) == KERN_SUCCESS, let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(n) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        return (0..<Int(count)).map { i in
            let b = i * Int(CPU_STATE_MAX)
            func t(_ k: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[b + Int(k)])) }
            return (t(CPU_STATE_USER) + t(CPU_STATE_SYSTEM) + t(CPU_STATE_NICE), t(CPU_STATE_IDLE))
        }
    }

    private static func memory() -> Memory? {
        var vm = vm_statistics64_data_t()
        var n = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &n) }
        }
        guard r == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)
        var level: Int32 = 0
        size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        let anon = UInt64(vm.internal_page_count), purgeable = UInt64(vm.purgeable_count)
        return Memory(total: total,
                      app: (anon > purgeable ? anon - purgeable : 0) * page,
                      wired: UInt64(vm.wire_count) * page,
                      compressed: UInt64(vm.compressor_page_count) * page,
                      cached: (UInt64(vm.external_page_count) + purgeable) * page,
                      pressure: level)
    }

    private static func gpuUtilization() -> Double? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var best: Double?
        while case let acc = IOIteratorNext(it), acc != 0 {
            defer { IOObjectRelease(acc) }
            guard let stats = IORegistryEntryCreateCFProperty(acc, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let u = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { continue }
            best = max(best ?? 0, u)
        }
        return best
    }

    /// Bytes read and written by every block storage driver since boot.
    private static func diskBytes() -> (UInt64?, UInt64?) {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) == KERN_SUCCESS else { return (nil, nil) }
        defer { IOObjectRelease(it) }
        var r: UInt64 = 0, w: UInt64 = 0, any = false
        while case let d = IOIteratorNext(it), d != 0 {
            defer { IOObjectRelease(d) }
            guard let stats = IORegistryEntryCreateCFProperty(d, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { continue }
            r &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            w &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            any = true
        }
        return any ? (r, w) : (nil, nil)
    }

    /// Bytes received and sent over every interface but loopback, from the 64-bit counters (NET_RT_IFLIST2:
    /// getifaddrs' if_data is 32-bit and wraps at 4 GB).
    private static func netBytes() -> (UInt64?, UInt64?) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return (nil, nil) }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return (nil, nil) }
        var i = 0, rx: UInt64 = 0, tx: UInt64 = 0
        buf.withUnsafeBytes { raw in
            while i + MemoryLayout<if_msghdr>.size <= len {
                let h = raw.loadUnaligned(fromByteOffset: i, as: if_msghdr.self)
                guard h.ifm_msglen > 0 else { break }
                if Int32(h.ifm_type) == RTM_IFINFO2, i + MemoryLayout<if_msghdr2>.size <= len {
                    let h2 = raw.loadUnaligned(fromByteOffset: i, as: if_msghdr2.self)
                    if h2.ifm_flags & IFF_LOOPBACK == 0 {
                        rx &+= h2.ifm_data.ifi_ibytes
                        tx &+= h2.ifm_data.ifi_obytes
                    }
                }
                i += Int(h.ifm_msglen)
            }
        }
        return (rx, tx)
    }

    // MARK: Rates

    struct Rates: Sendable, Hashable {
        /// Whole machine, 0…100 (all cores busy = 100).
        var cpuPercent: Double?
        var perCore: [Double] = []
        var gpuPercent: Double?
        var memory: Memory?
        var diskRead: Double?, diskWrite: Double?     // bytes per second
        var netIn: Double?, netOut: Double?
        var disk: Double? { diskRead.flatMap { r in diskWrite.map { r + $0 } } }
        var net: Double? { netIn.flatMap { i in netOut.map { i + $0 } } }
    }

    func rates(since a: SystemStats) -> Rates {
        var r = Rates(gpuPercent: gpuPercent, memory: memory)
        let secs = Double(at &- a.at) / 1e9
        if coreTicks.count == a.coreTicks.count, !coreTicks.isEmpty {
            var busy: UInt64 = 0, all: UInt64 = 0
            r.perCore = zip(a.coreTicks, coreTicks).map { x, y in
                let b = y.busy &- x.busy, i = y.idle &- x.idle
                busy &+= b; all &+= b &+ i
                return b &+ i > 0 ? Double(b) / Double(b &+ i) * 100 : 0
            }
            r.cpuPercent = all > 0 ? Double(busy) / Double(all) * 100 : nil
        }
        guard secs > 0 else { return r }
        func rate(_ x: UInt64?, _ y: UInt64?) -> Double? {
            guard let x, let y else { return nil }
            return y >= x ? Double(y - x) / secs : 0   // a counter that went back (an interface or disk went away)
        }
        r.diskRead = rate(a.diskRead, diskRead); r.diskWrite = rate(a.diskWritten, diskWritten)
        r.netIn = rate(a.netIn, netIn); r.netOut = rate(a.netOut, netOut)
        return r
    }
}
