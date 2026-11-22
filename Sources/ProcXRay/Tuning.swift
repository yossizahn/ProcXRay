import AppKit
import Foundation
import IOKit.ps

/// Every setting that trades freshness or detail for CPU, memory or energy, in one place: the Settings window's
/// Performance tab binds these keys, and the samplers ask here how often to run and what to read. Anything that
/// costs something to keep up to date gets a key here rather than a constant where it is used.
///
/// The effective cadence also follows what the app can see for itself: nothing is read for a window that is off
/// screen (Store.onScreen), and an app in the background or a Mac on battery reads less often when the settings
/// say so.
enum Tuning {
    // MARK: Keys

    static let windowInterval = "perf.windowInterval"        // seconds between process list refreshes
    static let menuBarInterval = AmbientPrefs.interval       // seconds between menu bar readings
    static let inactive = "perf.inactive"                    // Inactive raw value
    static let savePower = "perf.savePower"                  // read half as often on battery or in Low Power Mode
    static let registryEvery = "perf.registryEvery"          // least seconds between LaunchServices reads
    static let signatures = "perf.signatures"                // check code signatures in the background
    static let pidDomains = "perf.pidDomains"                // read launchd pid domains (one launchctl per process)
    static let historyMinutes = "perf.historyMinutes"        // graph history kept per process; 0: none
    static let idleEvery = "perf.idleEvery"                  // a process using no CPU is read every Nth refresh
    static let menuBarProcesses = "perf.menuBarProcesses"    // popover closed: processes are read every Nth reading

    /// What the process window does while another app is in front.
    enum Inactive: String, CaseIterable, Identifiable, Sendable {
        case same, half, slow, pause
        var id: String { rawValue }
        var title: String {
            switch self {
            case .same: "Keep refreshing as usual"
            case .half: "Refresh half as often"
            case .slow: "Refresh every 10 s"
            case .pause: "Stop refreshing"
            }
        }
    }

