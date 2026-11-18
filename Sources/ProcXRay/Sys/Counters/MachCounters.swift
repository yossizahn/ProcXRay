import Darwin
import Foundation

/// The Mach host's statistics: no privileges needed, a handful of calls.
final class MachCounters: CounterSource {
    let kind = CounterSourceKind.mach

    private enum G: String, CaseIterable {
        case vm, cpu, percpu, expired, pset, load, extmod
        var name: String {
            switch self {
            case .vm: "Virtual memory (HOST_VM_INFO64)"
            case .cpu: "CPU time (HOST_CPU_LOAD_INFO)"
            case .percpu: "CPU time per core (PROCESSOR_CPU_LOAD_INFO)"
            case .expired: "Exited processes (HOST_EXPIRED_TASK_INFO)"
            case .pset: "Tasks and threads (PROCESSOR_SET_LOAD_INFO)"
            case .load: "Load (HOST_LOAD_INFO)"
            case .extmod: "Changes to other processes (HOST_EXTMOD_INFO64)"
            }
        }
        var note: String {
            switch self {
            case .vm: "host_statistics64(HOST_VM_INFO64): page counts (in pages of vm_kernel_page_size) and event counts since boot"
            case .cpu: "host_statistics(HOST_CPU_LOAD_INFO): time all CPUs spent in each state since boot, converted from 10 ms ticks"
            case .percpu: "host_processor_info(PROCESSOR_CPU_LOAD_INFO): the same per core (efficiency cores first on Apple silicon)"
            case .expired: "host_statistics(HOST_EXPIRED_TASK_INFO): CPU time and wakeups of every process that has exited since boot, converted from Mach ticks"
            case .pset: "processor_set_statistics(PROCESSOR_SET_LOAD_INFO) on the default processor set"
            case .load: "host_statistics(HOST_LOAD_INFO): load averages and Mach factor over 5 s, 30 s and 60 s (avenrun, mach_factor), scaled from LOAD_SCALE"
            case .extmod: "host_statistics64(HOST_EXTMOD_INFO64): how often a process got another's task port, created threads in it or set its threads' state"
            }
        }
        var id: String { "mach|\(rawValue)" }
    }

    private static let vmFields = ["free", "active", "inactive", "wired", "zero_fill", "reactivations", "pageins", "pageouts",
                                   "faults", "cow_faults", "lookups", "hits", "purges", "purgeable", "speculative",
                                   "decompressions", "compressions", "swapins", "swapouts", "compressor_pages",
                                   "throttled", "external_pages", "internal_pages", "uncompressed_pages_in_compressor"]
    private static let pageFields: Set = ["free", "active", "inactive", "wired", "purgeable", "speculative", "compressor_pages",
                                          "throttled", "external_pages", "internal_pages", "uncompressed_pages_in_compressor"]
    private static let cpuStates = ["user", "system", "idle", "nice"]
    private static let expiredFields = ["user", "system", "interrupt_wakeups", "platform_idle_wakeups"]
    private static let psetFields = ["tasks", "threads", "load_average", "mach_factor"]
    private static let loadFields = ["load_5s", "load_30s", "load_60s", "mach_factor_5s", "mach_factor_30s", "mach_factor_60s"]
    private static let extmodFields = ["task_for_pid", "task_for_pid_callers", "thread_creation", "thread_creation_callers",
                                       "thread_set_state", "thread_set_state_callers"]

    private lazy var timebase: (Double) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    func groups() -> [CounterGroup] {
        let cores = cpuTicks().count
        return G.allCases.map { g in
            func c(_ name: String, _ unit: String = "") -> CounterInfo { CounterInfo(id: "\(g.id)|\(name)", group: g.id, name: name, unit: unit) }
            let counters: [CounterInfo]
            switch g {
            case .vm: counters = Self.vmFields.map { c($0, Self.pageFields.contains($0) ? "pages" : "") }
            case .cpu: counters = Self.cpuStates.map { c($0, "ns") }
            case .percpu: counters = (0..<cores).flatMap { i in Self.cpuStates.map { c("cpu\(i).\($0)", "ns") } }
            case .expired: counters = Self.expiredFields.map { c($0, $0.hasSuffix("wakeups") ? "" : "ns") }
            case .pset: counters = Self.psetFields.map { c($0) }
            case .load: counters = Self.loadFields.map { c($0) }
            case .extmod: counters = Self.extmodFields.map { c($0) }
            }
            return CounterGroup(id: g.id, source: .mach, name: g.name, note: g.note, counters: counters)
        }
    }

