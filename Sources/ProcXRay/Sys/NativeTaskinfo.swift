import Darwin
import Foundation

/// The per-thread part of `taskinfo <pid> --threads --dq`, read straight from the target's threads (only when SIP allows task ports;
/// see NativeMach for the task port). Printed in taskinfo's layout, so ThreadDetails.mergeTaskinfo and the Raw
/// switch work unchanged. Only what the app reads is produced; taskinfo's task-wide section is not.
///
/// Sources, fitted against taskinfo on 327 threads of 120 processes on macOS 27.2, then checked on 373 threads of 120
/// other processes (every field matched on every thread):
///   - thread ID and dispatch queue: THREAD_IDENTIFIER_INFO, the queue label read through libdispatch's exported
///     `dispatch_queue_offsets` (326 of 327 agree; the other is a main thread taskinfo printed no queue for);
///   - sched mode: the time-constraint and extended policies, with THREAD_BASIC_INFO's current policy for a demoted
///     fixed-priority thread (372 of 373 on a second set before the demoted case was handled, which it now prints);
///   - QoS, darwin BG, I/O tier, latency and throughput tiers: THREAD_POLICY_STATE (private flavor 6, what taskinfo
///     reads). Its two 64-bit words are the kernel's thread policy bitfields; the bit positions below were fitted
///     against taskinfo (325–327 of 327 per field, the misses being threads whose policy changed between the reads)
///     and follow xnu's thread_effective_policy order.
enum NativeTaskinfo {
    /// thread_policy_state (osfmk/mach/thread_policy_private.h).
    private struct PolicyState {
        var requested: Int32 = 0, effective: Int32 = 0, pending: Int32 = 0, flags: Int32 = 0
        var requestedPolicy: UInt64 = 0, effectivePolicy: UInt64 = 0
        var userPromotions: UInt32 = 0, userPromotionBasepri: UInt32 = 0, ipcOverrides: UInt32 = 0, reserved32: UInt32 = 0
        var reserved: (UInt64, UInt64) = (0, 0)
    }
    private static let threadPolicyState = thread_policy_flavor_t(6)
    /// THREAD_QOS_POLICY (private flavor 9): requested tier and its relative priority.
    private static let threadQoSPolicy = thread_policy_flavor_t(9)

    static func text(_ pid: pid_t) -> String? {
        guard let task = NativeVMMap.controlPort(pid) else { return nil }
        defer { mach_port_deallocate(mach_task_self_, task) }
        var threads: thread_act_array_t?
        var n: mach_msg_type_number_t = 0
        guard task_threads(task, &threads, &n) == KERN_SUCCESS, let threads else { return nil }
        defer {
            for i in 0..<Int(n) { mach_port_deallocate(mach_task_self_, threads[i]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), vm_size_t(n) * vm_size_t(MemoryLayout<thread_act_t>.stride))
        }
        var name = [CChar](repeating: 0, count: 256)
        proc_name(pid, &name, UInt32(name.count))
        var out = "process: \"\(String(cString: name))\" [\(pid)]\n"
        out += "analysis tool: Proc X-Ray (native, task port)\n"
        out += "threads:\n"
        for i in 0..<Int(n) { out += thread(threads[i], task: task) }
        return out
    }

