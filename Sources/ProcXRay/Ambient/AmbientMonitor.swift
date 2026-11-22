import AppKit
import Foundation
import Observation

/// Settings for the menu bar and the alerts, as UserDefaults keys (the Settings window binds them with
/// @AppStorage; the monitor reads them on each tick).
enum AmbientPrefs {
    enum ShowIn: String, CaseIterable, Identifiable {
        case both, menuBar, dock
        var id: String { rawValue }
        var title: String {
            switch self {
            case .both: "Menu bar and Dock"
            case .menuBar: "Menu bar only"
            case .dock: "Dock only"
            }
        }
    }
    static let showIn = "app.showIn"
    static let launchToMenuBar = "app.launchToMenuBar"   // at launch, open no window (only with the menu bar item)
    static let widgets = "menuBar.widgets"            // comma-separated AmbientMetric raw values
    static let widgetGraphs = "menuBar.graphs"
    static let widgetColors = "menuBar.colors"
    static let interval = "ambient.interval"
    static let alertsOn = "alerts.enabled"
    static let cpu = "alerts.cpu"                     // percent of one core
    static let gpu = "alerts.gpu"                     // percent
    static let diskMB = "alerts.diskMB"               // MB/s
    static let netMB = "alerts.netMB"                 // MB/s
    static let seconds = "alerts.seconds"
    static let unresponsive = "alerts.unresponsive"
    static let system = "alerts.system"               // thermal and memory pressure
    static let ignore = "alerts.ignore"
    static let keepMinutes = "alerts.keepMinutes"
    static let thirdPartyOnly = "triage.thirdPartyOnly"

    static func register() {
        UserDefaults.standard.register(defaults: [
            showIn: ShowIn.both.rawValue, launchToMenuBar: false, widgets: "cpu,memory", widgetGraphs: true, widgetColors: true, interval: 3.0,
            alertsOn: true, cpu: 80.0, gpu: 60.0, diskMB: 50.0, netMB: 10.0, seconds: 30.0, unresponsive: true, system: true,
            ignore: "", keepMinutes: 10.0, thirdPartyOnly: true,
        ])
    }

    static var showInValue: ShowIn { ShowIn(rawValue: UserDefaults.standard.string(forKey: showIn) ?? "") ?? .both }
    static var menuBarShown: Bool { showInValue != .dock }
    /// Launch with no window: the menu bar item only. The main window still opens at its saved frame later.
    static var launchesHidden: Bool { menuBarShown && UserDefaults.standard.bool(forKey: launchToMenuBar) }
    static var widgetList: [AmbientMetric] {
        (UserDefaults.standard.string(forKey: widgets) ?? "").split(separator: ",").compactMap { AmbientMetric(rawValue: String($0)) }
    }
}

/// The figures the menu bar, the top-consumer lists and the alerts work with.
enum AmbientMetric: String, CaseIterable, Identifiable, Sendable {
    case cpu, gpu, memory, disk, network

    /// The process list's column for this metric, for "Show All". Disk and network rank by read plus
    /// written (received plus sent), which no single column shows.
    var columnID: String? {
        switch self {
        case .cpu: "cpu"
        case .gpu: "gpu"
        case .memory: "mem"
        case .disk, .network: nil
        }
    }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .network: "Network"
        }
    }
    /// Menu bar label: at most 3 letters.
    var short: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "MEM"
        case .disk: "DSK"
        case .network: "NET"
        }
    }
    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "rectangle.3.group"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "network"
        }
    }

    func value(_ p: AmbientProc) -> Double? {
        switch self {
        case .cpu: p.cpu
        case .gpu: p.gpu
        case .memory: p.footprint.map { Double($0) }   // not .map(Double.init): that picks init(bitPattern:) for UInt64
        case .disk: p.disk
        case .network: p.net
        }
    }

    func value(_ s: AmbientSums) -> Double? { s.value(self) }

    /// A process's value as text: CPU in percent of one core, GPU in percent, the rest in bytes (per second).
    func format(_ v: Double) -> String {
        switch self {
        case .cpu, .gpu: String(format: v < 10 ? "%.1f %%" : "%.0f %%", v)
        case .memory: Fmt.bytes(UInt64(max(0, v)))
        case .disk, .network: Fmt.bytes(UInt64(max(0, v))) + "/s"
        }
    }
}

/// The two directions of disk and network traffic, each with its own history for the menu bar's in/out graphs.
enum IOSeries: Sendable, Hashable { case diskRead, diskWrite, netIn, netOut }

/// One process as the monitor last read it.
struct AmbientProc: Identifiable, Hashable, Sendable {
    /// A process's identity: pids are reused, so with its start time.
    struct Key: Hashable, Sendable { var pid: pid_t; var start: Double }
    var id: Key { key }
    var key: Key
    var pid: pid_t
    var start: Date
    var name: String
    var path: String?
    var cpu: Double?          // percent of one core
    var gpu: Double?          // percent
    var footprint: UInt64?
    var disk: Double?         // bytes per second, read + written
    var net: Double?          // bytes per second, received + sent
    var notResponding = false
    var apple = false
    var isApp = false
    var uid: uid_t = 0
    var ppid: pid_t = 0
    /// The controlling terminal's device, nil without one.
    var tty: Int32?
    /// The resource coalition (read once per process), nil when unreadable.
    var coalition: UInt64?
    /// The process macOS holds responsible for this one (read once), nil when unreadable (other users' processes).
    var responsible: pid_t?
    /// The name of the accounting group this process belongs to, when it is not that group's leader.
    var groupName: String?
    var ref: ProcessRef { ProcessRef(pid: pid, start: start.timeIntervalSince1970) }
}

