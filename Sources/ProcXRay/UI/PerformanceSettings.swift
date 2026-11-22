import AppKit
import Observation
import SwiftUI

/// What Proc X-Ray itself costs right now: its own CPU, memory and wake-ups, from its rusage. Read every two
/// seconds, and only while something shows it (the Performance settings).
@MainActor
@Observable
final class SelfMeter {
    static let shared = SelfMeter()

    /// Percent of one core over the last reading interval; nil until there are two readings.
    private(set) var cpu: Double?
    private(set) var footprint: UInt64?
    /// Times a second the app woke a sleeping CPU.
    private(set) var wakeups: Double?

    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var last: (at: UInt64, cpu: UInt64, wakeups: UInt64)?

    func addViewer() {
        viewers += 1
        guard timer == nil else { return }
        last = nil
        read()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.read() } }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func removeViewer() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        timer?.invalidate()
        timer = nil
        cpu = nil; wakeups = nil
    }

    private func read() {
        guard let ru = Native.rusage(getpid()) else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let used = Native.machToNanos(ru.ri_user_time &+ ru.ri_system_time)
        let woke = ru.ri_pkg_idle_wkups &+ ru.ri_interrupt_wkups
        if let l = last, now > l.at {
            let secs = Double(now - l.at) / 1e9
            cpu = Double(used &- l.cpu) / 1e9 / secs * 100
            wakeups = Double(woke &- l.wakeups) / secs
        }
        last = (now, used, woke)
        footprint = ru.ri_phys_footprint
    }
}

/// A setting's explanation, under its control: one style for every such line in the app.
struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Settings › Performance: everything that trades freshness or detail for CPU, memory and energy (Tuning).
struct PerformanceSettings: View {
    @AppStorage(Tuning.windowInterval) private var windowInterval = 2.0
    @AppStorage(Tuning.menuBarInterval) private var menuBarInterval = 3.0
    @AppStorage(Tuning.inactive) private var inactive = Tuning.Inactive.half
    @AppStorage(Tuning.savePower) private var savePower = true
    @AppStorage(Tuning.registryEvery) private var registryEvery = 10.0
    @AppStorage(Tuning.signatures) private var signatures = true
    @AppStorage(Tuning.pidDomains) private var pidDomains = true
    @AppStorage(Tuning.historyMinutes) private var historyMinutes = 4.0
    @AppStorage(Tuning.idleEvery) private var idleEvery = 2.0

    /// Recomputed with the body: any of the values above changing redraws it.
    private var preset: Tuning.Preset { Tuning.preset }

    var body: some View {
        Form {
            SwiftUI.Section {
                Picker("Profile", selection: Binding(get: { preset }, set: { Tuning.apply($0) })) {
                    ForEach(Tuning.Preset.allCases.filter { $0 != .custom || preset == .custom }) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Hint(preset.summary)
                SelfMeterRow()
            }
            SwiftUI.Section("Refresh") {
                Picker("Process window", selection: $windowInterval) {
                    ForEach([1.0, 2, 3, 5, 10], id: \.self) { Text("every \(Int($0)) s").tag($0) }
                }
                Picker("Menu bar and alerts", selection: $menuBarInterval) {
                    ForEach([1.0, 2, 3, 5, 10], id: \.self) { Text("every \(Int($0)) s").tag($0) }
                }
                Picker("While another app is in front", selection: $inactive) {
                    ForEach(Tuning.Inactive.allCases) { Text($0.title).tag($0) }
                }
                Picker("Processes using no CPU", selection: $idleEvery) {
                    Text("read every refresh").tag(1.0)
                    Text("every 2nd refresh").tag(2.0)
                    Text("every 4th refresh").tag(4.0)
                }
                Hint("Most processes are idle. One that wakes up shows its figures at its next reading; the rest of the list stays as fresh as set above.")
                Toggle("Half as often on battery or in Low Power Mode", isOn: $savePower)
                Hint("A window that is closed, minimized or covered is never refreshed.")
            }
            SwiftUI.Section("Detail") {
                Toggle("Check code signatures", isOn: $signatures)
                Hint("Signer, team, Apple or third party. Each program is checked once. Off: no signer, and Apple code is told by its path.")
                Toggle("Name the host of extensions and XPC services (launchd pid domains)", isOn: $pidDomains)
                Hint("Runs launchctl once per program, two programs per refresh. Off: no host is shown.")
                Picker("Look up apps (LaunchServices) at most", selection: $registryEvery) {
                    ForEach([5.0, 10, 30, 60], id: \.self) { Text("every \(Int($0)) s").tag($0) }
                }
                Hint("App names, types and what an app left behind (lsappinfo), read when an app launches, quits or comes forward. ⌘R always reads it.")
                Picker("Graph history", selection: $historyMinutes) {
                    Text("None").tag(0.0)
                    ForEach([2.0, 4, 10], id: \.self) { Text("\(Int($0)) min").tag($0) }
                }
                Hint("Kept for every process, so a graph is ready when you select one: \(historyNote).")
            }
        }
        // Taller than a small screen otherwise: the form scrolls.
        .frame(height: 600)
        .formStyle(.grouped)
        .onChange(of: [windowInterval, menuBarInterval, registryEvery, historyMinutes, idleEvery]) { _, _ in Tuning.changed() }
        .onChange(of: inactive) { _, _ in Tuning.changed() }
        .onChange(of: savePower) { _, _ in Tuning.changed() }
        .onChange(of: signatures) { _, _ in Tuning.changed() }
        .onChange(of: pidDomains) { _, _ in Tuning.changed() }
    }

    /// Five lanes of 4-byte readings per process.
    private var historyNote: String {
        let perProcess = Tuning.historyLength * 5 * 4
        return perProcess == 0 ? "no memory" : Fmt.bytes(UInt64(perProcess * 1000)) + " per 1,000 processes"
    }
}

/// "Proc X-Ray now  1.2 % CPU · 132 MB · 4 wake-ups/s". Its own view, so a new reading redraws this row only: read in
/// the form's body, the meter made SwiftUI rebuild every picker of the form every two seconds, which cost more than
/// the figure it was showing.
private struct SelfMeterRow: View {
    @State private var meter = SelfMeter.shared

    var body: some View {
        LabeledContent("Proc X-Ray now") { Text(now).monospacedDigit() }
            .help("This process, as it runs with this window open: CPU over the last two seconds, memory footprint, and how often it wakes a sleeping CPU. The helper and the tools it starts are not counted.")
            .onAppear { meter.addViewer() }
            .onDisappear { meter.removeViewer() }
    }

    private var now: String {
        [meter.cpu.map { String(format: "%.1f %% CPU", $0) } ?? "… CPU", Fmt.bytes(meter.footprint),
         meter.wakeups.map { String(format: "%.0f wake-ups/s", $0) } ?? "… wake-ups/s"].joined(separator: " · ")
    }
}
