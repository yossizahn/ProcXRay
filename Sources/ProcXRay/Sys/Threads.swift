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
    /// Lifetime counters per core type (PROC_PIDTHREADCOUNTS), index = perf level: 0 Performance,
    /// 1 Efficiency on Apple silicon. nil when the kernel didn't return them.
    var cores: [CoreCounts]? = nil

    var cpuNanos: UInt64 { userNanos &+ systemNanos }

    struct CoreCounts: Codable, Hashable, Sendable {
        var instructions: UInt64
        var cycles: UInt64
        /// User + system time on this core type.
        var nanos: UInt64
        var energyNJ: UInt64
    }

    var instructions: UInt64? { cores.map { $0.reduce(0) { $0 &+ $1.instructions } } }
    var cycles: UInt64? { cores.map { $0.reduce(0) { $0 &+ $1.cycles } } }
    var energyNJ: UInt64? { cores.map { $0.reduce(0) { $0 &+ $1.energyNJ } } }
    /// Instructions per cycle over the thread's life.
    var ipc: Double? {
        guard let i = instructions, let c = cycles, c > 0 else { return nil }
        return Double(i) / Double(c)
    }
    /// Share of the thread's CPU time spent on performance cores (perf level 0), 0–100.
    var perfShare: Double? {
        guard let cores, cores.count > 1 else { return nil }
        let total = cores.reduce(0) { $0 &+ $1.nanos }
        return total > 0 ? Double(cores[0].nanos) / Double(total) * 100 : nil
    }

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
    /// `PROC_PIDTHREADCOUNTS`, also private (xnu bsd/sys/proc_info_private.h): per thread ID, a 8-byte header
    /// (`ptc_len`: entries) and per perf level instructions, cycles, user and system time (mach units) and energy
    /// (nJ). Measured 2026-11-15 on this Mac: works for the user's own processes without root; Finder's main thread
    /// user+system across both levels matched pth_user_time + pth_system_time.
    private static let threadCounts: Int32 = 34
    private static let perfLevels: Int = {
        var n: Int32 = 0, size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.nperflevels", &n, &size, nil, 0) == 0 && n > 0 ? Int(min(n, 8)) : 2
    }()

    private static func counts(_ pid: pid_t, _ tid: UInt64) -> [ThreadSample.CoreCounts]? {
        let entry = 5 * MemoryLayout<UInt64>.size
        var buf = [UInt8](repeating: 0, count: 8 + perfLevels * entry)
        let got = buf.withUnsafeMutableBytes { proc_pidinfo(pid, threadCounts, tid, $0.baseAddress, Int32($0.count)) }
        guard got >= 8 else { return nil }
        return buf.withUnsafeBytes { raw -> [ThreadSample.CoreCounts]? in
            let n = min(Int(raw.loadUnaligned(as: UInt16.self)), (Int(got) - 8) / entry)
            guard n > 0 else { return nil }
            return (0..<n).map { i in
                func f(_ k: Int) -> UInt64 { raw.loadUnaligned(fromByteOffset: 8 + i * entry + k * 8, as: UInt64.self) }
                return .init(instructions: f(0), cycles: f(1), nanos: Native.machToNanos(f(2) &+ f(3)), energyNJ: f(4))
            }
        }
    }

    /// Same user as the caller, or root (the helper) for any process, kernel_task (pid 0) included: root reads its
    /// thread list and per-thread info like any other task's (measured in the VM: 192 threads, 169 named), the
    /// user gets EPERM. nil when the list can't be read.
    /// About 0.35 ms for a 67-thread process with the core counters (0.13 ms for 70 threads without them).
    static func read(_ pid: pid_t) -> ThreadSnapshot? {
        guard pid >= 0 else { return nil }
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
                                    basePriority: ti.pth_priority, maxPriority: ti.pth_maxpriority,
                                    cores: counts(pid, tid)))
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

    /// How the thread came to be, from the outermost frames of its stack (measured 2026-11-15 with a test program:
    /// a global queue runs in _dispatch_worker_thread2, a workloop and a serial queue's event source both in
    /// _dispatch_workloop_worker_thread, an idle pool thread sits in __workq_kernreturn right under _pthread_wqthread).
    /// Over this Mac's processes, the rest (2026-11-15): a thread running a Swift async task is unwound through the
    /// task's async frames, so sample starts it at completeTaskWithClosure (libswift_Concurrency) on a
    /// "….cooperative" queue; a dispatch_main() process's main thread exits and the thread left in _dispatch_sig_thread
    /// is what sample calls "Main Thread"; Go programs and stripped binaries unwind to a ??? frame in the binary.
    var kind: ThreadKind? {
        guard let root = stack.first else { return nil }
        if queue?.hasSuffix(".cooperative") == true || root.library == "libswift_Concurrency.dylib" { return .swiftConcurrency }
        let syms = stack.prefix(4).map(\.symbol)
        if syms.first == "start" || syms.contains("main") { return .main }
        if root.symbol == "_dispatch_sig_thread" { return .dispatchSignal }
        guard syms.first == "start_wqthread" else { return syms.contains("thread_start") || syms.contains("_pthread_start") ? .pthread : .other }
        // Only start_wqthread + 0: a pool thread that has run before, parked so that its next work item starts it
        // over at the entry point (measured: 1–10 ms of user time each, in 3 processes).
        if stack.count == 1 { return .gcdIdle }
        guard let i = syms.firstIndex(of: "_pthread_wqthread"), i + 1 < stack.count else { return .gcd }
        let next = stack[i + 1].symbol
        if next.hasPrefix("_dispatch_workloop_worker_thread") { return .gcdWorkloop }
        if next.hasPrefix("_dispatch_worker_thread") { return .gcdRootQueue }
        if next.hasPrefix("_dispatch_kevent_worker_thread") { return .gcdKevent }
        if next == "__workq_kernreturn" { return .gcdIdle }
        return .gcd
    }

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