/// A process that stayed in a demanding state (see AmbientMonitor), live or recently cleared.
struct AmbientAlert: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        case cpu, gpu, disk, network, notResponding
        var metric: AmbientMetric? {
            switch self {
            case .cpu: .cpu
            case .gpu: .gpu
            case .disk: .disk
            case .network: .network
            case .notResponding: nil
            }
        }
        var title: String {
            switch self {
            case .cpu: "High CPU"
            case .gpu: "High GPU"
            case .disk: "High disk throughput"
            case .network: "High network throughput"
            case .notResponding: "Not responding"
            }
        }
        var symbol: String { metric?.symbol ?? "hourglass" }
    }
    struct ID: Hashable, Sendable { var key: AmbientProc.Key; var kind: Kind }
    var id: ID { ID(key: proc.key, kind: kind) }
    var kind: Kind
    var proc: AmbientProc
    var since: Date
    var until: Date?
    var current: Double
    var peak: Double
}

/// A whole-machine condition that slows everything down: thermal pressure (the CPU is being throttled) or
/// memory pressure (the kernel is compressing, swapping and asking apps to free memory). Live only: it shows
/// while the condition holds.
struct SystemCondition: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case thermal, memory }
    var id: Kind { kind }
    var kind: Kind
    /// The thermal level (1…4) or the memory pressure level (2 warning, 4 critical) now, and the highest since.
    var level: Int32
    var peak: Int32
    var since: Date

    var title: String {
        switch kind {
        case .thermal: "Thermal pressure: \(SystemStats.thermalLevelName(level))"
        case .memory: "Memory pressure: \(level >= 4 ? "critical" : "warning")"
        }
    }
    var symbol: String { kind == .thermal ? "thermometer.high" : "memorychip" }
    var explanation: String {
        switch kind {
        case .thermal: "macOS is limiting CPU and GPU clocks to keep the Mac cool, so everything runs slower."
        case .memory: "The kernel is compressing and swapping memory and asking apps to free some. Top memory lists who holds it."
        }
    }
    /// Thermal levels from moderate, memory pressure from warning.
    static func level(_ kind: Kind, in r: SystemStats.Rates) -> Int32? {
        switch kind {
        case .thermal: r.thermal.flatMap { $0 >= 1 ? $0 : nil }
        case .memory: r.memory.flatMap { $0.pressure >= 2 ? $0.pressure : nil }
        }
    }
}

/// A process that started or exited while the monitor watched.
struct AmbientEvent: Identifiable, Hashable, Sendable {
    var id: AmbientProc.Key { proc.key }
    var proc: AmbientProc
    var at: Date
}

/// The always-on side of the app: a light sampler that keeps running while every window is closed, for the
/// menu bar widgets, its popover and the triage lists. It reads far less than the process table's snapshot
/// (no LaunchServices, launchd, signatures or argv): the process list, rusage, GPU time, the network reader's
/// rates, WindowServer's hung state for apps, and the system totals. Other users' processes come from the
/// helper when it runs.
///
/// Alerts: a process whose CPU, GPU, disk or network rate stays at or above its threshold for the set time
/// (30 s by default) raises one; a single reading below doesn't end it, two in a row do. A hung app raises
/// one at once (WindowServer has already waited ~18 s). Ended alerts stay listed for the set minutes.
@MainActor
@Observable
final class AmbientMonitor {
    static let shared = AmbientMonitor()

    private(set) var system = SystemStats.Rates()
    private(set) var systemHistory: [AmbientMetric: [Double]] = [:]
    /// Bytes per second, read and written (disk) and received and sent (network), last `historyLength` readings.
    private(set) var ioHistory: [IOSeries: [Double]] = [:]
    private(set) var procs: [AmbientProc] = []
    /// The last readings of each running process (ProcHistory.length), for the popover's row graphs.
    private(set) var procHistory: [AmbientProc.Key: ProcHistory] = [:]
    private(set) var top: [AmbientMetric: [AmbientProc]] = [:]
    /// Accounting groups (resource coalitions, see AmbientGroups), and the top few per metric.
    private(set) var groups: [AmbientGroup] = []
    private(set) var topGroups: [AmbientMetric: [AmbientGroup]] = [:]
    /// Each group's own readings: members exit, and a sum of their rings would lose the group's past with them.
    private(set) var groupHistory: [UInt64: ProcHistory] = [:]
    private(set) var alerts: [AmbientAlert] = []
    private(set) var conditions: [SystemCondition] = []
    /// What the menu bar's warning sign and the Triage badge count.
    var attentionCount: Int { alerts.count + conditions.count }
    private(set) var cleared: [AmbientAlert] = []
    private(set) var launched: [AmbientEvent] = []
    private(set) var ended: [AmbientEvent] = []
    private(set) var lastMillis = 0
    private(set) var running = false

    nonisolated static let historyLength = 60
    nonisolated static let topCount = 5

    /// Whether the store's helper is running; set by the store when it probes.
    @ObservationIgnored var helperRunning = false
    /// Views that need the monitor while the menu bar is off (the Triage section).
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var tuningObserver: NSObjectProtocol?
    @ObservationIgnored private var tracker = Tracker()

    private init() {}

    func addViewer() { viewers += 1; update() }
    func removeViewer() { viewers = max(0, viewers - 1); update() }

