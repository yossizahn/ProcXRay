import AppKit
import ServiceManagement
import SwiftUI

/// Dock icon or not. "Menu bar only" runs as an accessory app (no Dock icon, not in ⌘-Tab) while no window is
/// open; opening one makes it a regular app until the last one closes, so the window gets the app's menus.
@MainActor
enum AppActivation {
    private static var observers: [NSObjectProtocol] = []

    static func install() {
        let names: [Notification.Name] = [NSWindow.willCloseNotification, NSWindow.didBecomeKeyNotification]
        observers = names.map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { update() } }
            }
        }
        update()
    }

    /// Call before opening a window from the menu bar, so it opens as a regular app's window.
    static func willShowWindow() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    static func update() {
        let want: NSApplication.ActivationPolicy
        if AmbientPrefs.showInValue == .menuBar {
            let open = NSApp.windows.contains { $0.styleMask.contains(.titled) && $0.isVisible }
            want = open ? .regular : .accessory
        } else {
            want = .regular
        }
        if NSApp.activationPolicy() != want { NSApp.setActivationPolicy(want) }
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            MenuBarSettings().tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            AlertSettings().tabItem { Label("Alerts", systemImage: "exclamationmark.triangle") }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @AppStorage(AmbientPrefs.showIn) private var showIn: AmbientPrefs.ShowIn = .both
    @AppStorage(AmbientPrefs.interval) private var interval = 3.0
    @State private var loginItem = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Picker("Show Proc X-Ray in", selection: $showIn) {
                ForEach(AmbientPrefs.ShowIn.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: showIn) { _, _ in AppActivation.update(); AmbientMonitor.shared.update() }
            Text(showIn == .dock ? "No menu bar item, and nothing is sampled while the window is closed."
                 : showIn == .menuBar ? "No Dock icon while no window is open. Closing the last window keeps Proc X-Ray running in the menu bar."
                 : "Closing the last window keeps Proc X-Ray running in the menu bar.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Open at login", isOn: $loginItem)
                .onChange(of: loginItem) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                        loginItem = SMAppService.mainApp.status == .enabled
                    }
                }
            if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            Picker("Menu bar sampling", selection: $interval) {
                ForEach([1.0, 2, 3, 5, 10], id: \.self) { Text("every \(Int($0)) s").tag($0) }
            }
            .onChange(of: interval) { _, _ in AmbientMonitor.shared.update() }
            Text("How often the menu bar, its popover and the alerts read the system. Each reading costs ~9 ms of CPU (about 0.3 % of one core at every 3 s). The process window refreshes on its own schedule, and only while it's on screen.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct MenuBarSettings: View {
    @AppStorage(AmbientPrefs.widgets) private var widgets = "cpu,memory"
    @AppStorage(AmbientPrefs.widgetGraphs) private var graphs = true
    @AppStorage(AmbientPrefs.widgetColors) private var colors = true
    @State private var monitor = AmbientMonitor.shared

    private func binding(_ m: AmbientMetric) -> Binding<Bool> {
        Binding(get: { widgets.split(separator: ",").contains(Substring(m.rawValue)) }, set: { on in
            let current = Set(widgets.split(separator: ",").map(String.init))
            let next = on ? current.union([m.rawValue]) : current.subtracting([m.rawValue])
            widgets = AmbientMetric.allCases.map(\.rawValue).filter(next.contains).joined(separator: ",")
        })
    }

    var body: some View {
        Form {
            SwiftUI.Section("Widgets") {
                ForEach(AmbientMetric.allCases) { m in Toggle(m.title, isOn: binding(m)) }
                Toggle("Graphs", isOn: $graphs)
                Toggle("Colored graphs", isOn: $colors).disabled(!graphs)
                Text("CPU green, GPU purple, memory blue (orange under memory pressure, red when critical). Disk and network: read and received in blue above the middle, written and sent in red below. Off: one color, like the menu bar's icons.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Preview") {
                HStack {
                    Spacer()
                    let list = widgets.split(separator: ",").compactMap { AmbientMetric(rawValue: String($0)) }
                    if list.isEmpty {
                        Image(systemName: "waveform.path.ecg")
                    } else {
                        MenuBarWidgets(metrics: list, alert: monitor.attentionCount > 0, graphs: graphs, system: monitor.system,
                                       history: monitor.systemHistory, io: monitor.ioHistory, ink: .primary, colored: colors && graphs)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
                Text("With no widget, the menu bar shows an icon. A warning sign comes first while an alert is live.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AlertSettings: View {
    @AppStorage(AmbientPrefs.alertsOn) private var on = true
    @AppStorage(AmbientPrefs.cpu) private var cpu = 80.0
    @AppStorage(AmbientPrefs.gpu) private var gpu = 60.0
    @AppStorage(AmbientPrefs.diskMB) private var disk = 50.0
    @AppStorage(AmbientPrefs.netMB) private var net = 10.0
    @AppStorage(AmbientPrefs.seconds) private var seconds = 30.0
    @AppStorage(AmbientPrefs.unresponsive) private var unresponsive = true
    @AppStorage(AmbientPrefs.system) private var system = true
    @AppStorage(AmbientPrefs.ignore) private var ignore = ""
    @AppStorage(AmbientPrefs.keepMinutes) private var keep = 10.0
    @AppStorage(AmbientPrefs.thirdPartyOnly) private var thirdPartyOnly = true

    var body: some View {
        Form {
            SwiftUI.Section {
                Toggle("Alert on sustained usage", isOn: $on)
                Text("A process that stays at or above a threshold for the set time shows under Needs Attention in the menu bar popover and the Triage section, and the menu bar shows a warning sign. One reading below doesn't end an alert; two in a row do.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Thresholds") {
                number("CPU", $cpu, unit: "% of one core", range: 10...1600, step: 10)
                number("GPU", $gpu, unit: "%", range: 5...100, step: 5)
                number("Disk", $disk, unit: "MB/s read + written", range: 1...5000, step: 10)
                number("Network", $net, unit: "MB/s received + sent", range: 0.1...1000, step: 1)
                Picker("For at least", selection: $seconds) {
                    ForEach([10.0, 20, 30, 60, 120, 300], id: \.self) { Text(duration($0)).tag($0) }
                }
                Toggle("Apps that stop responding", isOn: $unresponsive)
                Text("WindowServer decides when an app is hung (Activity Monitor's \"Not Responding\"), after about 15–20 s without handling events; the alert follows at once.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Thermal and memory pressure", isOn: $system)
                Text("Shown while macOS throttles the CPU to keep cool (thermal pressure moderate or higher) or memory runs short (memory pressure warning or critical), with no wait.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!on)
            SwiftUI.Section("Ignore") {
                TextField("Process names, comma-separated", text: $ignore, prompt: Text("e.g. Xcode, clang, mds_stores"))
                Text("Matched without case against the app name or the executable's file name.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!on)
            SwiftUI.Section("Lists") {
                Picker("Keep ended alerts, launches and exits", selection: $keep) {
                    ForEach([2.0, 5, 10, 30, 60], id: \.self) { Text("\(Int($0)) min").tag($0) }
                }
                Toggle("Just Launched and Recently Ended: third-party processes only", isOn: $thirdPartyOnly)
                Text("Leaves out Apple's processes (by path: /System, /usr, /bin, /sbin, /Library/Apple), which come and go by the dozen every minute.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func number(_ title: String, _ v: Binding<Double>, unit: String, range: ClosedRange<Double>, step: Double) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: v, format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden().multilineTextAlignment(.trailing).frame(width: 70)
                Stepper(title, value: v, in: range, step: step).labelsHidden()
                Text(unit).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
            }
        }
    }
}
