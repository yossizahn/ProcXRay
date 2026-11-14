import Darwin
import Foundation

/// One thread of a process, from `proc_pidinfo(PROC_PIDTHREADID64INFO)`. Times are nanoseconds.
///
/// Left out on purpose (measured over 479 processes, 3,036 threads, 2026-11-14): `pth_sleep_time` was 0 for
/// every thread, and `pth_flags` had TH_FLAGS_SWAPPED on 98 % of them, so neither tells threads apart.
/// `pth_cpu_usage` is the scheduler's decayed estimate; CPU % is computed from `user + system` deltas instead.
struct ThreadSample: Codable, Hashable, Sendable, Identifiable {
    /// The kernel's unique thread ID: the one `sample`, `taskinfo` and the syscall trace print.
    var id: UInt64
    var name: String
    var userNanos: UInt64
    var systemNanos: UInt64
    /// TH_STATE_*: 1 running, 2 stopped, 3 waiting, 4 uninterruptible, 5 halted. One instant.
    var runState: Int32
    /// POLICY_TIMESHARE (1), POLICY_RR (2), POLICY_FIFO (4).
    var policy: Int32
    var curPriority: Int32
    var basePriority: Int32
    var maxPriority: Int32

    var cpuNanos: UInt64 { userNanos &+ systemNanos }

    var stateText: String {
        switch runState {
        case 1: "running"
        case 2: "stopped"
        case 3: "waiting"
        case 4: "uninterruptible"
        case 5: "halted"
        default: "state \(runState)"
        }
    }

    var policyText: String {
        switch policy {
        case 1: "timeshare"
        case 2: "round robin"
        case 4: "FIFO"
        default: "policy \(policy)"
        }
    }
}

/// Every thread of a process, plus its workqueue (GCD) pool counts.
struct ThreadSnapshot: Codable, Sendable {
    var threads: [ThreadSample]
    /// PROC_PIDWORKQUEUEINFO: nil for a process without a workqueue.
    var workqueue: Workqueue?
    /// When it was read, for CPU % between two snapshots.
    var at: UInt64 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)

    struct Workqueue: Codable, Sendable {
        var total: UInt32
        var running: UInt32
        var blocked: UInt32
    }
}

enum ThreadReader {
    /// `PROC_PIDLISTTHREADIDS` is not in the SDK's proc_info.h, but libproc and taskinfo use it. Unlike
    /// PROC_PIDLISTTHREADS (pthread_self addresses), it returns unique thread IDs, which match the ones in
    /// `sample`, `taskinfo` and the syscall trace (measured: Finder's main thread 11742 in all of them).
    private static let listThreadIDs: Int32 = 28

    /// Same user as the caller, or root (the helper) for any process. nil when the list can't be read.
    /// About 0.13 ms for a 70-thread process.
    static func read(_ pid: pid_t) -> ThreadSnapshot? {
        guard pid > 0 else { return nil }
        // Room for the current thread count plus some growth; read again, larger, if the list filled it.
        var capacity = Int(Native.taskInfo(pid)?.pti_threadnum ?? 0) + 64
        var ids: [UInt64] = []
        for _ in 0..<4 {
            var buf = [UInt64](repeating: 0, count: capacity)
            let got = buf.withUnsafeMutableBytes { proc_pidinfo(pid, listThreadIDs, 0, $0.baseAddress, Int32($0.count)) }
            guard got > 0 else { return nil }
            let n = Int(got) / MemoryLayout<UInt64>.size
            if n < capacity { ids = Array(buf[..<n]); break }
            capacity *= 2
        }
        guard !ids.isEmpty else { return nil }

        var out: [ThreadSample] = []
        out.reserveCapacity(ids.count)
        let size = Int32(MemoryLayout<proc_threadinfo>.size)
        for tid in ids {
            var ti = proc_threadinfo()
            // A thread that exited since the list was read fails here; it is simply not shown.
            guard proc_pidinfo(pid, PROC_PIDTHREADID64INFO, tid, &ti, size) == size else { continue }
            let name = withUnsafeBytes(of: ti.pth_name) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            out.append(ThreadSample(id: tid, name: name, userNanos: ti.pth_user_time, systemNanos: ti.pth_system_time,
                                    runState: ti.pth_run_state, policy: ti.pth_policy, curPriority: ti.pth_curpri,
                                    basePriority: ti.pth_priority, maxPriority: ti.pth_maxpriority))
        }
        var wq = proc_workqueueinfo()
        let wqSize = Int32(MemoryLayout<proc_workqueueinfo>.size)
        let workqueue = proc_pidinfo(pid, PROC_PIDWORKQUEUEINFO, 0, &wq, wqSize) == wqSize
            ? ThreadSnapshot.Workqueue(total: wq.pwq_nthreads, running: wq.pwq_runthreads, blocked: wq.pwq_blockedthreads)
            : nil
        return ThreadSnapshot(threads: out, workqueue: workqueue)
    }
}

// MARK: - Stacks and QoS (snapshots, not live)

/// One frame of a sampled stack, outermost first.
struct StackFrame: Hashable, Sendable {
    var symbol: String
    var library: String?
}

/// What a one-sample `sample` run and `taskinfo --threads --dq` say about one thread.
struct ThreadDetail: Sendable {
    /// Outermost frame first; the last one is where the thread was when sampled.
    var stack: [StackFrame] = []
    /// The dispatch queue the thread was running a block for, if any (sample, else taskinfo).
    var queue: String?
    // taskinfo, root only.
    var requestedQoS: String?
    var effectiveQoS: String?
    var promotionQoS: String?
    var schedMode: String?
    var darwinBG: Bool?
    var ioTier: String?

