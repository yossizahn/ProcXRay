import Darwin
import Foundation

/// What task_info gives through a task *name* port beyond proc_pidinfo and rusage: the audit token, changes made
/// to the task from outside, its suspend count and its memory broken down. A name port is the user's own processes,
/// or any as root (the helper); measured on macOS 27.2 for Finder as its user and WindowServer as root.
struct TaskDetail: Codable, Equatable, Sendable {
    var token: AuditToken?
    var extmod: TaskExtmod?
    var basic: TaskBasic?
    var vm: TaskVMBreakdown?

    /// nil when no name port could be had (another user's process without root, or gone). `full`: everything;
    /// else the token alone (what the helper gives a caller who may not inspect the process).
    static func read(_ pid: pid_t, full: Bool = true) -> TaskDetail? {
        guard pid > 0 else { return nil }
        var t: mach_port_t = 0
        guard task_name_for_pid(mach_task_self_, pid, &t) == KERN_SUCCESS else { return nil }
        defer { mach_port_deallocate(mach_task_self_, t) }
        // The pid was reused between the lookup and now: someone else's details.
        guard let token = LoginSessions.token(task: t).map(AuditToken.init), token.pid == pid else { return nil }
        var d = TaskDetail(token: token)
        guard full else { return d }
        d.extmod = TaskExtmod.read(t)
        d.basic = TaskBasic.read(t)
        d.vm = TaskVMBreakdown.read(t)
        return d
    }

    /// task_info into a struct of type T; nil on failure. Returns how many words the kernel filled.
    static func info<T>(_ t: mach_port_t, _ flavor: Int32, _ value: inout T) -> mach_msg_type_number_t? {
        var count = mach_msg_type_number_t(MemoryLayout<T>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &value) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(t, task_flavor_t(flavor), $0, &count) }
        }
        return r == KERN_SUCCESS ? count : nil
    }
}

/// TASK_EXTMOD_INFO: the task's UUID (its main executable's LC_UUID, not a per-run id), and how often other processes reached into it (and it into others): took its
/// task port, created threads in it, set its threads' registers. What debuggers and injectors do; 0 on Finder and
/// WindowServer, measured. task_for_pid and a remote thread_create on a sleep in the VM counted 1 each.
struct TaskExtmod: Codable, Equatable, Sendable {
    var uuid: String
    /// task_for_pid on this task by others / by this task on others.
    var taskPortLookups: Int64
    var taskPortLookupsMade: Int64
    var threadsCreatedFromOutside: Int64
    var threadsCreatedElsewhere: Int64
    var threadStateSets: Int64
    var threadStateSetsMade: Int64

    static func read(_ t: mach_port_t) -> TaskExtmod? {
        var i = task_extmod_info_data_t()
        guard TaskDetail.info(t, TASK_EXTMOD_INFO, &i) != nil else { return nil }
        let uuid = withUnsafeBytes(of: i.task_uuid) { UUID(uuid: $0.load(as: uuid_t.self)).uuidString }
        let s = i.extmod_statistics
        return TaskExtmod(uuid: uuid, taskPortLookups: s.task_for_pid_count, taskPortLookupsMade: s.task_for_pid_caller_count,
                          threadsCreatedFromOutside: s.thread_creation_count, threadsCreatedElsewhere: s.thread_creation_caller_count,
                          threadStateSets: s.thread_set_state_count, threadStateSetsMade: s.thread_set_state_caller_count)
    }

    var anyFromOutside: Bool { taskPortLookups + threadsCreatedFromOutside + threadStateSets > 0 }
}

/// MACH_TASK_BASIC_INFO: the fields proc_taskinfo lacks.
struct TaskBasic: Codable, Equatable, Sendable {
    /// task_suspend calls not yet resumed (RunningBoard, a debugger). Not SIGSTOP, which is p_stat's "stopped".
    var suspendCount: Int32
    /// Most memory resident at once.
    var residentMax: UInt64

    static func read(_ t: mach_port_t) -> TaskBasic? {
        var i = mach_task_basic_info_data_t()
        guard TaskDetail.info(t, MACH_TASK_BASIC_INFO, &i) != nil else { return nil }
        return TaskBasic(suspendCount: i.suspend_count, residentMax: i.resident_size_max)
    }