    /// Starts or stops sampling to match the settings; call after they change.
    func update() {
        let want = AmbientPrefs.menuBarShown || viewers > 0
        if tuningObserver == nil {
            tuningObserver = NotificationCenter.default.addObserver(forName: Tuning.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        }
        let interval = Tuning.menuBarIntervalNow
        defer { NetPace.update() }
        if want, let t = timer, t.timeInterval == interval { return }
        timer?.invalidate()
        timer = nil
        running = want
        guard want else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)   // keep sampling while a menu or the popover is open
        timer = t
        tick()
    }

    func tick() {
        guard !busy else { return }
        busy = true
        // While nothing shows the processes, only every Nth reading reads them.
        tickCount &+= 1
        let light = !popover.live && viewers == 0 && tracker.lastOutput != nil && tickCount % Tuning.menuBarProcessEvery != 0
        var apps: [pid_t: AppInfo] = [:]
        if !light {
            for a in NSWorkspace.shared.runningApplications where a.activationPolicy != .prohibited {
                apps[a.processIdentifier] = AppInfo(name: a.localizedName, regular: a.activationPolicy == .regular)
            }
        }
        let input = Input(apps: apps, helper: helperRunning, settings: .current, light: light)
        var tr = tracker
        Task.detached(priority: .utility) {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let out = PerfStages.measure(.ambientSample) { Self.sample(&tr, input) }
            let ms = Int((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
            let done = tr
            await MainActor.run {
                let perfM = PerfStages.begin(); defer { PerfStages.end(.ambientPublish, perfM) }
                self.tracker = done
                self.busy = false
                guard let out else { return }
                self.lastMillis = ms
                self.system = out.system
                self.systemHistory = done.systemHistory
                self.ioHistory = done.ioHistory
                if light {
                    // Nothing else changed.
                    if self.conditions != out.conditions { self.conditions = out.conditions }
                    return
                }
                self.procs = out.procs
                self.procHistory = done.history
                self.top = out.top
                self.groups = out.groups
                Pins.shared.prune()
                self.topGroups = out.topGroups
                self.groupHistory = done.groupHistory
                self.alerts = out.alerts
                self.conditions = out.conditions
                self.cleared = done.cleared
                self.launched = done.launched
                self.ended = done.ended
                // MenuBarExtra orders its window out without a notification: the window's state is what counts.
                if self.popover.live, self.popover.window?.isVisible != true { self.popover.live = false }
                if self.popover.live { self.popover.copy(from: self) }
            }
        }
    }

    func clearEnded() {
        tracker.cleared = []; cleared = []
        if popover.live { popover.copy(from: self) }
    }

    /// What the menu bar popover shows, kept up to date only while it's on screen.
    @ObservationIgnored let popover = AmbientShown()

    // MARK: Sampling (off the main thread)

    struct AppInfo: Sendable { var name: String?; var regular: Bool }

    struct Settings: Sendable {
        var alertsOn = true
        var cpu = 80.0, gpu = 60.0, disk = 50e6, net = 10e6
        var seconds = 30.0
        var unresponsive = true
        var system = true
        var ignore: Set<String> = []
        var keep = 600.0
        var thirdPartyOnly = true

        @MainActor static var current: Settings {
            let d = UserDefaults.standard
            return Settings(alertsOn: d.bool(forKey: AmbientPrefs.alertsOn),
                            cpu: d.double(forKey: AmbientPrefs.cpu), gpu: d.double(forKey: AmbientPrefs.gpu),
                            disk: d.double(forKey: AmbientPrefs.diskMB) * 1e6, net: d.double(forKey: AmbientPrefs.netMB) * 1e6,
                            seconds: d.double(forKey: AmbientPrefs.seconds), unresponsive: d.bool(forKey: AmbientPrefs.unresponsive),
                            system: d.bool(forKey: AmbientPrefs.system),
                            ignore: Set((d.string(forKey: AmbientPrefs.ignore) ?? "").split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }),
                            keep: d.double(forKey: AmbientPrefs.keepMinutes) * 60,
                            thirdPartyOnly: d.bool(forKey: AmbientPrefs.thirdPartyOnly))
        }

        func threshold(_ k: AmbientAlert.Kind) -> Double {
            switch k {
            case .cpu: cpu
            case .gpu: gpu
            case .disk: disk
            case .network: net
            case .notResponding: 0.5
            }
        }
    }

    struct Input: Sendable {
        var apps: [pid_t: AppInfo]
        var helper: Bool
        var settings: Settings
        /// The system's totals only (sampleSystem).
        var light = false
    }

    struct Output: Sendable {
        var system: SystemStats.Rates
        var procs: [AmbientProc]
        var top: [AmbientMetric: [AmbientProc]]
        var groups: [AmbientGroup]
        var topGroups: [AmbientMetric: [AmbientGroup]]
        var alerts: [AmbientAlert]
        var conditions: [SystemCondition]
    }

    struct Streak: Sendable {
        var since: Date
        var below = 0
        var current: Double
        var peak: Double
        var proc: AmbientProc
    }

    /// What carries over from one tick to the next.
    /// What doesn't change while a process runs, read once.
    struct Stable: Sendable {
        var path: String?
        var name: String          // the executable's file name, or the kernel's 16-character comm
        var apple: Bool
        var coalition: UInt64?
        var responsible: pid_t?
    }

    /// The three counters the monitor turns into rates.
    struct Counts: Sendable { var at: UInt64; var cpu: UInt64; var disk: UInt64 }

    struct Tracker: Sendable {
        /// The last full reading, which a light one (sampleSystem) hands on.
        var lastOutput: Output?
        /// When the helper reading last used was read (HelperClient.recentMetrics).
        var helperAt: UInt64 = 0
        /// The processes the last reading couldn't read without the helper, and when it was made (HelperAsk).
        var needsHelper: Set<Int32> = []
        var readAt: Double = 0
        /// Processes the helper was asked about and gave no figures for: not asked about on every reading.
        var helperFutile: Set<Int32> = []
        var samples: [AmbientProc.Key: Counts] = [:]
        /// GPU time is read every other tick (the IORegistry walk is the costliest read here, ~3.7 ms of CPU);
        /// the rates from the last read stand in between.
        var gpuLast: (at: UInt64, nanos: [pid_t: UInt64])?
        var gpuRates: [pid_t: Double] = [:]
        var stable: [AmbientProc.Key: Stable] = [:]
        var lastSystem: SystemStats?
        var systemHistory: [AmbientMetric: [Double]] = [:]
        var ioHistory: [IOSeries: [Double]] = [:]
        var lastProcs: [AmbientProc.Key: AmbientProc] = [:]
        var history: [AmbientProc.Key: ProcHistory] = [:]
        var groupHistory: [UInt64: ProcHistory] = [:]
        var streaks: [AmbientAlert.ID: Streak] = [:]
        var conditions: [SystemCondition.Kind: SystemCondition] = [:]
        var cleared: [AmbientAlert] = []
        var launched: [AmbientEvent] = []
        var ended: [AmbientEvent] = []
        var ticks = 0
    }

    /// Works out the system's rates since the last reading and adds them to the histories the menu bar graphs draw.
    nonisolated private static func recordSystem(_ tr: inout Tracker, _ sys: SystemStats) -> SystemStats.Rates {
        var sysRates = SystemStats.Rates(gpuPercent: sys.gpuPercent, gpu: sys.gpu, memory: sys.memory, thermal: sys.thermal)
        if let last = tr.lastSystem { sysRates = sys.rates(since: last) }
        tr.lastSystem = sys
        if tr.ticks > 0 {
            func push(_ m: AmbientMetric, _ v: Double?) {
                guard let v else { return }
                var h = tr.systemHistory[m] ?? []
                h.append(v)
                if h.count > historyLength { h.removeFirst(h.count - historyLength) }
                tr.systemHistory[m] = h
            }
            push(.cpu, sysRates.cpuPercent); push(.gpu, sysRates.gpuPercent)
            push(.memory, sysRates.memory.map { $0.usedFraction * 100 })
            push(.disk, sysRates.disk); push(.network, sysRates.net)
            func push(_ k: IOSeries, _ v: Double?) {
                guard let v else { return }
                var h = tr.ioHistory[k] ?? []
                h.append(v)
                if h.count > historyLength { h.removeFirst(h.count - historyLength) }
                tr.ioHistory[k] = h
            }
            push(.diskRead, sysRates.diskRead); push(.diskWrite, sysRates.diskWrite)
            push(.netIn, sysRates.netIn); push(.netOut, sysRates.netOut)
        }
        return sysRates
    }

    /// Thermal and memory pressure: shown from the first reading at that level until it drops back.
    nonisolated private static func systemConditions(_ tr: inout Tracker, _ sysRates: SystemStats.Rates, _ s: Settings, _ date: Date) -> [SystemCondition] {
        var conditions: [SystemCondition] = []
        for kind in [SystemCondition.Kind.thermal, .memory] {
            guard s.alertsOn, s.system, let level = SystemCondition.level(kind, in: sysRates) else { tr.conditions[kind] = nil; continue }
            var c = tr.conditions[kind] ?? SystemCondition(kind: kind, level: level, peak: level, since: date)
            c.level = level
            c.peak = max(c.peak, level)
            tr.conditions[kind] = c
            conditions.append(c)
        }
        return conditions
    }

    /// A light reading: the system's totals only, for the menu bar's widgets and the pressure conditions. The
    /// processes, groups and alerts stay as the last full reading left them (`last`). A full reading costs ~11 ms
    /// of CPU for ~1,100 processes and this one a fraction of that, so while nothing shows the per-process
    /// figures (the popover is closed, Triage isn't open) only every Nth reading is a full one
    /// (Tuning.menuBarProcessEvery).
    nonisolated static func sampleSystem(_ tr: inout Tracker, _ input: Input, _ last: Output) -> Output {
        let sys = SystemStats.read()
        let sysRates = recordSystem(&tr, sys)
        var out = last
        out.system = sysRates
        out.conditions = systemConditions(&tr, sysRates, input.settings, Date())
        return out
    }

    nonisolated static func sample(_ tr: inout Tracker, _ input: Input) -> Output? {
        if input.light, let last = tr.lastOutput { return sampleSystem(&tr, input, last) }
        guard case .success(let list) = Native.listProcesses() else { return nil }
        // The process list's reading when it refreshed lately (the helper's answer costs ~40 ms of its CPU); counts
        // from it are dated when it was read, so rates stay right.
        // Only a reading this monitor hasn't used: two ticks on one reading would have no interval to rate over.
        let recent = HelperClient.shared.recentMetrics(maxAge: 2.5).flatMap { $0.at > tr.helperAt ? $0 : nil }
        // Asked only for the processes this monitor couldn't read itself last time, and whatever started since.
        // Not those the helper gave nothing for (a caller who isn't an admin gets only their own processes'
        // figures, and a zombie has none): they are asked about again every 30th reading.
        if tr.ticks % 30 == 0 { tr.helperFutile = [] }
        let ask = tr.ticks == 0 ? nil : HelperAsk(pids: Array(tr.needsHelper.subtracting(tr.helperFutile)), since: tr.readAt - 1)
        let helped = input.helper ? recent ?? HelperClient.shared.metrics(ask, timeout: 1.5) : nil
        if let helped { tr.helperAt = helped.at }
        var needsHelper: Set<Int32> = []
        defer { tr.needsHelper = needsHelper; tr.readAt = Date().timeIntervalSince1970 }
        let priv = helped?.metrics
        if tr.ticks % 2 == 0 {
            let at = DispatchTime.now().uptimeNanoseconds, g = ExtraRead.gpuNanosByPid()
            if let last = tr.gpuLast, at > last.at {
                let secs = Double(at - last.at) / 1e9
                tr.gpuRates = g.reduce(into: [:]) { r, e in
                    // A client that went away lowers the sum: no negative rates.
                    let before = last.nanos[e.key] ?? 0
                    if e.value > before { r[e.key] = Double(e.value - before) / 1e9 / secs * 100 }
                }
            }
            tr.gpuLast = (at, g)
        }
        let net = NetSampler.shared.current()
        let hung = Responsiveness.unresponsive(input.apps.keys)
        let sys = SystemStats.read()
        let now = DispatchTime.now().uptimeNanoseconds
        let date = Date()
        let s = input.settings

        var samples: [AmbientProc.Key: Counts] = [:]
        var stable: [AmbientProc.Key: Stable] = [:]
        samples.reserveCapacity(list.count)
        stable.reserveCapacity(list.count)
        var procs: [AmbientProc] = []
        procs.reserveCapacity(list.count)
        for k in list where k.pid > 0 && k.stat != 5 {
            let key = AmbientProc.Key(pid: k.pid, start: k.start.timeIntervalSince1970)
            let st: Stable
            if let known = tr.stable[key] { st = known } else {
                let p = ProcInfo(pid: k.pid, ppid: k.ppid, pgid: k.pgid, uid: k.uid, user: "", comm: k.comm,
                                 path: Native.path(k.pid), start: k.start, stat: k.stat, pflags: k.flags)
                st = Stable(path: p.path, name: p.name, apple: SmartTree.isApple(p),
                            coalition: Native.coalition(k.pid)?.0, responsible: Native.responsible(k.pid))
            }
            stable[key] = st
            // One rusage call; the helper's reading for processes of other users.
            var c: Counts?, footprint: UInt64?
            if let ru = Native.rusage(k.pid) {
                c = Counts(at: now, cpu: Native.machToNanos(ru.ri_user_time &+ ru.ri_system_time),
                           disk: ru.ri_diskio_bytesread &+ ru.ri_diskio_byteswritten)
                footprint = ru.ri_phys_footprint
            } else {
                needsHelper.insert(k.pid)
                if let m = priv?[k.pid], let cpu = m.cpuNanos, let at = helped?.at {
                    c = Counts(at: at, cpu: cpu, disk: (m.diskRead ?? 0) &+ (m.diskWrite ?? 0))
                    footprint = m.footprint
                } else if let m = priv?[k.pid], m.cpuNanos == nil {
                    tr.helperFutile.insert(k.pid)
                }
            }
            let app = input.apps[k.pid]
            var a = AmbientProc(key: key, pid: k.pid, start: k.start, name: app?.name ?? st.name, path: st.path)
            a.uid = k.uid
            a.ppid = k.ppid
            if k.tty != -1 { a.tty = k.tty }   // NODEV: no controlling terminal
            a.coalition = st.coalition
            a.responsible = st.responsible
            if let c {
                samples[key] = c
                if let b = tr.samples[key], c.at > b.at {
                    let secs = Double(c.at - b.at) / 1e9
                    a.cpu = c.cpu >= b.cpu ? Double(c.cpu - b.cpu) / 1e9 / secs * 100 : 0
                    a.disk = c.disk >= b.disk ? Double(c.disk - b.disk) / secs : 0
                }
            }
            a.footprint = footprint
            a.gpu = tr.gpuLast == nil ? nil : tr.gpuRates[k.pid] ?? 0
            if let net { a.net = net[k.pid].map { $0.inPerSec + $0.outPerSec } ?? 0 }
            a.notResponding = hung.contains(k.pid)
            a.apple = st.apple
            a.isApp = app?.regular == true
            procs.append(a)
        }

        // Accounting groups; each member that isn't its group's leader carries the group's name.
        let groups = AmbientGroups.group(&procs)

        // System totals and their history.
        let sysRates = recordSystem(&tr, sys)

        // Top consumers per metric.
        var top: [AmbientMetric: [AmbientProc]] = [:]
        for m in AmbientMetric.allCases {
            // One pass, keeping the best few in order.
            var best: [(Double, Int)] = []
            // By index, not `for p in procs`: that copies each process (see AmbientGroups.top).
            for i in procs.indices {
                guard let v = m.value(procs[i]), v > 0, best.count < topCount || v > best[best.count - 1].0 else { continue }
                best.insert((v, i), at: best.firstIndex { $0.0 < v } ?? best.count)
                if best.count > topCount { best.removeLast() }
            }
            top[m] = best.map { procs[$0.1] }
        }
        var topGroups: [AmbientMetric: [AmbientGroup]] = [:]
        for m in AmbientMetric.allCases { topGroups[m] = AmbientGroups.top(groups, m, count: topCount) }

        // Launched and ended (not on the first tick: everything would look new).
        let byKey = Dictionary(procs.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let shown: (AmbientProc) -> Bool = { !s.thirdPartyOnly || !$0.apple }
        if tr.ticks > 0 {
            for p in procs where tr.lastProcs[p.key] == nil && shown(p) {
                tr.launched.insert(AmbientEvent(proc: p, at: p.start), at: 0)
            }
            for (key, p) in tr.lastProcs where byKey[key] == nil && shown(p) {
                tr.ended.insert(AmbientEvent(proc: p, at: date), at: 0)
            }
        }
        // The launch entry follows its process's current figures.
        tr.launched = tr.launched.map { e in var e = e; if let p = byKey[e.proc.key] { e.proc = p }; return e }
        let horizon = date.addingTimeInterval(-max(60, s.keep))
        tr.launched = Array(tr.launched.filter { $0.at > horizon }.prefix(50))
        tr.ended = Array(tr.ended.filter { $0.at > horizon }.prefix(50))

        // Sustained usage.
        var live: [AmbientAlert] = []
        var seen: Set<AmbientAlert.ID> = []
        if s.alertsOn {
            let ignored: (AmbientProc) -> Bool = { p in
                !s.ignore.isEmpty && (s.ignore.contains(p.name.lowercased()) || s.ignore.contains((stable[p.key]?.name ?? "").lowercased()))
            }
            for p in procs {
                for kind in AmbientAlert.Kind.allCases {
                    let v: Double?
                    if kind == .notResponding { v = s.unresponsive ? (p.notResponding ? 1 : 0) : nil } else { v = kind.metric.flatMap { $0.value(p) } }
                    guard let v else { continue }
                    let id = AmbientAlert.ID(key: p.key, kind: kind)
                    let over = v >= s.threshold(kind)
                    if var st = tr.streaks[id] {
                        st.proc = p
                        st.current = v
                        if over { st.below = 0; st.peak = max(st.peak, v) } else { st.below += 1 }
                        tr.streaks[id] = st
                        seen.insert(id)
                    } else if over, !ignored(p) {
                        tr.streaks[id] = Streak(since: date, current: v, peak: v, proc: p)
                        seen.insert(id)
                    }
                }
            }
        }
        for (id, st) in tr.streaks {
            let kind = id.kind
            let need = kind == .notResponding ? 0 : s.seconds
            let active = date.timeIntervalSince(st.since) >= need
            let gone = !seen.contains(id)
            // Two readings below in a row end it (one below is tolerated); a hung app ends at once.
            let over = st.below == 0 || (st.below < 2 && kind != .notResponding)
            if !gone && over {
                if active { live.append(AmbientAlert(kind: kind, proc: st.proc, since: st.since, current: st.current, peak: st.peak)) }
                continue
            }
            if active {
                tr.cleared.removeAll { $0.id == id }
                tr.cleared.insert(AmbientAlert(kind: kind, proc: st.proc, since: st.since, until: date, current: st.current, peak: st.peak), at: 0)
            }
            tr.streaks[id] = nil
        }
        tr.cleared = Array(tr.cleared.filter { ($0.until ?? date) > horizon }.prefix(50))
        live.sort { ($0.kind == .notResponding ? 0 : 1, $0.since) < ($1.kind == .notResponding ? 0 : 1, $1.since) }

        let conditions = systemConditions(&tr, sysRates, s, date)

        tr.samples = samples
        tr.stable = stable
        tr.lastProcs = byKey
        var hist: [AmbientProc.Key: ProcHistory] = [:]
        hist.reserveCapacity(procs.count)
        for p in procs {
            var h = tr.history[p.key] ?? ProcHistory()
            h.append(p)
            hist[p.key] = h
        }
        tr.history = hist
        var ghist: [UInt64: ProcHistory] = [:]
        ghist.reserveCapacity(groups.count)
        for g in groups {
            var h = tr.groupHistory[g.id] ?? ProcHistory()
            h.append(g.sums)
            ghist[g.id] = h
        }
        tr.groupHistory = ghist
        tr.ticks += 1
        let out = Output(system: sysRates, procs: procs, top: top, groups: groups, topGroups: topGroups, alerts: live, conditions: conditions)
        tr.lastOutput = out
        return out
    }
}

extension AmbientMonitor {
    /// `--ambient <seconds> [interval]`: the monitor's sampling without the UI, timed per tick (wall and this
    /// process's CPU), with what it found: hung apps, top CPU, alerts (raised with a 6 s threshold so a short
    /// run can show one), launches and exits.
    nonisolated static func bench(seconds: Double, interval: Double) {
        func cpuNanos() -> UInt64 {
            var ru = rusage(); getrusage(RUSAGE_SELF, &ru)
            return UInt64(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) * 1_000_000_000 + UInt64(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) * 1000
        }
        NetSampler.shared.startAtLaunch()
        var tr = Tracker()
        var s = Settings()
        s.seconds = 6
        let end = Date().addingTimeInterval(seconds)
        var walls: [Double] = [], cpus: [Double] = []
        while Date() < end {
            let apps: [pid_t: AppInfo] = DispatchQueue.main.sync {
                var a: [pid_t: AppInfo] = [:]
                for r in NSWorkspace.shared.runningApplications where r.activationPolicy != .prohibited {
                    a[r.processIdentifier] = AppInfo(name: r.localizedName, regular: r.activationPolicy == .regular)
                }
                return a
            }
            let t0 = DispatchTime.now().uptimeNanoseconds, c0 = cpuNanos()
            guard let out = sample(&tr, Input(apps: apps, helper: HelperClient.shared.probe().isRunning, settings: s)) else { print("process list failed"); return }
            let wall = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6, cpu = Double(cpuNanos() - c0) / 1e6
            walls.append(wall); cpus.append(cpu)
            let sys = out.system
            print(String(format: "tick %2d: %5.1f ms wall %5.1f ms cpu | %d procs | sys cpu %@ gpu %@ mem %@ disk %@/s net %@/s | hung %@",
                         tr.ticks, wall, cpu, out.procs.count, sys.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "—",
                         sys.gpuPercent.map { String(format: "%.0f%%", $0) } ?? "—",
                         sys.memory.map { Fmt.bytes($0.used) } ?? "—", Fmt.bytes(sys.disk.map { UInt64($0) }),
                         Fmt.bytes(sys.net.map { UInt64($0) }),
                         out.procs.filter(\.notResponding).map(\.name).joined(separator: ", ")))
            let mem = sys.memory, cl = sys.clusters
            print("         swap " + Fmt.bytes(mem?.swapUsed) + " of " + Fmt.bytes(mem?.swapTotal) + ", available \(mem?.level.map { "\($0) %" } ?? "—")"
                  + ", thermal " + (sys.thermal.map(SystemStats.thermalLevelName) ?? "—")
                  + " | " + (cl?.cpu ?? []).map { "\($0.kind) \($0.mhz.map { String(format: "%.0f MHz", $0) } ?? "idle/—") \(String(format: "%.0f%%", $0.active * 100))" }.joined(separator: ", ")
                  + " | GPU " + (cl?.gpu.map { "\($0.mhz.map { String(format: "%.0f MHz", $0) } ?? "idle/—") \(String(format: "%.0f%%", $0.active * 100))" } ?? "—")
                  + (cl?.gpuWatts.map { String(format: " %.2f W", $0) } ?? "")
                  + " renderer \(sys.gpu?.renderer.map { String(format: "%.0f%%", $0) } ?? "—") tiler \(sys.gpu?.tiler.map { String(format: "%.0f%%", $0) } ?? "—") mem " + Fmt.bytes(sys.gpu?.memoryInUse))
            for c in out.conditions { print("         CONDITION \(c.title) since \(Int(Date().timeIntervalSince(c.since))) s") }
            if let t = out.top[.cpu]?.first { print("         top cpu: \(t.name) (\(t.pid)) \(AmbientMetric.cpu.format(t.cpu ?? 0))") }
            if let g = out.topGroups[.cpu]?.first { print("         top cpu group: \(g.name) (\(g.count) processes) \(AmbientMetric.cpu.format(g.sums.cpu ?? 0))") }
            if let t = out.top[.memory]?.first { print("         top memory: \(t.name) (\(t.pid)) \(AmbientMetric.memory.format(Double(t.footprint ?? 0)))") }
            print("         footprints: \(out.procs.filter { ($0.footprint ?? 0) > 0 }.count) of \(out.procs.count) nonzero, \(out.procs.filter { $0.footprint == nil }.count) nil")
            for a in out.alerts { print("         ALERT \(a.kind.title): \(a.proc.name) (\(a.proc.pid)) now \(a.kind.metric?.format(a.current) ?? "") peak \(a.kind.metric?.format(a.peak) ?? "") for \(Int(Date().timeIntervalSince(a.since))) s") }
            Thread.sleep(forTimeInterval: interval)
        }
        print("launched: \(tr.launched.map { "\($0.proc.name)(\($0.proc.pid))" }.joined(separator: " "))")
        print("ended: \(tr.ended.map { "\($0.proc.name)(\($0.proc.pid))" }.joined(separator: " "))")
        print("cleared: \(tr.cleared.map { "\($0.kind.title) \($0.proc.name)" }.joined(separator: "; "))")
        let w = walls.dropFirst(), c = cpus.dropFirst()
        if !w.isEmpty {
            print(String(format: "after the first tick: wall avg %.1f ms max %.1f ms; cpu avg %.1f ms → %.2f %% of one core at a %.0f s interval",
                         w.reduce(0, +) / Double(w.count), w.max()!, c.reduce(0, +) / Double(c.count),
                         c.reduce(0, +) / Double(c.count) / (interval * 1000) * 100, interval))
        }
    }
}

extension AmbientMonitor {
    /// `--groups [seconds]`: two samples that far apart (2 s by default), then each accounting group of more than one
    /// process with its leader, sub-groups and sums, largest CPU first; checks every process lands in exactly one group.
    nonisolated static func printGroups(seconds: Double) {
        NetSampler.shared.startAtLaunch()
        func apps() -> [pid_t: AppInfo] {
            DispatchQueue.main.sync {
                var a: [pid_t: AppInfo] = [:]
                for r in NSWorkspace.shared.runningApplications where r.activationPolicy != .prohibited {
                    a[r.processIdentifier] = AppInfo(name: r.localizedName, regular: r.activationPolicy == .regular)
                }
                return a
            }
        }
        var tr = Tracker()
        let helper = HelperClient.shared.probe().isRunning
        _ = sample(&tr, Input(apps: apps(), helper: helper, settings: Settings()))
        Thread.sleep(forTimeInterval: seconds)
        guard let out = sample(&tr, Input(apps: apps(), helper: helper, settings: Settings())) else { print("process list failed"); return }
        var groups: [AmbientGroup] = [], times: [Double] = []
        for _ in 0..<5 {   // the first call looks up terminal names (devname searches /dev); later ones are what a tick costs
            let t0 = DispatchTime.now().uptimeNanoseconds
            var ps = out.procs
            groups = AmbientGroups.group(&ps)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000)
        }
        let us = times.dropFirst().reduce(0, +) / Double(times.count - 1)
        func figs(_ s: AmbientSums) -> String {
            "\(AmbientMetric.cpu.format(s.cpu ?? 0)) cpu, \(Fmt.bytes(s.memory.map { UInt64($0) })) mem" + (s.partial ? " (sums cover \(s.covered) of \(s.count))" : "")
        }
        func line(_ p: AmbientProc) -> String {
            "\(p.name) (\(p.pid)) \(AmbientMetric.cpu.format(p.cpu ?? 0)) \(Fmt.bytes(p.footprint))" + (p.responsible.map { $0 == p.pid ? "" : " resp \($0)" } ?? " resp ?")
        }
        let multi = groups.filter { !$0.single }.sorted { ($0.sums.cpu ?? 0) > ($1.sums.cpu ?? 0) }
        for g in multi {
            print("\(g.name) [coalition \(g.id)] \(g.count) processes: \(figs(g.sums)), leader pid \(g.leader.pid)")
            for sg in g.subgroups.sorted(by: { ($0.sums.cpu ?? 0) > ($1.sums.cpu ?? 0) }) {
                print("    ▸ \(sg.title) — \(sg.members.count): \(figs(sg.sums))")
                for m in sg.members.sorted(by: { ($0.cpu ?? 0) > ($1.cpu ?? 0) }).prefix(4) { print("        \(line(m))") }
                if sg.members.count > 4 { print("        …") }
            }
            for m in g.plain { print("    \(line(m))") }
        }
        // Every process in exactly one group, and in exactly one place inside it.
        var seen: [AmbientProc.Key: Int] = [:]
        for g in groups {
            for m in g.members { seen[m.key, default: 0] += 1 }
            if g.members.count != g.count { print("MISMATCH in \(g.name): \(g.members.count) placed of \(g.count)") }
        }
        let twice = seen.filter { $0.value != 1 }.count, missing = out.procs.filter { seen[$0.key] == nil }.count
        print("\(out.procs.count) processes, \(groups.count) groups, \(multi.count) of more than one; in two groups: \(twice), in none: \(missing); grouping took \(String(format: "%.0f", times[0])) µs the first time, \(String(format: "%.0f", us)) µs after")
        print("top cpu groups: " + (out.topGroups[.cpu] ?? []).map { "\($0.name) \(AmbientMetric.cpu.format($0.sums.cpu ?? 0))" }.joined(separator: ", "))
        print("top cpu processes: " + (out.top[.cpu] ?? []).map { "\($0.name) \(AmbientMetric.cpu.format($0.cpu ?? 0))" }.joined(separator: ", "))
    }
}

/// A process's last readings for the popover's row graphs, oldest first.
struct ProcHistory: Sendable {
    static let length = 30
    private var ring = SeriesRing(lanes: 5, capacity: ProcHistory.length)

