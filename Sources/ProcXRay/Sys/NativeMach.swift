import Darwin
import Foundation

/// `lsmp -a -j` read straight from the kernel. With SIP's task_for_pid protection relaxed, root gets a read port
/// for every task (measured: 647 of 649 on macOS 27.2, against 13 inspect ports of 727 with SIP on), so the helper
/// can walk every port space itself instead of running lsmp and parsing ~18 MB of JSON.
///
/// Produces lsmp's per-process records (same keys and value formats) so `MachSnapshot.parseWithPorts(processes:)`
/// pairs them exactly as it pairs lsmp's.
enum NativeMach {
    /// Every readable process's record, or nil when task ports aren't available (SIP on, or not root).
    static func processes() -> [[String: Any]]? {
        guard getuid() == 0, SystemSecurity.current.allows(.taskForPid) else { return nil }
        var out: [[String: Any]] = []
        for pid in allPids() where pid > 0 {
            var task: mach_port_t = 0
            guard let readFor = taskReadForPid, readFor(mach_task_self_, pid, &task) == KERN_SUCCESS else { continue }
            defer { mach_port_deallocate(mach_task_self_, task) }
            if let p = process(pid, task: task) { out.append(p) }
        }
        return out.isEmpty ? nil : out
    }

    /// task_read_for_pid is exported by libsystem_kernel but not declared to Swift.
    private typealias TaskForPidFn = @convention(c) (mach_port_t, pid_t, UnsafeMutablePointer<mach_port_t>) -> kern_return_t
    private static let taskReadForPid: TaskForPidFn? = dlsym(dlopen(nil, RTLD_NOW), "task_read_for_pid").map { unsafeBitCast($0, to: TaskForPidFn.self) }