    /// The suspend count alone, for the State column (ExtraReads.suspended). ~2 µs.
    static func suspendCount(_ pid: pid_t) -> Int32? {
        guard pid > 0 else { return nil }
        var t: mach_port_t = 0
        guard task_name_for_pid(mach_task_self_, pid, &t) == KERN_SUCCESS else { return nil }
        defer { mach_port_deallocate(mach_task_self_, t) }
        return read(t)?.suspendCount
    }
}

/// TASK_VM_INFO, all of it (the Compressed column reads one field): where the footprint is, and the kernel's
/// per-tag ledgers. Bytes; the ledgers are signed in the kernel and kept that way.
struct TaskVMBreakdown: Codable, Equatable, Sendable {
    var footprint: UInt64
    var footprintPeak: Int64
    var resident: UInt64
    var residentPeak: UInt64
    var `internal`: UInt64
    var internalPeak: UInt64
    var external: UInt64
    var externalPeak: UInt64
    var reusable: UInt64
    var reusablePeak: UInt64
    var device: UInt64
    var compressed: UInt64
    var compressedPeak: UInt64
    var compressedLifetime: UInt64
    var purgeableVolatileResident: UInt64
    var purgeableVolatileVirtual: UInt64
    var purgeableNonvolatile: Int64
    var purgeableVolatileLedger: Int64
    /// Footprint by owner tag: (footprint, of which compressed). Network is counted as nonvolatile.
    var network: Int64, networkCompressed: Int64
    var media: Int64, mediaCompressed: Int64
    var graphics: Int64, graphicsCompressed: Int64
    var neural: Int64, neuralCompressed: Int64
    /// Memory with those tags the footprint doesn't count.
    var mediaNoFootprint: Int64, graphicsNoFootprint: Int64, neuralNoFootprint: Int64
    /// 0 when the process has no limit (the kernel reports 0 then).
    var limitRemaining: UInt64
    var decompressions: Int32
    /// Bytes read back from swap (ledger_swapins).
    var swapins: Int64
    var regionCount: Int32
    var pageSize: Int32

    static func read(_ t: mach_port_t) -> TaskVMBreakdown? {
        var v = task_vm_info_data_t()
        guard TaskDetail.info(t, TASK_VM_INFO, &v) != nil else { return nil }
        return TaskVMBreakdown(
            footprint: v.phys_footprint, footprintPeak: v.ledger_phys_footprint_peak,
            resident: v.resident_size, residentPeak: v.resident_size_peak,
            internal: v.internal, internalPeak: v.internal_peak, external: v.external, externalPeak: v.external_peak,
            reusable: v.reusable, reusablePeak: v.reusable_peak, device: v.device,
            compressed: v.compressed, compressedPeak: v.compressed_peak, compressedLifetime: v.compressed_lifetime,
            purgeableVolatileResident: v.purgeable_volatile_resident, purgeableVolatileVirtual: v.purgeable_volatile_virtual,
            purgeableNonvolatile: v.ledger_purgeable_nonvolatile, purgeableVolatileLedger: v.ledger_purgeable_volatile,
            network: v.ledger_tag_network_nonvolatile, networkCompressed: v.ledger_tag_network_nonvolatile_compressed,
            media: v.ledger_tag_media_footprint, mediaCompressed: v.ledger_tag_media_footprint_compressed,
            graphics: v.ledger_tag_graphics_footprint, graphicsCompressed: v.ledger_tag_graphics_footprint_compressed,
            neural: v.ledger_tag_neural_footprint, neuralCompressed: v.ledger_tag_neural_footprint_compressed,
            mediaNoFootprint: v.ledger_tag_media_nofootprint, graphicsNoFootprint: v.ledger_tag_graphics_nofootprint,
            neuralNoFootprint: v.ledger_tag_neural_nofootprint,
            limitRemaining: v.limit_bytes_remaining, decompressions: v.decompressions, swapins: v.ledger_swapins,
            regionCount: v.region_count, pageSize: v.page_size)
    }
}