    /// A set of values for every key. `custom` is whatever doesn't match one of the three.
    enum Preset: String, CaseIterable, Identifiable, Sendable {
        case efficient, balanced, live, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .efficient: "Efficient"
            case .balanced: "Balanced"
            case .live: "Live"
            case .custom: "Custom"
            }
        }
        var summary: String {
            switch self {
            case .efficient: "Reads every 5 s, least when in the background. For leaving it open all day."
            case .balanced: "Reads every 2 s, half as often in the background or on battery."
            case .live: "Reads every second, wherever the window is. For watching something closely."
            case .custom: "Your own mix of the settings below."
            }
        }
        /// The keys' values, nil for custom.
        var values: [String: Any]? {
            switch self {
            case .efficient:
                [windowInterval: 5.0, menuBarInterval: 5.0, inactive: Inactive.slow.rawValue, savePower: true,
                 registryEvery: 60.0, signatures: true, pidDomains: false, historyMinutes: 2.0, idleEvery: 4.0, menuBarProcesses: 4.0]
            case .balanced:
                [windowInterval: 2.0, menuBarInterval: 3.0, inactive: Inactive.half.rawValue, savePower: true,
                 registryEvery: 10.0, signatures: true, pidDomains: true, historyMinutes: 4.0, idleEvery: 2.0, menuBarProcesses: 2.0]
            case .live:
                [windowInterval: 1.0, menuBarInterval: 2.0, inactive: Inactive.same.rawValue, savePower: false,
                 registryEvery: 5.0, signatures: true, pidDomains: true, historyMinutes: 10.0, idleEvery: 1.0, menuBarProcesses: 1.0]
            case .custom: nil
            }
        }
    }

    static func register() {
        UserDefaults.standard.register(defaults: Preset.balanced.values!)
    }

    /// The preset the stored values match.
    static var preset: Preset {
        let d = UserDefaults.standard
        return Preset.allCases.first { p in
            p.values?.allSatisfy { k, v in (d.object(forKey: k) as? NSObject) == (v as? NSObject) } ?? false
        } ?? .custom
    }

    static func apply(_ p: Preset) {
        guard let v = p.values else { return }
        for (k, x) in v { UserDefaults.standard.set(x, forKey: k) }
        changed()
    }

    // MARK: Values

    private static var d: UserDefaults { .standard }
    static var checksSignatures: Bool { d.bool(forKey: signatures) }
    static var readsPidDomains: Bool { d.bool(forKey: pidDomains) }
    static var registrySpacing: TimeInterval { max(2, d.double(forKey: registryEvery)) }
    static var inactiveMode: Inactive { Inactive(rawValue: d.string(forKey: inactive) ?? "") ?? .half }
    /// A process that used no CPU at its last reading is read again every this many refreshes (1: every one).
    static var idleReadEvery: Int { min(8, max(1, Int(d.double(forKey: idleEvery)))) }
    /// While the popover is closed and Triage isn't showing, the menu bar monitor reads the processes on every
    /// this many readings and only the system's totals on the others.
    static var menuBarProcessEvery: Int { min(8, max(1, Int(d.double(forKey: menuBarProcesses)))) }

    /// Readings kept per process for the graphs, at the window's own interval. 0: none are kept.
    static var historyLength: Int {
        let minutes = d.double(forKey: historyMinutes)
        guard minutes > 0 else { return 0 }
        return min(600, max(10, Int(minutes * 60 / max(1, d.double(forKey: windowInterval)))))
    }

    /// Seconds between process list refreshes now, nil to stop: the setting, stretched while another app is in
    /// front and on battery.
    @MainActor
    static func windowIntervalNow(active: Bool) -> TimeInterval? {
        var s = max(0.5, d.double(forKey: windowInterval))
        if !active {
            switch inactiveMode {
            case .same: break
            case .half: s *= 2
            case .slow: s = max(s, 10)
            case .pause: return nil
            }
        }
        return s * powerFactor
    }

    /// Seconds between menu bar readings now.
    @MainActor
    static var menuBarIntervalNow: TimeInterval { max(1, d.double(forKey: menuBarInterval)) * powerFactor }

    /// 2 while saving power applies: the setting is on and the Mac runs on battery or in Low Power Mode.
    @MainActor
    static var powerFactor: Double { d.bool(forKey: savePower) && Power.saving ? 2 : 1 }

    // MARK: Changes

    /// Posted when a value here or the power state changes: the samplers reschedule.
    static let didChange = Notification.Name("ProcXRay.tuningChanged")
    static func changed() { NotificationCenter.default.post(name: didChange, object: nil) }
}

/// How often per-process network traffic is read: as often as the fastest thing showing it. The process window
/// while it refreshes, else the menu bar monitor's readings of the processes, else once a minute to keep the
/// totals moving.
@MainActor
enum NetPace {
    /// Seconds between the process window's refreshes while it refreshes, nil while it doesn't (Store.schedule).
    static var window: Double? { didSet { update() } }

    /// Call when what decides the pace changes: the window's refreshing, the monitor's interval, the popover.
    static func update() {
        let m = AmbientMonitor.shared
        var pace = 60.0
        if m.running { pace = min(pace, Tuning.menuBarIntervalNow * Double(m.popover.live ? 1 : Tuning.menuBarProcessEvery)) }
        if let w = window, w > 0 { pace = min(pace, w) }
        NetSampler.shared.setPace(pace)
    }
}

/// Whether the Mac is on battery or in Low Power Mode, kept up to date by notifications (no polling).
@MainActor
enum Power {
    private(set) static var saving = false
    private static var installed = false
    private static var source: CFRunLoopSource?

    static func install() {
        guard !installed else { return }
        installed = true
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { update() }
        }
        let s = IOPSNotificationCreateRunLoopSource({ _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { Power.update() } }
        }, nil)?.takeRetainedValue()
        if let s { CFRunLoopAddSource(CFRunLoopGetMain(), s, .defaultMode); source = s }
        update()
    }

    private static func update() {
        let battery = (IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() as String?) == kIOPMBatteryPowerKey
        let now = battery || ProcessInfo.processInfo.isLowPowerModeEnabled
        guard now != saving else { return }
        saving = now
        Tuning.changed()
    }
}