    private static func thread(_ th: thread_act_t, task: mach_port_t) -> String {
        var id = thread_identifier_info_data_t()
        var c = mach_msg_type_number_t(MemoryLayout<thread_identifier_info_data_t>.size / MemoryLayout<natural_t>.size)
        guard withUnsafeMutablePointer(to: &id, { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) {
            thread_info(th, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &c) } }) == KERN_SUCCESS else { return "" }
        var basic = thread_basic_info_data_t()
        c = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let haveBasic = withUnsafeMutablePointer(to: &basic) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) {
            thread_info(th, thread_flavor_t(THREAD_BASIC_INFO), $0, &c) } } == KERN_SUCCESS

        var out = "\tthread ID: 0x\(String(id.thread_id, radix: 16)) / \(id.thread_id)\n"
        if let q = queueLabel(id.dispatch_qaddr, task: task) { out += "\tdispatch queue name: \"\(q)\"\n" }
        if haveBasic {
            func secs(_ t: time_value_t) -> String { String(format: "%.6f s", Double(t.seconds) + Double(t.microseconds) / 1e6) }
            out += "\tuser/system time: \(secs(basic.user_time)) / \(secs(basic.system_time))\n"
            out += "\tCPU usage (over last tick): \(Int(basic.cpu_usage) * 100 / Int(TH_USAGE_SCALE))%\n"
            out += "\tsched mode: \(schedMode(th, policy: basic.policy))\n"
        }

        var state = PolicyState()
        c = mach_msg_type_number_t(MemoryLayout<PolicyState>.size / MemoryLayout<integer_t>.size)
        var getDefault: boolean_t = 0
        guard withUnsafeMutablePointer(to: &state, { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) {
            thread_policy_get(th, threadPolicyState, $0, &c, &getDefault) } }) == KERN_SUCCESS else { return out }
        var qos = (tier: Int32(0), relprio: Int32(0))
        c = 2
        getDefault = 0
        _ = withUnsafeMutablePointer(to: &qos) { $0.withMemoryRebound(to: integer_t.self, capacity: 2) {
            thread_policy_get(th, threadQoSPolicy, $0, &c, &getDefault) } }

        let req = state.requestedPolicy, eff = state.effectivePolicy
        func bits(_ w: UInt64, _ lo: UInt64, _ n: UInt64) -> Int { Int((w >> lo) & ((1 << n) - 1)) }
        out += "\trequested policy:\n"
        out += "\t\treq thread qos: \(qosName(bits(req, 15, 3))), relprio: \(qos.relprio)\n"
        out += "\teffective policy:\n"
        out += "\t\teff thread qos: \(qosName(bits(eff, 14, 3)))\n"
        out += "\t\teff promotion qos: \(qosName(bits(eff, 21, 3)))\n"
        out += "\t\teff latency qos: \(tierName("LATENCY_QOS_TIER", bits(eff, 8, 3)))\n"
        out += "\t\teff thruput qos: \(tierName("THROUGHPUT_QOS_TIER", bits(eff, 11, 3)))\n"
        out += "\t\teff darwin BG: \(bits(eff, 0, 1) == 1 ? "YES" : "NO")\n"
        out += "\t\teff iotier: \(ioTierName(bits(eff, 1, 2)))\n"
        return out
    }

    /// The thread's scheduling mode: realtime when it has a time-constraint policy, else fixed-priority when its
    /// extended policy turns timeshare off, else timeshare. A fixed-priority thread the scheduler has demoted runs
    /// under POLICY_TIMESHARE for now; taskinfo says so with its priorities (measured on one such thread).
    private static func schedMode(_ th: thread_act_t, policy: policy_t) -> String {
        var tc = thread_time_constraint_policy_data_t()
        var c = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        var getDefault: boolean_t = 0
        let r = withUnsafeMutablePointer(to: &tc) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) {
            thread_policy_get(th, thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, &c, &getDefault) } }
        if r == KERN_SUCCESS && getDefault == 0 { return "realtime" }
        var ext = thread_extended_policy_data_t(timeshare: 1)
        c = mach_msg_type_number_t(MemoryLayout<thread_extended_policy_data_t>.size / MemoryLayout<integer_t>.size)
        getDefault = 0
        _ = withUnsafeMutablePointer(to: &ext) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) {
            thread_policy_get(th, thread_policy_flavor_t(THREAD_EXTENDED_POLICY), $0, &c, &getDefault) } }
        guard ext.timeshare == 0 else { return "timeshare" }
        guard policy == POLICY_TIMESHARE else { return "fixed-priority" }
        var ts = policy_timeshare_info_data_t()
        c = mach_msg_type_number_t(MemoryLayout<policy_timeshare_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &ts) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) {
            thread_info(th, thread_flavor_t(THREAD_SCHED_TIMESHARE_INFO), $0, &c) } }
        return "fixed-priority demoted to policy POLICY_TIMESHARE: base priority: \(ts.base_priority) cur priority \(ts.cur_priority)"
    }

    static func qosName(_ v: Int) -> String {
        ["THREAD_QOS_UNSPECIFIED", "THREAD_QOS_MAINTENANCE", "THREAD_QOS_BACKGROUND", "THREAD_QOS_UTILITY",
         "THREAD_QOS_LEGACY", "THREAD_QOS_USER_INITIATED", "THREAD_QOS_USER_INTERACTIVE"][safe: v] ?? "THREAD_QOS_\(v)"
    }

    /// Latency and throughput tiers are stored one above their number, 0 meaning unspecified.
    static func tierName(_ prefix: String, _ v: Int) -> String { v == 0 ? "\(prefix)_UNSPECIFIED" : "\(prefix)_\(v - 1)" }

    static func ioTierName(_ v: Int) -> String {
        "THROTTLE_LEVEL_TIER\(v) (" + (["IMPORTANT", "STANDARD", "UTILITY", "THROTTLE"][safe: v] ?? "?") + ")"
    }

    // MARK: Dispatch queue labels

    /// libdispatch's published offsets into a queue object (what debuggers and taskinfo use); same library, so the
    /// same offsets as the target's.
    private struct QueueOffsets { var version: UInt16; var label: UInt16; var labelSize: UInt16 }
    private static let queueOffsets: QueueOffsets? = dlsym(dlopen(nil, RTLD_NOW), "dispatch_queue_offsets")
        .map { $0.load(as: QueueOffsets.self) }

    /// thread_identifier_info's dispatch_qaddr points at the thread's slot holding its current queue.
    private static func queueLabel(_ qaddr: UInt64, task: mach_port_t) -> String? {
        guard qaddr != 0, let o = queueOffsets, let queue = readWord(task, qaddr), queue != 0,
              let label = readWord(task, queue + UInt64(o.label)), label != 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: 128)
        var got: mach_vm_size_t = 0
        for size in [128, 32] as [mach_vm_size_t] {   // a short label near the end of a page: retry smaller
            let r = buf.withUnsafeMutableBytes { mach_vm_read_overwrite(task, label, size, mach_vm_address_t(UInt(bitPattern: $0.baseAddress)), &got) }
            if r == KERN_SUCCESS { break }
            if size == 32 { return nil }
        }
        let s = String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    private static func readWord(_ task: mach_port_t, _ addr: UInt64) -> UInt64? {
        var v: UInt64 = 0
        var got: mach_vm_size_t = 0
        let r = withUnsafeMutableBytes(of: &v) { mach_vm_read_overwrite(task, addr, 8, mach_vm_address_t(UInt(bitPattern: $0.baseAddress)), &got) }
        // Strip arm64e pointer authentication bits.
        return r == KERN_SUCCESS && got == 8 ? v & ((1 << 47) - 1) : nil
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
