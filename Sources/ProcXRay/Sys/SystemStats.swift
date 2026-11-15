import Darwin
import Foundation
import IOKit
import notify

/// Whole-machine figures for the menu bar: CPU, memory, GPU, disk, network, thermal pressure, and the CPU and
/// GPU clocks. Each is one or two kernel, notify, IORegistry or IOReport calls, no privileges needed. Counters
/// are cumulative; `SystemStats.Rates` compares two readings.
struct SystemStats: Sendable {
    var at: UInt64 = DispatchTime.now().uptimeNanoseconds
    /// Per core: (user + system + nice, idle) ticks.
    var coreTicks: [(busy: UInt64, idle: UInt64)] = []
    var memory: Memory?
    /// IOAccelerator "Device Utilization %", the highest over the GPUs (0…100).
    var gpuPercent: Double?
    var gpu: GPU?
    /// The kernel's thermal pressure level (OSThermalNotification.h): 0 nominal, 1 moderate, 2 heavy,
    /// 3 trapping, 4 sleeping. What throttles the CPU before a fan or temperature would say so.
    var thermal: Int32?
    var clusters: ClusterReader.Sample?
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
        /// vm.swapusage: swap in use and the swap files' size.
        var swapUsed: UInt64?, swapTotal: UInt64?
        /// kern.memorystatus_level: the share of memory the kernel counts as available (0…100), what its
        /// pressure levels are decided from.
        var level: Int32?
    }

    /// The busiest GPU's PerformanceStatistics.
    struct GPU: Sendable, Hashable {
        /// "Renderer Utilization %" and "Tiler Utilization %" (0…100): fragment and vertex work.
        var renderer: Double?, tiler: Double?
        /// "In use system memory": unified memory the GPU's allocations hold.
        var memoryInUse: UInt64?
    }

    static func thermalLevelName(_ l: Int32) -> String {
        switch l {
        case 0: "nominal"
        case 1: "moderate"
        case 2: "heavy"
        case 3: "trapping"
        case 4: "sleeping"
        default: "level \(l)"
        }
    }

    /// Performance and efficiency cores (hw.perflevel0/1.logicalcpu); host_processor_info lists the
    /// efficiency cores first on Apple silicon.
    static let coreKinds: (performance: Int, efficiency: Int) = {
        func n(_ name: String) -> Int { var v: Int32 = 0; var sz = MemoryLayout<Int32>.size; return sysctlbyname(name, &v, &sz, nil, 0) == 0 ? Int(v) : 0 }
        return (n("hw.perflevel0.logicalcpu"), n("hw.perflevel1.logicalcpu"))
    }()

    static func read() -> SystemStats {
        var s = SystemStats()
        s.coreTicks = cpuTicks()
        s.memory = memory()
        (s.gpuPercent, s.gpu) = gpuUtilization()
        s.thermal = thermalPressure()
        s.clusters = ClusterReader.shared.read()
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
        var avail: Int32 = 0
        size = MemoryLayout<Int32>.size
        let haveLevel = sysctlbyname("kern.memorystatus_level", &avail, &size, nil, 0) == 0
        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        let haveSwap = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0
        let anon = UInt64(vm.internal_page_count), purgeable = UInt64(vm.purgeable_count)
        return Memory(total: total,
                      app: (anon > purgeable ? anon - purgeable : 0) * page,
                      wired: UInt64(vm.wire_count) * page,
                      compressed: UInt64(vm.compressor_page_count) * page,
                      cached: (UInt64(vm.external_page_count) + purgeable) * page,
                      pressure: level,
                      swapUsed: haveSwap ? swap.xsu_used : nil, swapTotal: haveSwap ? swap.xsu_total : nil,
                      level: haveLevel ? avail : nil)
    }

    /// notify(3) keeps the level as the state of "com.apple.system.thermalpressurelevel"; a registered token
    /// reads it without a message to notifyd after the first time.
    nonisolated(unsafe) private static var thermalToken: Int32 = {
        var t: Int32 = 0
        return notify_register_check(kOSThermalNotificationPressureLevelName, &t) == NOTIFY_STATUS_OK ? t : -1
    }()

    private static func thermalPressure() -> Int32? {
        guard thermalToken >= 0 else { return nil }
        var v: UInt64 = 0
        guard notify_get_state(thermalToken, &v) == NOTIFY_STATUS_OK else { return nil }
        return Int32(truncatingIfNeeded: v)
    }

    private static func gpuUtilization() -> (Double?, GPU?) {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return (nil, nil) }
        defer { IOObjectRelease(it) }
        var best: Double?, gpu: GPU?
        while case let acc = IOIteratorNext(it), acc != 0 {
            defer { IOObjectRelease(acc) }
            guard let stats = IORegistryEntryCreateCFProperty(acc, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let u = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { continue }
            guard best == nil || u > best! else { continue }
            best = u
            func n(_ k: String) -> NSNumber? { stats[k] as? NSNumber }
            gpu = GPU(renderer: n("Renderer Utilization %").map { min(100, $0.doubleValue) },
                      tiler: n("Tiler Utilization %").map { min(100, $0.doubleValue) },
                      memoryInUse: n("In use system memory").map { $0.uint64Value })
        }
        return (best.map { min(100, $0) }, gpu)
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
        var gpu: GPU?
        var memory: Memory?
        var thermal: Int32?
        var clusters: ClusterStats?
        var diskRead: Double?, diskWrite: Double?     // bytes per second
        var netIn: Double?, netOut: Double?
        var disk: Double? { diskRead.flatMap { r in diskWrite.map { r + $0 } } }
        var net: Double? { netIn.flatMap { i in netOut.map { i + $0 } } }
    }

    func rates(since a: SystemStats) -> Rates {
        var r = Rates(gpuPercent: gpuPercent, gpu: gpu, memory: memory, thermal: thermal)
        let secs = Double(at &- a.at) / 1e9
        if let x = a.clusters, let y = clusters {
            r.clusters = ClusterStats.rates(from: x, to: y, secs: secs, tables: ClusterReader.shared.tables)
        }
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
