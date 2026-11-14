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