    mutating func append(_ p: AmbientProc) {
        push(p.cpu, p.gpu, p.footprint.map { Double($0) }, p.disk, p.net)
    }

    mutating func append(_ s: AmbientSums) { push(s.cpu, s.gpu, s.memory, s.disk, s.net) }

    private mutating func push(_ c: Double?, _ g: Double?, _ m: Double?, _ d: Double?, _ n: Double?) {
        ring.push { lane in
            switch lane {
            case 0: c
            case 1: g
            case 2: m
            case 3: d
            default: n
            }
        }
    }

    func values(_ m: AmbientMetric) -> [Double] {
        switch m {
        case .cpu: ring.filled(0)
        case .gpu: ring.filled(1)
        case .memory: ring.filled(2)
        case .disk: ring.filled(3)
        case .network: ring.filled(4)
        }
    }
}

/// The menu bar popover's copy of the monitor's state, refreshed only while the popover is on screen (`live`).
/// SwiftUI keeps a MenuBarExtra's content alive after it closes: reading the monitor directly re-rendered the whole
/// closed popover on every tick, about a tenth of the app's CPU time.
@MainActor
@Observable
final class AmbientShown {
    fileprivate(set) var system = SystemStats.Rates()
    fileprivate(set) var systemHistory: [AmbientMetric: [Double]] = [:]
    fileprivate(set) var procs: [AmbientProc] = []
    fileprivate(set) var procHistory: [AmbientProc.Key: ProcHistory] = [:]
    fileprivate(set) var groups: [AmbientGroup] = []
    fileprivate(set) var topGroups: [AmbientMetric: [AmbientGroup]] = [:]
    fileprivate(set) var groupHistory: [UInt64: ProcHistory] = [:]
    fileprivate(set) var alerts: [AmbientAlert] = []
    fileprivate(set) var conditions: [SystemCondition] = []
    var attentionCount: Int { alerts.count + conditions.count }
    fileprivate(set) var cleared: [AmbientAlert] = []
    fileprivate(set) var launched: [AmbientEvent] = []
    fileprivate(set) var ended: [AmbientEvent] = []

    /// Whether the popover is on screen. Turning it on catches up with the monitor at once.
    @ObservationIgnored var live = false {
        didSet {
            if live != oldValue { NetPace.update() }
            guard live, !oldValue else { return }
            copy(from: AmbientMonitor.shared)
            // The processes may be a few readings old (light readings while it was closed): read them now.
            AmbientMonitor.shared.tick()
        }
    }

    /// The popover's window, once it has one.
    @ObservationIgnored weak var window: NSWindow?

    func clearEnded() { AmbientMonitor.shared.clearEnded() }

    fileprivate func copy(from m: AmbientMonitor) {
        system = m.system; systemHistory = m.systemHistory
        procs = m.procs; procHistory = m.procHistory
        groups = m.groups; topGroups = m.topGroups; groupHistory = m.groupHistory
        alerts = m.alerts; conditions = m.conditions
        cleared = m.cleared; launched = m.launched; ended = m.ended
    }
}
