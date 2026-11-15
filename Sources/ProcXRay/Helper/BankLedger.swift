import Darwin
import Foundation

/// Who did voucher-attributed work for whom, over a recording: the kernel's BANK settlement events, summed per
/// pair of processes. rusage's `ri_serviced_*` / `ri_billed_*` totals (Counters) have no counterparty; this is
/// the breakdown behind them.
///
/// The BANK voucher attribute keeps a ledger per {merchant, holder} pair: the merchant is the process doing the
/// work (a service that adopted its caller's voucher, usually over XPC), the holder the process it is done for.
/// When the kernel settles one (rolls the chit up to the two tasks' ledgers) it logs BANK_SETTLE_CPU_TIME and
/// BANK_SETTLE_ENERGY (class DBG_BANK 40, subclass BANK_ACCOUNT_INFO 0x10, <sys/kdebug.h>) with arg1 = merchant
/// pid, arg2 = holder pid, arg3 = the amount (mach ticks of CPU, or nanojoules). The event fires in the
/// merchant's context: measured on macOS 27.2, arg1 was the emitting process every time.
///
/// Reading the ledgers directly isn't possible: `mach_voucher_debug_info` returns KERN_NOT_SUPPORTED on release
/// kernels, even with SIP and AMFI off and a task port for the holder. These events need root only.
///
/// Settlement, not consumption: work shows up when its account is settled, which can lag the work itself.
/// kdebug has one owner system-wide, so a recording can't run alongside a syscall trace or Instruments.
enum BankLedger {
    static let classSubclass: UInt16 = 0x2810
    static let settleCPU: UInt32 = 0x2810_0004
    static let settleEnergy: UInt32 = 0x2810_000c
    /// Recordings longer than this are cut short.
    static let maxSeconds = 120
    /// Settlements come at a few thousand a second on a busy Mac: 32k events (2 MB) per read is plenty.
    private static let kernelEvents = 32 << 10

    struct Flow: Codable, Hashable, Sendable {
        /// The process that did the work.
        var merchant: Int32
        var merchantName: String
        /// The process it was done for (billed).
        var holder: Int32
        var holderName: String
        var cpuNanos: UInt64
        var energyNJ: UInt64
        /// Settlements summed.
        var count: Int
    }

    struct Recording: Codable, Sendable {
        var seconds: Double
        var flows: [Flow]
        /// Kernel buffer overflows: some settlements are missing.
        var lost: Int
        /// Settlements with a debit (arg4); kept to check how often that happens.
        var debits: Int
    }

    /// Records for `seconds` (or until `cancel` fires) and sums the settlements per pair. Needs root.
    static func record(seconds: Double, cancel: Shell.Cancel? = nil) -> Result<Recording, KdebugTrace.StartError> {
        typealias K = KdebugTrace
        if K.op(K.KERN_KDREMOVE) == nil { Kperf.reset() }
        if let e = K.op(K.KERN_KDSETBUF, Int32(kernelEvents)) { return .failure(e == EBUSY ? .refused(K.busyText()) : .failed("KDSETBUF: \(K.errText(e))")) }
        func fail(_ what: String, _ e: Int32) -> Result<Recording, KdebugTrace.StartError> {
            _ = K.op(K.KERN_KDREMOVE)
            return .failure(e == EBUSY ? .refused(K.busyText()) : .failed("\(what): \(K.errText(e))"))
        }
        if let e = K.op(K.KERN_KDSETUP) { return fail("KDSETUP", e) }
        var filter = [UInt8](repeating: 0, count: 8192)
        filter[Int(classSubclass) / 8] |= 1 << (classSubclass % 8)
        if let e = filter.withUnsafeMutableBytes({ K.input(K.KERN_KDSET_TYPEFILTER, $0.baseAddress!, $0.count) }) { return fail("typefilter", e) }
        if let e = K.op(K.KERN_KDENABLE, K.KDEBUG_ENABLE_TRACE) { return fail("KDENABLE", e) }
        defer { _ = K.op(K.KERN_KDENABLE, 0); _ = K.op(K.KERN_KDREMOVE) }

        struct Pair: Hashable { var merchant: Int32, holder: Int32 }
        var sums: [Pair: (cpu: UInt64, energy: UInt64, count: Int)] = [:]
        var names: [Int32: String] = [:]
        var lost = 0, debits = 0
        let buf = UnsafeMutableRawPointer.allocate(byteCount: kernelEvents * K.recordSize, alignment: 8)
        defer { buf.deallocate() }
        let t0 = Date()
        let limit = min(seconds, Double(maxSeconds))
        var last = false
        func name(_ pid: Int32) {
            if names[pid] == nil { names[pid] = Native.process(pid)?.comm ?? "" }
        }
        while true {
            if -t0.timeIntervalSinceNow >= limit || cancel?.isCancelled == true {
                _ = K.op(K.KERN_KDENABLE, 0)
                last = true
            } else {
                var ms = 100
                _ = K.call([CTL_KERN, KERN_KDEBUG, K.KERN_KDBUFWAIT], nil, &ms)
            }
            var n = kernelEvents
            if let e = K.call([CTL_KERN, KERN_KDEBUG, K.KERN_KDREADTR], buf, &n) { return .failure(.failed("reading the kernel trace: \(K.errText(e))")) }
            let recs = buf.bindMemory(to: K.Record.self, capacity: n)
            for i in 0..<n {
                let r = recs[i]
                if r.debugid == K.lostEvents { lost += 1; continue }
                let isCPU = r.debugid == settleCPU
                guard isCPU || r.debugid == settleEnergy else { continue }
                let p = Pair(merchant: Int32(truncatingIfNeeded: r.arg1), holder: Int32(truncatingIfNeeded: r.arg2))
                // arg3 credit, arg4 debit (xnu bank_rollup_chit_to_tasks); the task ledgers take both.
                if r.arg4 != 0 { debits += 1 }
                let amount = r.arg3 > r.arg4 ? r.arg3 - r.arg4 : 0
                var s = sums[p] ?? (0, 0, 0)
                if isCPU { s.cpu &+= amount; s.count += 1 } else { s.energy &+= amount }
                sums[p] = s
                // Named while they still exist: a short-lived holder may be gone by the end.
                name(p.merchant); name(p.holder)
            }
            if last { break }
        }
        let flows = sums.map { p, s in
            Flow(merchant: p.merchant, merchantName: names[p.merchant] ?? "", holder: p.holder, holderName: names[p.holder] ?? "",
                 cpuNanos: Native.machToNanos(s.cpu), energyNJ: s.energy, count: s.count)
        }.sorted { ($0.cpuNanos, $0.energyNJ) > ($1.cpuNanos, $1.energyNJ) }
        return .success(Recording(seconds: -t0.timeIntervalSinceNow, flows: flows, lost: lost, debits: debits))
    }
}