enum ThreadKind: Int, Sendable {
    case main, dispatchSignal, pthread, swiftConcurrency, gcdRootQueue, gcdWorkloop, gcdKevent, gcd, gcdIdle, gcdNotRun, other

    var text: String {
        switch self {
        case .main: "Main"
        case .dispatchSignal: "GCD signal thread"
        case .pthread: "pthread"
        case .swiftConcurrency: "Swift concurrency"
        case .gcdRootQueue: "GCD global queue"
        case .gcdWorkloop: "GCD workloop"
        case .gcdKevent: "GCD kevent"
        case .gcd: "GCD"
        case .gcdIdle: "GCD idle"
        case .gcdNotRun: "GCD idle, new"
        case .other: "unknown"
        }
    }

    var help: String {
        switch self {
        case .main: "The thread the process started with."
        case .dispatchSignal: "The process called dispatch_main(): its main thread exited, and libdispatch keeps this thread (_dispatch_sig_thread) to handle signals. sample calls it the Main Thread."
        case .pthread: "Created by the process itself (pthread_create, NSThread): starts in thread_start."
        case .swiftConcurrency: "A GCD pool thread in Swift concurrency's cooperative pool (a ….cooperative queue). While it runs an async task, sample shows the task's async frames, so the stack starts at the task (completeTaskWithClosure), not at the thread's entry point."
        case .gcdRootQueue: "A GCD pool thread running blocks from a global (concurrent) queue: _dispatch_worker_thread2."
        case .gcdWorkloop: "A GCD pool thread servicing a workloop: serial queues, event sources and XPC run here (_dispatch_workloop_worker_thread)."
        case .gcdKevent: "A GCD pool thread delivering kernel events: _dispatch_kevent_worker_thread."
        case .gcd: "A GCD pool thread (start_wqthread)."
        case .gcdIdle: "A GCD pool thread parked in the kernel, waiting for work: in __workq_kernreturn, or at start_wqthread + 0 when its next work item will start it over at the entry point."
        case .gcdNotRun: "No stack and no user CPU time at capture: inferred to be a GCD pool thread the kernel created and parked before it ever ran user code (sample leaves those out)."
        case .other: "The stack doesn't reach a known thread entry point: unwinding stopped early. Typical of Go programs and binaries built without frame pointers, whose outermost frame is a ??? in the binary."
        }
    }
}

/// Thread details from one capture, by thread ID.
struct ThreadDetails: Sendable {
    var byID: [UInt64: ThreadDetail] = [:]
    var at = Date()
    /// Why stacks or QoS are missing (no helper, sample failed…), for the view to say.
    var notes: [String] = []
    /// The threads listed just before sampling, with their user CPU time then, to say why one has no stack.
    var listedUserNanos: [UInt64: UInt64] = [:]
    var hasStacks: Bool { byID.values.contains { !$0.stack.isEmpty } }
    var hasQoS: Bool { byID.values.contains { $0.effectiveQoS != nil } }

    /// The thread's kind from its stack; a thread listed at capture with no stack and 0 user time is a GCD pool
    /// thread that hasn't run yet (see noStackReason).
    func kind(_ id: UInt64) -> ThreadKind? {
        if let k = byID[id]?.kind { return k }
        return hasStacks && listedUserNanos[id] == 0 ? .gcdNotRun : nil
    }

    /// Why a thread has no stack in this capture. `sample` leaves out a thread that has never run user code
    /// (measured 2026-11-15: all 16 such threads over 40 processes had 0 ns user time, all GCD pool threads the
    /// kernel created and parked before they first returned to user space), so it has no frames to show.
    func noStackReason(_ id: UInt64) -> String {
        guard hasStacks else { return "No stack: sampling failed. Recapture to try again." }
        guard let user = listedUserNanos[id] else {
            return "No stack for this thread: it started after the last capture. Recapture to get it."
        }
        if user == 0 {
            return "No user stack yet: a GCD pool thread the kernel created that hasn't run any code (0 user time), so sample has no frames for it. It gets a stack once it runs a block."
        }
        return "No stack for this thread: sample didn't return it. Recapture to get it."
    }

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