    func read(_ groups: Set<String>?) -> [String: CounterValue] {
        var out: [String: CounterValue] = [:]
        for g in G.allCases where groups?.contains(g.id) ?? true {
            func put(_ name: String, _ v: CounterValue) { out["\(g.id)|\(name)"] = v }
            switch g {
            case .vm:
                guard let v = vm() else { continue }
                let vals: [UInt64] = [UInt64(v.free_count), UInt64(v.active_count), UInt64(v.inactive_count), UInt64(v.wire_count),
                                      v.zero_fill_count, v.reactivations, v.pageins, v.pageouts, v.faults, v.cow_faults, v.lookups,
                                      v.hits, v.purges, UInt64(v.purgeable_count), UInt64(v.speculative_count), v.decompressions,
                                      v.compressions, v.swapins, v.swapouts, UInt64(v.compressor_page_count), UInt64(v.throttled_count),
                                      UInt64(v.external_page_count), UInt64(v.internal_page_count), v.total_uncompressed_pages_in_compressor]
                for (n, x) in zip(Self.vmFields, vals) { put(n, .unsigned(x)) }
            case .cpu:
                var info = host_cpu_load_info_data_t()
                var n = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
                let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &n) } }
                guard r == KERN_SUCCESS else { continue }
                let t = info.cpu_ticks
                for (name, x) in zip(Self.cpuStates, [t.0, t.1, t.2, t.3]) { put(name, .unsigned(UInt64(x) * 10_000_000)) }
            case .percpu:
                for (i, t) in cpuTicks().enumerated() {
                    for (name, x) in zip(Self.cpuStates, t) { put("cpu\(i).\(name)", .unsigned(x * 10_000_000)) }
                }
            case .expired:
                var p = task_power_info()
                var n = mach_msg_type_number_t(MemoryLayout<task_power_info>.size / MemoryLayout<natural_t>.size)
                let r = withUnsafeMutablePointer(to: &p) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics(mach_host_self(), HOST_EXPIRED_TASK_INFO, $0, &n) } }
                guard r == KERN_SUCCESS else { continue }
                // Mach absolute time units (measured: a 0.4 s spin reads 10 M, ×125/3 on M1), not ns.
                put("user", .unsigned(UInt64(Double(p.total_user) * timebase)))
                put("system", .unsigned(UInt64(Double(p.total_system) * timebase)))
                put("interrupt_wakeups", .unsigned(p.task_interrupt_wakeups))
                put("platform_idle_wakeups", .unsigned(p.task_platform_idle_wakeups))
            case .pset:
                var ps = processor_set_name_t()
                guard processor_set_default(mach_host_self(), &ps) == KERN_SUCCESS else { continue }
                defer { mach_port_deallocate(mach_task_self_, ps) }
                var info = processor_set_load_info()
                var n = mach_msg_type_number_t(MemoryLayout<processor_set_load_info>.size / MemoryLayout<natural_t>.size)
                let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { processor_set_statistics(ps, PROCESSOR_SET_LOAD_INFO, $0, &n) } }
                guard r == KERN_SUCCESS else { continue }
                put("tasks", .signed(Int64(info.task_count)))
                put("threads", .signed(Int64(info.thread_count)))
                put("load_average", .double(Double(info.load_average) / Double(LOAD_SCALE)))
                put("mach_factor", .double(Double(info.mach_factor) / Double(LOAD_SCALE)))
            case .load:
                var info = host_load_info()
                var n = mach_msg_type_number_t(MemoryLayout<host_load_info>.size / MemoryLayout<integer_t>.size)
                let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics(mach_host_self(), HOST_LOAD_INFO, $0, &n) } }
                guard r == KERN_SUCCESS else { continue }
                let a = info.avenrun, m = info.mach_factor
                for (name, x) in zip(Self.loadFields, [a.0, a.1, a.2, m.0, m.1, m.2]) { put(name, .double(Double(x) / Double(LOAD_SCALE))) }
            case .extmod:
                var info = vm_extmod_statistics()
                var n = mach_msg_type_number_t(MemoryLayout<vm_extmod_statistics>.size / MemoryLayout<integer_t>.size)
                let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics64(mach_host_self(), HOST_EXTMOD_INFO64, $0, &n) } }
                guard r == KERN_SUCCESS else { continue }
                let vals = [info.task_for_pid_count, info.task_for_pid_caller_count, info.thread_creation_count,
                            info.thread_creation_caller_count, info.thread_set_state_count, info.thread_set_state_caller_count]
                for (name, x) in zip(Self.extmodFields, vals) { put(name, .signed(x)) }
            }
        }
        return out
    }

    private func vm() -> vm_statistics64? {
        var vm = vm_statistics64_data_t()
        var n = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &vm) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &n) } }
        return r == KERN_SUCCESS ? vm : nil
    }

    /// Per core: user, system, idle, nice ticks.
    private func cpuTicks() -> [[UInt64]] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var n: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &n) == KERN_SUCCESS, let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(n) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        return (0..<Int(count)).map { i in
            let b = i * Int(CPU_STATE_MAX)
            return [CPU_STATE_USER, CPU_STATE_SYSTEM, CPU_STATE_IDLE, CPU_STATE_NICE].map { UInt64(UInt32(bitPattern: info[b + Int($0)])) }
        }
    }
}