    /// The innermost frame: for a waiting thread, the trap it is blocked in (mach_msg2_trap, __psynch_cvwait…).
    var leaf: StackFrame? { stack.last }

    /// The innermost frame outside the syscall and pthread wrappers: what the wait is for
    /// (__CFRunLoopServiceMachPort, _dispatch_workloop_worker_thread, a condition variable's owner…).
    var caller: StackFrame? {
        stack.dropLast().last { f in !(f.library.map(ThreadDetail.plumbing.contains) ?? false) }
    }
    static let plumbing: Set<String> = ["libsystem_kernel.dylib", "libsystem_pthread.dylib", "libsystem_platform.dylib",
                                        "libsystem_c.dylib", "libsystem_malloc.dylib"]
}

/// Thread details from one capture, by thread ID.
struct ThreadDetails: Sendable {
    var byID: [UInt64: ThreadDetail] = [:]
    var at = Date()
    /// Why stacks or QoS are missing (no helper, sample failed…), for the view to say.
    var notes: [String] = []
    var hasStacks: Bool { byID.values.contains { !$0.stack.isEmpty } }
    var hasQoS: Bool { byID.values.contains { $0.effectiveQoS != nil } }

    /// `sample <pid> 0 1`: each thread is one chain. With more samples the heaviest path is taken.
    mutating func mergeSample(_ text: String) {
        for t in SampleParser.parse(text).threads {
            // "Thread_11742   DispatchQueue_1: com.apple.main-thread  (serial)" or "Thread_11849: com.apple.NSEventThread"
            guard let id = Self.threadID(t.symbol) else { continue }
            var d = byID[id] ?? ThreadDetail()
            if let r = t.symbol.range(of: #"DispatchQueue_\d+: "#, options: .regularExpression) {
                var q = String(t.symbol[r.upperBound...])
                if let paren = q.range(of: "  (", options: .backwards) { q = String(q[..<paren.lowerBound]) }
                d.queue = q.trimmingCharacters(in: .whitespaces)
            }
            var frames: [StackFrame] = []
            var n = t.children.max { $0.count < $1.count }
            while let node = n {
                frames.append(StackFrame(symbol: node.symbol, library: node.library))
                n = node.children.max { $0.count < $1.count }
            }
            d.stack = frames
            byID[id] = d
        }
    }

    private static func threadID(_ header: String) -> UInt64? {
        guard let r = header.range(of: #"Thread_\d+"#, options: .regularExpression) else { return nil }
        return UInt64(header[r].dropFirst("Thread_".count))
    }

    /// `taskinfo <pid> --threads --dq`: per-thread blocks after the "threads:" line, each starting
    /// "thread ID: 0x2dde / 11742".
    mutating func mergeTaskinfo(_ text: String) {
        var inThreads = false
        var id: UInt64?
        var d = ThreadDetail()
        func flush() { if let id { var m = byID[id] ?? ThreadDetail(); m.absorbPolicy(d); byID[id] = m } }
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !inThreads { inThreads = line == "threads:"; continue }
            func value(_ key: String) -> String? {
                line.hasPrefix(key) ? line.dropFirst(key.count).trimmingCharacters(in: .whitespaces) : nil
            }
            if let v = value("thread ID:") {
                flush()
                id = v.split(separator: "/").last.flatMap { UInt64($0.trimmingCharacters(in: .whitespaces)) }
                d = ThreadDetail()
            } else if let v = value("dispatch queue name:") {
                d.queue = v.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if let v = value("req thread qos:") {
                d.requestedQoS = Self.qos(v)
            } else if let v = value("eff thread qos:") {
                d.effectiveQoS = Self.qos(v)
            } else if let v = value("eff promotion qos:") {
                d.promotionQoS = Self.qos(v)
            } else if let v = value("sched mode:") {
                d.schedMode = v
            } else if let v = value("eff darwin BG:") {
                d.darwinBG = v.hasPrefix("YES")
            } else if let v = value("eff iotier:") {
                // "THROTTLE_LEVEL_TIER0 (IMPORTANT)" → "IMPORTANT"
                d.ioTier = v.split(separator: "(").last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ") ")).capitalized }
            }
        }
        flush()
    }

    /// "THREAD_QOS_USER_INITIATED, relprio: 0" → "User initiated"; nil for UNSPECIFIED.
    static func qos(_ v: String) -> String? {
        let name = v.split(separator: ",").first.map(String.init) ?? v
        switch name {
        case "THREAD_QOS_USER_INTERACTIVE": return "User interactive"
        case "THREAD_QOS_USER_INITIATED": return "User initiated"
        case "THREAD_QOS_LEGACY", "THREAD_QOS_DEFAULT": return "Default"   // xnu: LEGACY is the Default class
        case "THREAD_QOS_UTILITY": return "Utility"
        case "THREAD_QOS_BACKGROUND": return "Background"
        case "THREAD_QOS_MAINTENANCE": return "Maintenance"
        default: return nil
        }
    }
}

private extension ThreadDetail {
    mutating func absorbPolicy(_ d: ThreadDetail) {
        if queue == nil { queue = d.queue }
        requestedQoS = d.requestedQoS; effectiveQoS = d.effectiveQoS; promotionQoS = d.promotionQoS
        schedMode = d.schedMode; darwinBG = d.darwinBG; ioTier = d.ioTier
    }
}