    static func allPids() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(got, 0))))
    }

    // MACH_PORT_TYPE_* (mach/port.h): rights are bits 16… of iin_type; the request bits sit at the top.
    private static let typeSend: UInt32 = 1 << 16, typeReceive: UInt32 = 1 << 17, typeSendOnce: UInt32 = 1 << 18
    private static let typePortSet: UInt32 = 1 << 19, typeDeadName: UInt32 = 1 << 20
    private static let typeDNRequest: UInt32 = 0x8000_0000

    static func process(_ pid: pid_t, task: mach_port_t) -> [String: Any]? {
        var space = ipc_info_space_t()
        var table: ipc_info_name_array_t?
        var tableCount: mach_msg_type_number_t = 0
        var tree: ipc_info_tree_name_array_t?
        var treeCount: mach_msg_type_number_t = 0
        guard mach_port_space_info(task, &space, &table, &tableCount, &tree, &treeCount) == KERN_SUCCESS, let table else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: table)), vm_size_t(tableCount) * vm_size_t(MemoryLayout<ipc_info_name_t>.stride))
            if let tree { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: tree)), vm_size_t(treeCount) * vm_size_t(MemoryLayout<ipc_info_tree_name_t>.stride)) }
        }
        var ports: [[String: Any]] = []
        ports.reserveCapacity(Int(tableCount))
        var send = 0, receive = 0, sendOnce = 0, sets = 0, dead = 0, dnRequests = 0, vouchers = 0
        for i in 0..<Int(tableCount) {
            let e = table[i]
            let t = e.iin_type
            guard t & (typeSend | typeReceive | typeSendOnce | typePortSet | typeDeadName) != 0 else { continue }
            var q: [String: Any] = ["name": hex8(e.iin_name), "ipc-object": hex8(e.iin_object)]
            var rights: [String] = []
            if t & typeReceive != 0 { rights.append("recv"); receive += 1 }
            if t & typeSend != 0 { rights.append("send"); send += 1 }
            if t & typeSendOnce != 0 { rights.append("send once"); sendOnce += 1 }
            q["rights"] = rights
            var notes: [String] = []
            if t & typeDNRequest != 0 { notes.append("dead name"); dnRequests += 1 }
            if t & typePortSet != 0 {
                q["type"] = "port set"; sets += 1
            } else if t & typeDeadName != 0 {
                q["type"] = "dead name"; dead += 1
                q["send_rights"] = Int(e.iin_urefs)
            } else if t & typeReceive != 0 {
                q["type"] = "port"
                // lsmp puts this entry's own send references here; MachPortDetail.totalSendRights means every
                // holder's, which is the kernel's mps_srights below.
                q["send_rights"] = 0
                var ext = mach_port_info_ext_t()
                var count = mach_msg_type_number_t(MemoryLayout<mach_port_info_ext_t>.size / MemoryLayout<natural_t>.size)
                let r = withUnsafeMutablePointer(to: &ext) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                        mach_port_get_attributes(task, e.iin_name, MACH_PORT_INFO_EXT, $0, &count)
                    }
                }
                if r == KERN_SUCCESS {
                    let s = ext.mpie_status
                    q["msg_count"] = Int(s.mps_msgcount)
                    q["queue_limit"] = Int(s.mps_qlimit)
                    q["send_rights"] = Int(s.mps_srights)
                    q["boosts"] = Int(ext.mpie_boost_cnt)
                    q["port_status_flags"] = statusFlags(s.mps_flags)
                    if s.mps_nsrequest != 0 { notes.append("no sender") }
                    if s.mps_pdrequest != 0 { notes.append("port destroy request") }
                }
            } else {
                // A send or send-once right only: to a kernel object, or to a port another task receives on.
                q["send_rights"] = Int(e.iin_urefs)
                // Read as a plain number: IPC_OTYPE_* imports as a closed Swift enum, and a newer kernel may
                // return a value it doesn't list.
                var kotype: UInt32 = 0
                var kaddr: mach_vm_address_t = 0
                var desc = [CChar](repeating: 0, count: 512)   // kobject_description_t
                let r = withUnsafeMutablePointer(to: &kotype) {
                    $0.withMemoryRebound(to: ipc_info_object_type_t.self, capacity: 1) {
                        mach_port_kobject_description(task, e.iin_name, $0, &kaddr, &desc)
                    }
                }
                if r == KERN_SUCCESS, kotype != 0 {
                    let name = kobjectName(kotype)
                    q["type"] = name
                    if name == "VOUCHER" { vouchers += 1 }
                    let d = String(cString: desc)
                    if !d.isEmpty { q["description"] = d }
                } else {
                    q["type"] = "UNKNOWN"
                }
            }
            q["notifications"] = notes
            ports.append(q)
        }
        var p: [String: Any] = ["pid": Int(pid), "ports": ports, "total": ports.count, "send_rights": send,
                                "receive_rights": receive, "send_once_rights": sendOnce, "port_sets": sets,
                                "dead_names": dead, "dead_name requests": dnRequests, "vouchers": vouchers]
        p["exception_ports"] = exceptionPorts(task)
        return p
    }

    /// lsmp's "0x%08x".
    static func hex8(_ v: UInt32) -> String {
        let s = String(v, radix: 16)
        return "0x" + String(repeating: "0", count: max(0, 8 - s.count)) + s
    }

    /// MACH_PORT_STATUS_FLAG_* (mach/port.h), named as lsmp names them.
    static func statusFlags(_ f: natural_t) -> [String] {
        let names: [(natural_t, String)] = [(0x01, "temp owner"), (0x02, "guarded"), (0x04, "strict guard"),
                                            (0x08, "imp donation"), (0x10, "revive"), (0x20, "taskptr"),
                                            (0x40, "guard immovable receive"), (0x80, "no grant")]
        return names.filter { f & $0.0 != 0 }.map(\.1)
    }

    /// Task exception ports: the kernel object of each port (lsmp's `port_object`) and the kinds it takes.
    static func exceptionPorts(_ task: mach_port_t) -> [[String: Any]] {
        let max = Int(EXC_TYPES_COUNT)
        var masks = [exception_mask_t](repeating: 0, count: max)
        var infos = [ipc_info_port_t](repeating: ipc_info_port_t(), count: max)
        var behaviors = [exception_behavior_t](repeating: 0, count: max)
        var flavors = [thread_state_flavor_t](repeating: 0, count: max)
        var count = mach_msg_type_number_t(max)
        guard task_get_exception_ports_info(task, allExceptions, &masks, &count, &infos, &behaviors, &flavors) == KERN_SUCCESS else { return [] }
        return (0..<Int(count)).compactMap { i in
            guard infos[i].iip_port_object != 0 else { return nil }
            return ["port_object": hex8(infos[i].iip_port_object), "receiver_object": hex8(infos[i].iip_receiver_object),
                    "mask": exceptionMask(masks[i])]
        }
    }

    /// EXC_MASK_ALL (a macro Swift doesn't import); EXC_MASK_MACHINE is 0 on arm64.
    private static let allExceptions = exception_mask_t(EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION | EXC_MASK_ARITHMETIC |
        EXC_MASK_EMULATION | EXC_MASK_SOFTWARE | EXC_MASK_BREAKPOINT | EXC_MASK_SYSCALL | EXC_MASK_MACH_SYSCALL |
        EXC_MASK_RPC_ALERT | EXC_MASK_RESOURCE | EXC_MASK_GUARD)

    /// " BAD_ACCESS RESOURCE": lsmp's format, each name with a leading space.
    static func exceptionMask(_ m: exception_mask_t) -> String {
        let names = ["", "BAD_ACCESS", "BAD_INSTRUCTION", "ARITHMETIC", "EMULATION", "SOFTWARE", "BREAKPOINT", "SYSCALL",
                     "MACH_SYSCALL", "RPC_ALERT", "CRASH", "RESOURCE", "GUARD", "CORPSE_NOTIFY"]
        return (1..<names.count).filter { m & (1 << $0) != 0 }.map { " " + names[$0] }.joined()
    }

    /// Kernel object type (the SDK's stable IPC_OTYPE_* numbering, mach_debug/ipc_info.h) → lsmp's name for it.
    /// lsmp mixes hyphens and underscores; the names it printed on macOS 27.2 are copied as they are.
    /// IPC_OTYPE_UNKNOWN (~0) is what the kernel returns for an ordinary port: lsmp's "UNKNOWN".
    static func kobjectName(_ t: UInt32) -> String { t == .max ? "UNKNOWN" : kobjectNames[t] ?? "KOBJECT-\(t)" }
    static let kobjectNames: [UInt32: String] = [
        1: "THREAD-CONTROL", 2: "TASK-CONTROL", 3: "HOST", 4: "HOST-PRIV", 5: "PROCESSOR", 6: "PSET", 7: "PSET-NAME",
        8: "TIMER", 11: "MEMORY-OBJECT", 15: "UND-REPLY", 19: "MAIN-DEVICE", 20: "TASK-NAME", 23: "SEMAPHORE",
        25: "CLOCK", 27: "IOKIT-IDENT", 28: "NAMED-MEMORY", 29: "IOKIT-CONNECT", 30: "IOKIT-OBJECT", 33: "SESSIONPORT",
        34: "FILEPORT", 36: "TASK-RESUME", 37: "VOUCHER", 39: "WORK_INTERVAL", 40: "UX_HANDLER", 41: "UEXT_OBJECT",
        42: "ARCADE_REG", 43: "EVENTLINK", 44: "TASK-INSPECT", 45: "TASK-READ", 46: "THREAD-INSPECT", 47: "THREAD-READ",
        49: "HYPERVISOR", 50: "TASK_ID_TOKEN", 51: "TASK_FATAL", 52: "KCDATA", 53: "EXCLAVES_RESOURCE", 54: "THREAD_RESUME"]
}
