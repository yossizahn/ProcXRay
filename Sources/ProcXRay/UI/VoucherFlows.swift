import SwiftUI

/// Who a process (or a group's members) did voucher-attributed work for, and who did it for them, over a
/// recording of the kernel's BANK settlements (BankLedger, through the helper). The breakdown behind the
/// "On behalf of other processes" totals.
struct VoucherFlowsView: View {
    @Environment(Store.self) var store
    /// The processes shown: one, or a group's members.
    let pids: Set<Int32>
    /// "this process" or "these processes", for the text.
    let subject: String

    private enum Phase { case idle, recording(until: Date), done(BankLedger.Recording, at: Date, grew: (UInt64, UInt64)?), failed(String) }
    @State private var phase = Phase.idle
    @State private var seconds = 30
    @State private var task: Task<Void, Never>?

    var body: some View {
        Card(title: "Who for, and by whom", systemImage: "person.2.wave.2") {
            VStack(alignment: .leading, spacing: 8) {
                controls
                switch phase {
                case .idle:
                    Text("Records which processes \(subject) worked for, and which worked for \(subject), from the kernel's voucher accounting. Every process is recorded, so this needs an admin user; it can't run while a syscall trace or Instruments holds the kernel trace.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                case .recording:
                    EmptyView()
                case .failed(let why):
                    Label(why, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .done(let r, let at, let grew):
                    results(r, at: at, grew: grew)
                }
            }
        }
        .onDisappear { task?.cancel() }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 8) {
            if case .recording(let until) = phase {
                ProgressView().controlSize(.small)
                Text(timerInterval: Date()...until, countsDown: true).monospacedDigit().foregroundStyle(.secondary)
                Button("Stop") { task?.cancel() }
            } else {
                Picker("", selection: $seconds) {
                    ForEach([10, 30, 60, 120], id: \.self) { Text("\($0) s").tag($0) }
                }
                .labelsHidden().fixedSize()
                Button(isDone ? "Record again" : "Record") { record() }
                    .disabled(!store.helperState.isRunning)
                if !store.helperState.isRunning {
                    Text("Needs the privileged helper.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var isDone: Bool { if case .done = phase { true } else { false } }

    private func serviced() -> (UInt64, UInt64) {
        var s: UInt64 = 0, b: UInt64 = 0
        for pid in pids { if let c = store.procs[pid]?.counters { s &+= c.servicedCpuNanos ?? 0; b &+= c.billedCpuNanos ?? 0 } }
        return (s, b)
    }

    private func record() {
        task?.cancel()
        let secs = seconds
        let before = serviced()
        phase = .recording(until: Date().addingTimeInterval(Double(secs)))
        let cancel = Shell.Cancel()
        task = Task {
            let r = await withTaskCancellationHandler {
                await Task.detached { Shell.Cancel.$current.withValue(cancel) { HelperClient.shared.bankLedger(seconds: secs) } }.value
            } onCancel: { cancel.cancel() }
            // Stop cancels the wait, not the helper's reply: a stopped recording has nothing to show.
            if Task.isCancelled { phase = .idle; return }
            switch r {
            case .success(let rec):
                let after = serviced()
                let grew = after.0 >= before.0 && after.1 >= before.1 ? (after.0 - before.0, after.1 - before.1) : nil
                phase = .done(rec, at: Date(), grew: grew)
            case .failure(let e): phase = .failed(e.message)
            }
        }
    }

    // MARK: results

    private struct Line: Identifiable {
        var pid: Int32
        var name: String
        var cpu: UInt64
        var energy: UInt64
        var count: Int
        var id: Int32 { pid }
    }

    /// Flows summed per counterparty. `forOthers`: this side did the work (merchant), else it was done for it.
    private func lines(_ r: BankLedger.Recording, forOthers: Bool) -> [Line] {
        var by: [Int32: Line] = [:]
        for f in r.flows {
            let mine = forOthers ? f.merchant : f.holder
            let other = forOthers ? f.holder : f.merchant
            // A process billed for its own work isn't "another process".
            guard pids.contains(mine), other != mine else { continue }
            var l = by[other] ?? Line(pid: other, name: forOthers ? f.holderName : f.merchantName, cpu: 0, energy: 0, count: 0)
            l.cpu &+= f.cpuNanos; l.energy &+= f.energyNJ; l.count += f.count
            by[other] = l
        }
        return by.values.filter { $0.cpu > 0 || $0.energy > 0 }.sorted { ($0.cpu, $0.energy) > ($1.cpu, $1.energy) }
    }

    @ViewBuilder private func results(_ r: BankLedger.Recording, at: Date, grew: (UInt64, UInt64)?) -> some View {
        let forOthers = lines(r, forOthers: true), byOthers = lines(r, forOthers: false)
        let energy = (forOthers + byOthers).contains { $0.energy > 0 }
        HStack(alignment: .top, spacing: 24) {
            list("Worked for", forOthers, energy: energy, empty: "No settlements of work \(subject) did for others.")
            list("Worked for \(pids.count == 1 ? "it" : "them") by", byOthers, energy: energy, empty: "No settlements of work others did for \(subject).")
        }
        let total = { (ls: [Line]) in ls.reduce(UInt64(0)) { $0 + $1.cpu } }
        Text(caption(r, at: at, grew: grew, settled: (total(forOthers), total(byOthers))))
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func caption(_ r: BankLedger.Recording, at: Date, grew: (UInt64, UInt64)?, settled: (UInt64, UInt64)) -> String {
        var s = String(format: "Settled during %.0f s, ending %@. ", r.seconds, at.formatted(date: .omitted, time: .standard))
        s += "The kernel counts an account's work when it closes, all of it at once: work done before the recording can show up here, and accounts still open at the end aren't counted yet."
        if let grew {
            s += " Over the same time the totals above grew by about \(Fmt.secs(grew.0)) for others and \(Fmt.secs(grew.1)) by others; settled: \(Fmt.secs(settled.0)) and \(Fmt.secs(settled.1))."
        }
        if r.lost > 0 { s += " The kernel's trace buffer overflowed \(r.lost) times: some settlements are missing." }
        return s
    }

    private func list(_ title: String, _ ls: [Line], energy: Bool, empty: String) -> some View {
        let total = ls.reduce(UInt64(0)) { $0 + $1.cpu }
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            if ls.isEmpty {
                Text(empty).font(.caption).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    ForEach(ls.prefix(15)) { l in
                        GridRow {
                            counterparty(l)
                            Text(Fmt.secs(l.cpu)).monospacedDigit().gridColumnAlignment(.trailing)
                            Text(total > 0 ? String(format: "%.0f %%", Double(l.cpu) / Double(total) * 100) : "")
                                .monospacedDigit().foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            if energy { Text(String(format: "%.2f J", Double(l.energy) / 1e9)).monospacedDigit().gridColumnAlignment(.trailing) }
                        }
                        .help("\(l.count) settlement\(l.count == 1 ? "" : "s")")
                    }
                }
                if ls.count > 15 { Text("and \(ls.count - 15) more").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder private func counterparty(_ l: Line) -> some View {
        if let p = store.procs[l.pid] {
            ProcessChip(proc: p)
        } else {
            // Gone by now (or never listed: an exited holder); the helper named it while it ran.
            HStack(spacing: 4) {
                Text(verbatim: l.name.isEmpty ? "pid" : l.name).strikethrough()
                Text(verbatim: "\(l.pid)").monospacedDigit().strikethrough()
            }
            .foregroundStyle(.secondary)
            .help("Exited")
        }
    }
}
