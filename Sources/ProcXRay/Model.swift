import AppKit
import Darwin
import Foundation
import Observation
import SwiftUI

struct ProcInfo: Identifiable, Hashable, Sendable {
    var id: pid_t { pid }
    let pid: pid_t
    var ppid: pid_t
    var pgid: pid_t
    var uid: uid_t
    var user: String
    var comm: String {
        didSet {
            name = ProcInfo.displayName(path: path, comm: comm)
            if cdhash == nil, path == nil { codeKey = "\(key):\(comm)" }
        }
    }
    var path: String? {
        didSet {
            name = ProcInfo.displayName(path: path, comm: comm)
            if cdhash == nil { codeKey = "\(key):\(path ?? comm)" }
        }
    }
    let start: Date
    var stat: Int8
    var pflags: Int32
    /// The name shown for it (displayName). Stored, as the table reads it for every row on every rebuild.
    private(set) var name: String
    /// pid and start time, which together name one process (pids are reused). Stored: it's looked up for
    /// every process several times per refresh, and formatting the Double each time showed in profiles.
    let key: String

    init(pid: pid_t, ppid: pid_t, pgid: pid_t, uid: uid_t, user: String, comm: String, path: String?,
         start: Date, stat: Int8, pflags: Int32) {
        self.pid = pid; self.ppid = ppid; self.pgid = pgid; self.uid = uid; self.user = user; self.comm = comm
        self.path = path; self.start = start; self.stat = stat; self.pflags = pflags
        key = "\(pid):\(start.timeIntervalSince1970)"
        name = ProcInfo.displayName(path: path, comm: comm)
        codeKey = "\(key):\(path ?? comm)"
    }

    var responsible: pid_t?
    /// Audit session id (asid), from the audit token: the user's own processes, others' through the helper.
    var asid: Int32?
    /// What that session is (LoginSessions.describe): which login the process belongs to.
    var session: LoginSession?
    var coalition: UInt64?
    var jetsamCoalition: UInt64?
    var sandboxed: Bool?

    var rss: UInt64?
    var footprint: UInt64?
    var virt: UInt64?
    var threads: Int32?
    var cpuNanos: UInt64?
    var cpuPercent: Double?
    var diskRead: UInt64?
    var diskWrite: UInt64?
    /// Energy the process's own threads used on the CPU, in nanojoules (rusage ri_energy_nj).
    var energyNJ: UInt64?
    var wakeups: UInt64?
    var counters: Counters?
    /// Scheduling priority (proc_taskinfo).
    var priority: Int32?
    // Read only while a column shows them (ExtraReads); nil otherwise.
    var nice: Int32?
    var openFiles: Int?
    var compressed: UInt64?
    /// task_suspend calls not yet resumed (ExtraReads.suspended); nil when not read.
    var suspendCount: Int32?
    /// Jetsam band and memory limits (root only: from the helper, unless the app runs as root).
    var jetsam: JetsamInfo?
    /// Dirty tracking: whether it may be stopped when idle, and whether it's busy now.
    var idleExit: IdleExitState?
    /// Power assertion types held (IOPMCopyAssertionsByProcess); empty when it holds none.
    var assertions: [String]?
    /// GPU time since the process started, nanoseconds; nil when it has never used the GPU.
    var gpuNanos: UInt64?
    /// Network bytes per second over NetSampler's latest reading.
    var netIn: Double?
    var netOut: Double?
    /// Network bytes over every socket NetSampler has seen the process use; nil from nettop. A lower bound for
    /// a process started before NetSampler.since.
    var netInTotal: UInt64?
    var netOutTotal: UInt64?
    /// Port space totals from the last lsmp snapshot (MachLoader); nil for a process started after it.
    var machPorts: MachPortCounts?
    /// Per-second rates over the last refresh interval (nil on a process's first sample).
    var rates: Rates?

    // joined from other sources
    var launchdLabel: String?
    /// Domain of the launchd job (`launchdLabel`): "gui", "system" or "user".
    var launchdDomain: String?
    var lsAppName: String?
    /// LaunchServices application type: "Foreground", "UIElement" or "BackgroundOnly".
    var lsType: String?
    /// Controlling terminal device, nil when the process has none.
    var tty: Int32?
    /// NSExtensionPointIdentifier of the app extension this process runs (see ExtensionInfo).
    var extensionPoint: String?
    /// The process whose launchd pid domain this one runs in: an extension's host daemon, an XPC service's
    /// app (see PidDomain). Its name is kept for the Context column, which only sees this process.
    var domainOwner: pid_t?
    var domainOwnerName: String?
    /// launchd's `parent bundle identifier` for this process's job: the app that registered it through
    /// SMAppService. Read once per process (see Store.fillJobParents); nil when none or not read yet.
    var launchdParentBundle: String?
    var lsTags: [String] = []
    var signer: String?
    var signID: String?
    /// argv joined for display (see Store.argvCache); nil until read, or when it couldn't be read.
    var commandLine: String?
    /// Set once reading argv was tried, so the cell can tell "not read yet" from "unreadable".
    var commandLineRead = false
    var viaHelper = false              // metrics came from the root helper
    /// WindowServer reports the app as hung (Responsiveness). Apps only; false for everything else.
    var notResponding = false
    /// Set when this process outlived the app that launched it (see Store.ghosts): the Left Behind
    /// group's id, and the app's name and pid where known.
    var leftBehindGroup: Int?
    var leftBehindApp: String?
    var leftBehindPid: pid_t?
    /// The exited app's LaunchServices state tags, for the Left behind group row.
    var leftBehindTags: [String] = []
    var leftBehindText: String? {
        guard leftBehindGroup != nil else { return nil }
        return "\(leftBehindApp ?? "exited app") (\(leftBehindPid.map { "pid \($0)" } ?? "previous instance"))"
    }

    /// CDHash of the running code (see Native.cdhash); changes when the process execs something else.
    var cdhash: String? {
        didSet { if cdhash != oldValue { codeKey = "\(key):\(cdhash ?? path ?? comm)" } }
    }
    /// Key for signing details: pid and start time survive exec, so the running code is part of it.
    /// Without it a process could show an Apple signature while running unsigned code it exec'd.
    /// Stored, like `key`: it is looked up for every process several times per refresh, on the main thread too,
    /// and building the string each time was a measurable part of both. Kept in step by the three it's made of.
    private(set) var codeKey: String

    /// The executable's file name, or, when that file is named for a version, the folder it's installed in:
    /// Claude Code runs as ~/.local/share/claude/versions/2.1.325 (the kernel's name for it is "2.1.325" too),
    /// shown as "claude".
    static func displayName(path: String?, comm: String) -> String {
        guard let p = path else { return comm }
        let base = (p as NSString).lastPathComponent
        guard base.first?.isNumber == true, base.allSatisfy({ $0.isNumber || $0 == "." }) else { return base }
        var dir = (p as NSString).deletingLastPathComponent
        if (dir as NSString).lastPathComponent == "versions" { dir = (dir as NSString).deletingLastPathComponent }
        let folder = (dir as NSString).lastPathComponent
        return folder.isEmpty || folder == "/" ? base : folder
    }
    var isZombie: Bool { stat == 5 }
    var isTranslated: Bool { pflags & 0x20000 != 0 }   // P_TRANSLATED (Rosetta)
    var isInspectable: Bool { rss != nil }
    var respIsOther: Bool { responsible != nil && responsible != pid }

    /// Copies the metrics this process doesn't have yet; true if it took any.
    mutating func fill(from m: PrivMetrics) -> Bool {
        var took = false
        func fill<T>(_ kp: WritableKeyPath<ProcInfo, T?>, _ v: T?) {
            guard self[keyPath: kp] == nil, let v else { return }
            self[keyPath: kp] = v
            took = true
        }
        fill(\.rss, m.rss); fill(\.virt, m.virt); fill(\.threads, m.threads); fill(\.cpuNanos, m.cpuNanos)
        fill(\.footprint, m.footprint); fill(\.diskRead, m.diskRead); fill(\.diskWrite, m.diskWrite)
        // Counters as a whole: a local read that got only one of the two calls keeps its partial set.
        fill(\.energyNJ, m.energyNJ); fill(\.wakeups, m.wakeups); fill(\.counters, m.counters)
        fill(\.priority, m.priority); fill(\.nice, m.nice); fill(\.openFiles, m.openFiles)
        fill(\.compressed, m.compressed); fill(\.jetsam, m.jetsam); fill(\.suspendCount, m.suspendCount)
        return took
    }

    /// Bundle (.app) that owns the executable, if any.
    var bundlePath: String? {
        guard let p = path, let r = p.byteRange(of: ".app/", backwards: true) else { return nil }
        return String(p[..<r.lowerBound]) + ".app"
    }

    /// For an app extension inside an app: that app's name.
    var containingAppName: String? {
        guard path?.containsBytes(".appex/") == true, let b = bundlePath else { return nil }
        return ((b as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}

struct Ghost: Identifiable, Sendable {
    /// Also the row id of this group in the Responsible / parent tree: -pid - 1 for a known dead pid, below
    /// -1,000,000 for a previous instance known only by its coalition (process ids are >= 0, pids < 100,000).
    var id: Int
    /// nil when LaunchServices only tells us the coalition of an earlier instance, not its pid.
    var deadPid: pid_t?
    var detail: String { deadPid.map { "exited pid \($0)" } ?? "previous instance" }
    var name: String
    var lsApp: LSApp?
    var survivors: [ProcInfo]
}

/// What the process list shows with no column sort. Raw values are persisted in @AppStorage("grouping").
enum Grouping: String, CaseIterable, Identifiable, Codable {
    case smart = "Smart"
    // A process goes under its responsible process when that's another process, else under its parent.
    case responsible = "Responsible tree"   // raw value kept stable: it's persisted in @AppStorage("grouping")
    case flat = "Flat"
    // The flat list grouped by one field (View ▸ Group ▸ Group flat list by).
    case bySigner = "By signer"
    case byUser = "By user"
    case byDomain = "By launchd domain"
    case bySandbox = "By sandbox"
    case byArch = "By architecture"
    case bySession = "By session"
    var id: String { rawValue }
    var label: String { self == .responsible ? "Responsible / parent tree" : rawValue }
    static let trees: [Grouping] = [.smart, .responsible, .flat]
    static let pivots: [Grouping] = [.bySigner, .byUser, .bySession, .byDomain, .bySandbox, .byArch]
    /// The pivot's field name, for the submenu ("Signer").
    var pivotTitle: String {
        switch self {
        case .bySigner: "Signer"
        case .byUser: "User"
        case .byDomain: "launchd domain"
        case .bySandbox: "Sandbox"
        case .byArch: "Architecture"
        case .bySession: "Login session"
        default: label
        }
    }
}

/// A row in the process table: a real process, or a synthetic group (dead responsible app / coalition).
/// A process as a tree row holds it: by reference. A ProcInfo is some 1.5 KB of fields, dozens of them strings,
/// and a tree build moves its rows many times (grouping, pruning, sorting, handing the tree to the outline):
/// each move copied all of that and retained every string. Never changed once made.
final class ProcBox: Sendable {
    let info: ProcInfo
    init(_ info: ProcInfo) { self.info = info }
}

struct ProcNode: Identifiable, Sendable {
    enum Kind: UInt8, Sendable {
        case process
        case group      // coalition, sub-group of a Smart category
        case ghost      // Left Behind group
        case category   // Smart tree top level
        case unit       // Smart tree: an app or job with its helpers; a group row like the others
    }

    var id: Int
    /// The row's process, nil for a group row. Held in a ProcBox, so a row is cheap to copy.
    var proc: ProcInfo? {
        get { box?.info }
        set { box = newValue.map(ProcBox.init) }
    }
    private(set) var box: ProcBox?
    var title: String
    var subtitle: String = ""
    var isGhost = false
    var children: [ProcNode]?
    var kind: Kind = .process
    var category: ProcCategory?
    /// A unit row's main process (its icon, and the group inspector's link to it).
    var rootPid: pid_t?
    /// Rows with a fixed order sort before their siblings, in this order, whatever the sort column.
    var fixedOrder: Int?
    /// Pinned to the top (Pins): the row itself, for its pin mark. Filled in by `Store.sorted`.
    var pinned = false
    /// The lowest pin rank of the row and the rows under it; rows with one sort first, before fixed order.
    var pinRank: Int?
    /// A group row above already names this row's extension point, so the name cell doesn't repeat it.
    var extensionPointShownAbove = false
    /// Starts collapsed in the outline until the user opens it (or a search is active).
    var startsCollapsed = false
    /// Processes in the subtree before / after the search filter; and for a category, its top-level units.
    var totalCount = 0
    var shownCount = 0
    var unitCount = 0

    /// Group rows: their value in each shown column (Column.GroupRule), filled in by `Store.sorted`.
    var groupValues: [String: CellValue] = [:]
    /// The row's value in the sort column.
    var sortValue: CellValue = .empty
    /// Own value, or the subtree total for rows without a process. Filled in by `Store.sorted`:
    /// computing it on read re-walked the whole subtree on every sort comparison.
    var cpuKey: Double = 0
    var memKey: UInt64 = 0
    /// -1 when neither counter could be read (anywhere in the subtree, for group rows), so unknown
    /// sorts apart from (and below) a real zero.
    var diskKey: Int64 = -1

    init(id: Int, proc: ProcInfo?, title: String, subtitle: String = "", isGhost: Bool = false, children: [ProcNode]? = nil,
         kind: Kind = .process, category: ProcCategory? = nil, rootPid: pid_t? = nil, fixedOrder: Int? = nil,
         extensionPointShownAbove: Bool = false, startsCollapsed: Bool = false) {
        self.id = id
        box = proc.map(ProcBox.init)
        self.title = title
        self.subtitle = subtitle
        self.isGhost = isGhost
        self.children = children
        self.kind = kind
        self.category = category
        self.rootPid = rootPid
        self.fixedOrder = fixedOrder
        self.extensionPointShownAbove = extensionPointShownAbove
        self.startsCollapsed = startsCollapsed
    }

    static func disk(_ p: ProcInfo) -> Int64 {
        guard p.diskRead != nil || p.diskWrite != nil else { return -1 }
        return Int64(clamping: (p.diskRead ?? 0) &+ (p.diskWrite ?? 0))
    }

    func matches(_ q: String) -> Bool {
        if title.localizedCaseInsensitiveContains(q) || subtitle.localizedCaseInsensitiveContains(q) { return true }
        guard let p = proc else { return false }
        if String(p.pid) == q { return true }
        // "ttys003": a shell shown without a terminal row of its own (see SmartTree.roleGroups).
        if let t = p.tty, q.lowercased().hasPrefix("tty"),
           SmartTree.ttyName(t).localizedCaseInsensitiveContains(q) { return true }
        return [p.path, p.signer, p.signID, p.launchdLabel, p.lsAppName, p.user, p.extensionPoint.map(ExtensionInfo.title),
                p.commandLine]
            .compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(q) }
    }
}

@MainActor
@Observable
final class Store {
    var procs: [pid_t: ProcInfo] = [:] { didSet { dataGen &+= 1 } }
    var lsApps: [LSApp] = [] { didSet { dataGen &+= 1 } }
    var jobs: [LaunchdJob] = []
    /// Running jobs of the system and user domains; they only label processes.
    @ObservationIgnored var otherJobs: [LaunchdJob] = []
    var btm: [BTMItem] = [] {
        didSet { btmOwners = BTM.ownerIndex(btm); btmItems = BTM.itemIndex(btm); dataGen &+= 1 }
    }
    /// BTM.ownerIndex of btm, for the Smart tree.
    @ObservationIgnored private(set) var btmOwners: [String: [String]] = [:]
    /// BTM.itemIndex of btm, for the Name column's registration glyphs.
    @ObservationIgnored private(set) var btmItems: [String: [BTMItem]] = [:]
    var btmLoading = false
    /// Set once a load finished and produced a record list (possibly empty), so "nothing loaded yet",
    /// "loaded, no records" and "failed" (btmError) look different.
    var btmLoaded = false
    var btmError: String?
    var paused = false
    /// Seconds between timer refreshes now (Tuning.windowIntervalNow); 0 while they are stopped.
    var interval: Double = 2
    var lastRefresh = Date()
    /// Bumped by each full refresh (Refresh button, coming back on screen), not by timer ticks: views
    /// that read something the snapshot doesn't carry (a cwd, LaunchServices details) reload on it.
    var fullRefreshGen = 0
    var refreshMillis = 0
    /// Why the last refresh couldn't read the process list (the table keeps the previous snapshot).
    var refreshError: String?

    /// Bumped whenever an input of nodes() changes, so the table's tree is only rebuilt when needed.
    @ObservationIgnored private(set) var dataGen = 0
    /// How many processes each filter chip's predicate matches (FilterChip), by its source: counted by each
    /// refresh in the background, and assigned only when a count changed.
    private(set) var chipCounts: [String: Int] = [:]
    nonisolated static func chipCounts(_ ctx: TableContext) -> [String: Int] {
        let now = Date()
        var out: [String: Int] = [:]
        for c in FilterChip.allCases {
            guard let p = try? PredicateFields.compile(c.source, context: ctx) else { continue }
            out[c.source] = ctx.procs.values.reduce(0) { $0 + (p.test($1, now) ? 1 : 0) }
        }
        return out
    }
    /// The data as the columns read it (see `context`), for the data generation it was made from.
    @ObservationIgnored private var contextCache: (gen: Int, ctx: TableContext)?
    /// Bumps each time nodes() actually rebuilds, so views can skip work when it returned the cached tree.
    @ObservationIgnored private(set) var nodesVersion = 0
    @ObservationIgnored private var nodesCache: (gen: Int, pins: Int, spec: TreeSpec, nodes: [ProcNode])?
    /// The tree the table last asked for: each refresh builds it for the new data in its background task.
    @ObservationIgnored private var treeSpec: TreeSpec?
    /// Filter predicates compiled so far, by trimmed source (nil: doesn't parse). See predicate(_:).
    @ObservationIgnored var compiledPredicates: [String: PredicateFields.Compiled?] = [:]
    /// The extra reads the filter predicate's fields need, read as if their columns were shown.
    @ObservationIgnored var predicateReads: ExtraReads = []

    private(set) var signCache: [String: SignInfo] = [:]
    /// Each process's command line, by codeKey: read once per process (and again after it execs), since
    /// argv doesn't change while the same code runs. nil: tried and couldn't be read.
    @ObservationIgnored private var argvCache: [String: String?] = [:]
    @ObservationIgnored private var readingArgv = false
    /// `parent bundle identifier` of each third-party launchd job's process, by process key (nil: the job has
    /// none). ~6 ms per job and ~25 such jobs, so read once per process in the background.
    @ObservationIgnored private var jobParentCache: [String: String?] = [:]
    @ObservationIgnored private var readingJobParents = false
    /// launchd pid domains read so far, by host key: the keys of the services running in it (nil: couldn't
    /// be read, e.g. a root process without the helper). See fillPidDomains.
    @ObservationIgnored private var domainReads: [String: [String]?] = [:]
    /// Inverse of domainReads: child key → host key. Applied by every snapshot.
    @ObservationIgnored private var domainHostOf: [String: String] = [:]
    @ObservationIgnored private var readingDomains = false
    /// When the domains that host services were last read again (fillPidDomains).
    @ObservationIgnored private var hostsReadAt = Date.distantPast
    /// Services whose host was looked for already, by key: asked about once.
    @ObservationIgnored private var domainAsked: Set<String> = []
    /// Programs whose domain hosted services in this or an earlier run, by executable path: read first.
    @ObservationIgnored private var domainHostPaths = Set(UserDefaults.standard.stringArray(forKey: Store.domainHostPathsKey) ?? [])
    private static let domainHostPathsKey = "pidDomain.hostPaths"
    /// Programs whose domain was read and hosted nothing: not read again in later runs, unless a service points
    /// at them.
    @ObservationIgnored private var domainEmptyPaths = Set(UserDefaults.standard.stringArray(forKey: Store.domainEmptyPathsKey) ?? [])
    @ObservationIgnored private var domainEmptyUnsaved = 0
    private static let domainEmptyPathsKey = "pidDomain.emptyPaths"
    private func saveDomainEmptyPaths() {
        domainEmptyUnsaved = 0
        UserDefaults.standard.set(Array(domainEmptyPaths.prefix(4000)), forKey: Self.domainEmptyPathsKey)
    }
    /// A process's domain is read once it has run this long: most of what launchd starts (mdworker_shared and
    /// the like) is gone within seconds, and reading each cost a launchctl run, several a second.
    private static let domainSettle: TimeInterval = 10
    /// Hosts' domains are read again at most this often, however many launchd children appear.
    private static let hostRereadEvery: TimeInterval = 15
    /// The extra reads the shown columns need (see Column.reads); set by the process table.
    @ObservationIgnored var extraReads: ExtraReads = []
    /// Inspector pages showing network usage (Resources, the group page): while any is, refreshes read the
    /// network rates as the network columns do.
    @ObservationIgnored var networkViewers = 0
    /// Inspector pages showing the jetsam band and memory limit: while any is, refreshes read them.
    @ObservationIgnored var jetsamViewers = 0
    /// Other optional reads inspector pages show (nice, compressed, open files, GPU…), counted per read:
    /// while any page shows one, refreshes make it as the column would.
    @ObservationIgnored private var viewerCounts: [Int: Int] = [:]
    var viewerReads: ExtraReads {
        viewerCounts.reduce(into: ExtraReads()) { if $1.value > 0 { $0.insert(ExtraReads(rawValue: $1.key)) } }
    }
    func addViewer(_ r: ExtraReads) {
        for bit in 0..<16 where r.rawValue & (1 << bit) != 0 { viewerCounts[1 << bit, default: 0] += 1 }
    }
    func removeViewer(_ r: ExtraReads) {
        for bit in 0..<16 where r.rawValue & (1 << bit) != 0 { viewerCounts[1 << bit, default: 0] -= 1 }
    }
    /// Each process's counters at the last refresh, by key: CPU % and the rate columns divide the change
    /// by the time between the two readings.
    @ObservationIgnored private var prevSamples: [String: Sample] = [:]
    /// Recent values per process key, for sparklines (see History).
    @ObservationIgnored private(set) var history: [String: History] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var signing = false
    /// Signatures by the code's hash (cdhash), so a program is inspected once however many processes run it.
    @ObservationIgnored private var signByHash: [String: SignInfo] = [:]
    /// Signature lookups set aside because the code read wasn't the code running, by codeKey (fillSignatures).
    @ObservationIgnored private var signSkips: [String: Int] = [:]
    /// The same for command lines (fillCommandLines).
    @ObservationIgnored private var argvSkips: [String: Int] = [:]
    var helperState: HelperClient.State = .notInstalled
    var helperError: String?
    @ObservationIgnored private var probeTimer: Timer?

    init() {
        // From launch, so the network totals cover everything since the app started.
        NetSampler.shared.startAtLaunch()
        // From launch, so app launches can be traced to whoever asked for them (`open`, a shell, an agent).
        LaunchWatcher.shared.start()
        // A dropped helper connection (helper died, disabled, replaced): re-probe right away rather than
        // keep showing it as running until the next probe.
        HelperClient.shared.onConnectionLost = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.probeAfterConnectionLoss() } }
        }
        Power.install()
        watchRegistries()
        probeHelper()
        refresh()
        schedule()
        // The cadence follows the settings, the power source and whether the app is in front.
        for name in [Tuning.didChange, NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            visibilityObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let was = self.interval
                    self.schedule()
                    // Coming to the front after a slower stretch: show fresh figures at once.
                    if n.name == NSApplication.didBecomeActiveNotification, self.onScreen, !self.paused, self.interval != was {
                        self.refresh(full: false)
                    }
                }
            })
        }
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSApplication.didHideNotification, NSApplication.didUnhideNotification,
            NSApplication.didChangeOcclusionStateNotification,
        ]
        visibilityObservers += names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Let a closing/miniaturizing window finish changing state before reading it.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.visibilityChanged() } }
            }
        }
    }

    /// Whether any of our windows is on screen. Hidden, minimized, closed, fully covered, on another
    /// Space or behind a locked screen all count as off screen; nothing is refreshed then, so the app
    /// costs ~0 while it sits in the background.
    @ObservationIgnored private(set) var onScreen = true
    private static let assumeVisible = ProcessInfo.processInfo.environment["PROCXRAY_ASSUME_VISIBLE"] != nil
    @ObservationIgnored private var visibilityObservers: [NSObjectProtocol] = []

    private func visibilityChanged() {
        // Titled windows only: the menu bar item and its popover are windows too, always "visible", and
        // keeping the process table refreshing for them would cost the snapshot every tick for nothing (the
        // popover has its own light sampler, AmbientMonitor).
        // PROCXRAY_ASSUME_VISIBLE: for profiling in a session that's never on screen (a second login, where
        // every window counts as occluded).
        let visible = !NSApp.isHidden && NSApp.windows.contains {
            $0.styleMask.contains(.titled) && $0.isVisible && !$0.isMiniaturized
                && ($0.occlusionState.contains(.visible) || Self.assumeVisible)
        }
        guard visible != onScreen else { return }
        onScreen = visible
        if ProcessInfo.processInfo.environment["PROCXRAY_DEBUG"] != nil { NSLog("Proc X-Ray on screen: %d", visible ? 1 : 0) }
        if visible {
            probeHelper()
            // Paused means frozen: coming back on screen must not swap in new figures (Resume or Refresh does).
            if !paused {
                // A CPU % averaged over the whole off-screen stretch would be misleading: start a fresh
                // baseline and take the second sample shortly after so the column fills in quickly.
                prevSamples = [:]
                refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self, !self.paused else { return }
                    self.refresh(full: false)
                }
            }
        }
        schedule()
    }

    /// Only the latest probe may publish: an older one still in flight (up to 3 s) would otherwise
    /// overwrite a newer answer, e.g. "running" landing after Uninstall.
    @ObservationIgnored private var probeGen = 0

    /// Re-probing on every lost connection can loop: the probe opens a connection, it drops, that probes
    /// again. Each probe asks SMAppService for the status, and backgroundtaskmanagementd answers by
    /// re-hashing the whole app binary (~18 MB, uncached), so the loop kept it at ~40% CPU. The first loss
    /// after a quiet minute re-probes at once; repeated ones back off from 2 s to 60 s, one pending at a time.
    @ObservationIgnored private var lossProbePending = false
    @ObservationIgnored private var lastLossProbe = Date.distantPast
    @ObservationIgnored private var lossBackoff: TimeInterval = 0

    private func probeAfterConnectionLoss() {
        guard !lossProbePending else { return }
        lossProbePending = true
        let since = Date().timeIntervalSince(lastLossProbe)
        lossBackoff = since > 60 ? 0 : min(max(lossBackoff * 2, 2), 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, lossBackoff - since)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lossProbePending = false
                self.lastLossProbe = Date()
                self.probeHelper()
            }
        }
    }

    func probeHelper() {
        probeGen &+= 1
        let gen = probeGen
        Task.detached {
            let s = HelperClient.shared.probe()
            await MainActor.run {
                guard gen == self.probeGen else { return }
                AmbientMonitor.shared.helperRunning = s.isRunning
                NetSampler.shared.setHelper(s.isRunning)
                if self.helperState != s {
                    // Other users' processes the app couldn't read: the helper can, so try them again.
                    if s.isRunning {
                        self.argvCache = self.argvCache.filter { $0.value != nil }
                        self.domainReads = self.domainReads.filter { $0.value != nil }
                    }
                    self.helperState = s
                    // As root, sfltool doesn't prompt, so Background Items can be read up front instead of on request.
                    if s.isRunning, !self.btmLoaded { self.loadBTM() }
                }
            }
        }
    }

    func installHelper() {
        do {
            try HelperClient.shared.register()
            helperError = nil
        } catch {
            // register() throws "Operation not permitted" when the daemon is registered but awaiting the
            // user's approval in Login Items — that's the normal first-run path, not an error.
            if HelperClient.shared.service.status == .requiresApproval {
                helperError = nil
                HelperClient.shared.openLoginItems()
            } else {
                helperError = error.localizedDescription
            }
        }
        probeHelper()
    }

    func uninstallHelper() {
        do { try HelperClient.shared.unregister(); helperError = nil } catch { helperError = error.localizedDescription }
        probeHelper()
    }

    /// Starts the timers that fit the app's state now: none off screen, and the refresh timer at the cadence the
    /// settings give for an app in front or behind, on mains or battery (Tuning.windowIntervalNow).
    func schedule() {
        timer?.invalidate()
        timer = nil
        probeTimer?.invalidate()
        probeTimer = nil
        guard onScreen else { return }
        // Its own timer, which Pause doesn't stop: a frozen table must not hide that the helper went away.
        let pt = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.probeHelper() }
        }
        pt.tolerance = 2
        RunLoop.main.add(pt, forMode: .common)
        probeTimer = pt
        // No app object in the command-line modes (--bench, --dump), which make a Store too.
        let active = (NSApp as NSApplication?)?.isActive ?? true
        guard let every = Tuning.windowIntervalNow(active: active || Self.assumeVisible) else {
            if interval != 0 { interval = 0 }
            return
        }
        if interval != every { interval = every }
        let t = Timer(timeInterval: every, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.paused else { return }
                self.refresh(full: false)
            }
        }
        t.tolerance = every * 0.2   // lets the system coalesce our wakeups with others
        RunLoop.main.add(t, forMode: .default)   // as before: no refreshes mid-scroll or while a menu is open
        timer = t
    }

    /// The registries a snapshot labels processes from, and when each is read again.
    ///
    /// launchd's jobs (the login session's and the system's) are asked of launchd in-process, ~8 ms, so they are
    /// read again whenever a process came or went, at most every Tuning.registrySpacing seconds. LaunchServices
    /// (`lsappinfo`) and launchd's user domain (`launchctl print`) each start a tool, so they wait for a reason:
    /// LaunchServices' list of running apps changed (background-only ones included), or an app came forward or
    /// hid. Failing that they are read every lsFallback seconds, for what changes without either (a job loaded
    /// into the user domain). A manual refresh and coming back on screen read everything.
    @ObservationIgnored private var lsDirty = true
    private static let lsFallback: TimeInterval = 300
    @ObservationIgnored private var runningAppsObservation: NSKeyValueObservation?
    @ObservationIgnored private var jobsDirty = true
    @ObservationIgnored private var lsReadAt = Date.distantPast
    @ObservationIgnored private var jobsReadAt = Date.distantPast
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []

    private func watchRegistries() {
        // Every app LaunchServices knows, the ones without a Dock icon or any UI too.
        runningAppsObservation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.lsDirty = true } }
        }
        let nc = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        workspaceObservers = names.map { name in
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lsDirty = true }
            }
        }
    }

    func refresh(full: Bool = true) {
        guard !refreshing else { return }
        refreshing = true
        let prev = prevSamples
        let cache = signCache
        let argv = argvCache
        let jobParents = jobParentCache
        let hosts = domainHostOf
        let extras = extraReads.union(predicateReads).union(viewerReads)
            .union(networkViewers > 0 ? .network : []).union(jetsamViewers > 0 ? .jetsam : [])
        let useHelper = helperState.isRunning
        let now = Date()
        let spacing = Tuning.registrySpacing
        let readLS = full || lsApps.isEmpty
            || (lsDirty && now.timeIntervalSince(lsReadAt) >= spacing)
            || now.timeIntervalSince(lsReadAt) >= Self.lsFallback
        let readJobs = full || readLS || jobs.isEmpty || (jobsDirty && now.timeIntervalSince(jobsReadAt) >= spacing)
        if readLS { lsDirty = false; lsReadAt = now }
        if readJobs { jobsDirty = false; jobsReadAt = now }
        let recheck = full || ticksSinceRecheck + 1 >= Self.recheckEvery
        ticksSinceRecheck = recheck ? 0 : ticksSinceRecheck + 1
        // The processes this refresh doesn't read: those that used no CPU at their last reading (or couldn't be
        // read at all), each in its turn so that every one is read every idleReadEvery refreshes.
        refreshTick &+= 1
        let every = Tuning.idleReadEvery
        var skip: Set<pid_t> = []
        if !full, every > 1, !prev.isEmpty {
            let tick = refreshTick
            for p in procs.values where p.pid > 0 && (Int(p.pid) &+ tick) % every != 0 {
                if p.cpuNanos == nil || (p.rates != nil && (p.cpuPercent ?? 0) < 0.05) { skip.insert(p.pid) }
            }
        }
        let reuse = skip.isEmpty ? [:] : procs
        let giveBack = refreshTick % Self.giveBackEvery == 0
        let oldLS = lsApps, oldJobs = jobs, oldOther = otherJobs
        let btmOwners = btmOwners
        let spec = treeSpec
        let pins = Pins.shared.ranks
        let genAtStart = dataGen
        // A timer refresh asks the helper only for what the app couldn't read last time and what started since
        // (a second's margin for the time the last snapshot took); a full one asks for everything.
        let ask: HelperAsk? = full || prev.isEmpty ? nil
            : HelperAsk(pids: prev.values.lazy.filter { $0.needsHelper && !skip.contains($0.pid) }.map(\.pid),
                        since: lastRefresh.timeIntervalSince1970 - 1 - Double(refreshMillis) / 1000)
        Task.detached(priority: .userInitiated) {
            let t0 = DispatchTime.now().uptimeNanoseconds
            // Ask the helper first, but collect local data while it answers; the snapshot waits for the
            // helper only after that, and never longer than helperBudget (it normally takes ~10 ms).
            let priv = useHelper ? Pending { HelperClient.shared.metrics(ask, extras: extras, timeout: Self.helperBudget)?.metrics } : nil
            let perfR = PerfStages.begin()
            let ls = readLS ? LSAppInfo.list() : oldLS
            let jobs = readJobs ? Launchd.list() : oldJobs
            let other = readLS ? Launchd.otherDomains()
                : readJobs ? Launchd.systemJobs() + oldOther.filter { $0.domain == "user" } : oldOther
            PerfStages.end(.registries, perfR)
            let perfS = PerfStages.begin()
            var marked = Self.snapshot(prev: prev, signCache: cache, argvCache: argv, jobParents: jobParents, domainHosts: hosts, extras: extras, priv: { priv?.wait() },
                                       ls: ls, jobs: jobs, otherJobs: other, recheck: recheck, reuse: reuse, skip: skip)
            let leftBehind = Self.markLeftBehind(&marked.procs, lsApps: marked.ls)
            PerfStages.end(.snapshot, perfS)
            let snap = marked
            // The table's tree for the new data, built here so the main thread only swaps it in.
            let ctx = TableContext(procs: snap.procs, lsApps: snap.ls, btmOwners: btmOwners, signs: cache)
            let tree = snap.error == nil ? spec.map { s in PerfStages.measure(.treeBuildBackground) { TreeBuilder.build(s, ctx, pins: pins) } } : nil
            let chips = snap.error == nil ? Self.chipCounts(ctx) : [:]
            let ms = Int((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
            await MainActor.run {
                let perfM = PerfStages.begin(); defer { PerfStages.end(.publish, perfM) }
                self.refreshError = snap.error
                guard snap.error == nil else {
                    // Keep showing the last good snapshot rather than an empty table.
                    self.refreshing = false
                    return
                }
                // A process came or went: launchd's jobs may have changed with it.
                if snap.procs.count != self.procs.count || snap.procs.contains(where: { self.procs[$0.key]?.start != $0.value.start }) {
                    self.jobsDirty = true
                }
                // The tree fits only if nothing it was built from changed meanwhile: the view, a pin, or data a
                // background read or Background Items merged in while the snapshot was being taken.
                let treeFits = spec == self.treeSpec && self.dataGen == genAtStart
                self.procs = snap.procs
                Pins.shared.prune()
                if readLS { self.lsApps = snap.ls }
                if readJobs || readLS {
                    self.jobs = snap.jobs
                    self.otherJobs = snap.otherJobs
                }
                if treeFits, let tree, let spec, pins.version == Pins.shared.version {   // prune() may have dropped a pin
                    self.contextCache = (self.dataGen, ctx)
                    self.compiledPredicates.removeAll()
                    self.nodesCache = (self.dataGen, pins.version, spec, tree)
                    self.nodesVersion &+= 1
                }
                if chips != self.chipCounts { self.chipCounts = chips }
                self.prevSamples = snap.samples
                self.recordHistory(snap.procs)
                if full { self.fullRefreshGen &+= 1 }
                if leftBehind != self.ghostCount { self.ghostCount = leftBehind }
                self.lastRefresh = Date()
                self.refreshMillis = ms
                self.refreshing = false
                if Tuning.checksSignatures { self.fillSignatures() }
                self.fillCommandLines()
                if Tuning.readsPidDomains { self.fillPidDomains() }
                self.fillJobParents()
            }
            // Every refresh builds and drops a few megabytes of short-lived tables (the processes, their samples,
            // the tree), and the heap keeps the pages they leave free as dirty memory. Handing those back now and
            // then is what keeps the footprint near what the app really holds.
            if giveBack { malloc_zone_pressure_relief(nil, 0) }
        }
    }

    /// Free heap pages are given back to the system every this many refreshes (see refresh).
    private static let giveBackEvery = 15

    func benchRecordHistory(_ procs: [pid_t: ProcInfo]) { recordHistory(procs) }

    /// Appends this refresh to each process's history and forgets processes that are gone.
    private func recordHistory(_ procs: [pid_t: ProcInfo]) {
        // Taken out of the old table, so each series is uniquely owned and the append is in place: a copy left
        // in `history` made every append copy all five arrays of every process.
        let capacity = Tuning.historyLength
        guard capacity > 0 else { if !history.isEmpty { history = [:] }; return }
        var old = history
        history = [:]
        var next: [String: History] = [:]
        next.reserveCapacity(procs.count)
        for p in procs.values {
            var h = old.removeValue(forKey: p.key) ?? History(capacity: capacity)
            h.append(p, capacity: capacity)
            next[p.key] = h
        }
        history = next
    }

    /// Code-signing lookups are the slow part; do the missing ones in the background and merge.
    private func fillSignatures() {
        guard !signing else { return }
        // The same code (cdhash) has the same signature whichever process runs it: a tool started over and over
        // (launchctl, mdworker, a shell's commands) is inspected once, not once per process.
        var known: [String: SignInfo] = [:]
        var missing: [(String, pid_t, String?, String?)] = []
        for p in procs.values where signCache[p.codeKey] == nil {
            if let h = p.cdhash, let s = signByHash[h] { known[p.codeKey] = s } else { missing.append((p.codeKey, p.pid, p.path, p.cdhash)) }
        }
        if !known.isEmpty { signCache.merge(known) { a, _ in a } }
        guard !missing.isEmpty else { return }
        signing = true
        let skipped = signSkips
        Task.detached(priority: .utility) {
            let perf0 = PerfStages.begin()
            var acc: [String: SignInfo] = [:]
            var skips: [String: Int] = [:]
            for (k, pid, path, expected) in missing {
                var info = CodeSign.inspect(pid: pid, path: path)
                // An exec between the snapshot and this lookup: the details belong to other code. Skip;
                // the next snapshot carries the new cdhash and asks again.
                if let e = expected, let got = info.cdHash, e != got {
                    // Still different on the third look: no exec, the file on disk was replaced since the
                    // process started. Asking again on every refresh, for good, was a signature check per tick.
                    guard (skipped[k] ?? 0) >= 2 else { skips[k] = (skipped[k] ?? 0) + 1; continue }
                    info.error = "Read from the file on disk, which is not the code that is running (replaced since launch?)."
                }
                acc[k] = info
            }
            let found = acc, newSkips = skips
            PerfStages.end(.fillSignatures, perf0)
            await MainActor.run {
                let perfM = PerfStages.begin(); defer { PerfStages.end(.fillMerge, perfM) }
                self.signSkips = newSkips
                if self.signByHash.count > 4000 { self.signByHash.removeAll(keepingCapacity: true) }
                // Only what was read from the running code itself: a file on disk answers for that path alone.
                for (_, info) in found where info.error == nil { if let h = info.cdHash { self.signByHash[h] = info } }
                let live = Set(self.procs.values.map(\.codeKey))
                // Assigned once, and only when something changes: every assignment redraws what shows a signature.
                var cache = self.signCache
                cache.merge(found) { a, _ in a }
                if cache.count != live.count || !found.isEmpty { cache = cache.filter { live.contains($0.key) } }
                if !found.isEmpty || cache.count != self.signCache.count { self.signCache = cache }
                // snapshot() already applied every older cache entry; patch only the processes that were
                // just inspected, on a local copy, and publish once. Writing self.procs[pid] in a loop
                // copied the whole dictionary per write and invalidated the table ~700 times.
                guard self.publishFill(found.count) else { self.signing = false; return }
                var procs = self.procs
                var changed = false
                for (pid, p) in procs {
                    guard let s = found[p.codeKey], p.signer != s.shortSigner || p.signID != s.identifier else { continue }
                    procs[pid]!.signer = s.shortSigner; procs[pid]!.signID = s.identifier
                    changed = true
                }
                if changed { self.procs = procs }
                self.signing = false
            }
        }
    }

    /// Whether a fill pass patches the table now. The few processes that started since the last refresh wait
    /// for the next one, which applies them from the caches: publishing them now rebuilt the whole table a
    /// second time every refresh. A big batch (launch, a full refresh) shows at once, and so does anything
    /// while paused, when no refresh is coming.
    private func publishFill(_ count: Int) -> Bool { paused || count > 8 }

    /// Reads argv for processes not in argvCache yet, in the background, and merges it like signatures.
    private func fillCommandLines() {
        guard !readingArgv else { return }
        let missing = procs.values.filter { argvCache[$0.codeKey] == nil }.map { ($0.codeKey, $0.pid, $0.start, $0.cdhash) }
        guard !missing.isEmpty else { return }
        readingArgv = true
        let helper = helperState.isRunning
        let skipped = argvSkips
        Task.detached(priority: .utility) {
            let perf0 = PerfStages.begin()
            var acc: [String: String?] = [:]
            var skips: [String: Int] = [:]
            var buf: [UInt8] = []
            for (k, pid, start, expected) in missing {
                let args = Native.argsEnv(pid, buffer: &buf)?.args
                    ?? (helper ? HelperClient.shared.argsEnv(pid)?.args : nil)
                // Read from another process (the pid was reused) or other code (it exec'd since the
                // snapshot): leave it for the next refresh, whose key matches what's running. A process this
                // keeps happening to (the check itself can't read it) is given up on after the third time.
                guard Native.isSame(pid, start: start), Native.cdhash(pid) == expected else {
                    if (skipped[k] ?? 0) >= 2 { acc[k] = .some(nil) } else { skips[k] = (skipped[k] ?? 0) + 1 }
                    continue
                }
                // .some: assigning the bare optional (inferred as String??) removed the key for unreadable argv,
                // so every unreadable process was read again on every refresh.
                acc[k] = .some(args.map(Self.joinArgs))
            }
            let found = acc, newSkips = skips
            PerfStages.end(.fillArgv, perf0)
            await MainActor.run {
                let perfM = PerfStages.begin(); defer { PerfStages.end(.fillMerge, perfM) }
                self.argvSkips = newSkips
                self.argvCache.merge(found) { a, _ in a }
                let live = Set(self.procs.values.map(\.codeKey))
                self.argvCache = self.argvCache.filter { live.contains($0.key) }
                guard self.publishFill(found.count) else { self.readingArgv = false; return }
                var procs = self.procs
                var changed = false
                for (pid, p) in procs {
                    guard let c = found[p.codeKey] else { continue }
                    procs[pid]!.commandLine = c; procs[pid]!.commandLineRead = true
                    changed = true
                }
                if changed { self.procs = procs }
                self.readingArgv = false
            }
        }
    }

    /// Reads launchd pid domains in the background, to name the process that hosts each extension and XPC service.
    /// Each read is a `launchctl print` (through the helper for other users' processes), and only ~1 process in 20
    /// hosts anything, so the reads are rationed rather than made for every process at once (a thousand tool runs
    /// at launch, measured):
    /// - first the processes a new service points at (its responsible process), then those running a program that
    ///   hosted something before (remembered across launches), a few per refresh;
    /// - every other process once it has run domainSettle seconds, two per refresh, unless its program was read
    ///   in an earlier run and hosted nothing (remembered too): after the first run's sweep, a launch reads the
    ///   few dozen known hosts and then starts nothing more;
    /// - domains that listed services are read again only after a new extension or XPC service appears, at most
    ///   every hostRereadEvery seconds: only such a process can have joined one.
    private func fillPidDomains() {
        guard !readingDomains else { return }
        // Not this app's own children (launchctl, lsappinfo): they host no domain, and reading one spawns
        // launchctl, which the next refresh would find as a new process to read, every refresh.
        let me = getpid()
        let now = Date()
        let settled = procs.values.filter {
            $0.pid > 0 && !$0.isZombie && $0.ppid != me && now.timeIntervalSince($0.start) >= Self.domainSettle
        }
        // Services launchd started that have no host yet and haven't been looked into.
        let orphans = settled.filter {
            $0.ppid == 1 && domainHostOf[$0.key] == nil && !domainAsked.contains($0.key)
                && (SmartTree.isExtension($0) || Registrations.isXPCService($0.path))
        }
        let pointedAt = Set(orphans.compactMap { o in o.responsible.flatMap { $0 != o.pid ? $0 : nil } })
        // A process a new service points at is read even if it was read before: the service is new.
        let first = settled.filter { pointedAt.contains($0.pid) }
        var known: [ProcInfo] = [], rest: [ProcInfo] = []
        for p in settled where domainReads[p.key] == nil && !pointedAt.contains(p.pid) {
            if p.path.map(domainHostPaths.contains) == true { known.append(p) }
            else if p.path.map(domainEmptyPaths.contains) == true { domainReads[p.key] = .some([]) }   // as last time
            else { rest.append(p) }
        }
        for o in orphans where o.responsible.map(pointedAt.contains) == true { domainAsked.insert(o.key) }
        var targets = Array(first.prefix(16)) + known.prefix(8) + rest.prefix(2)
        let rereadHosts = !orphans.isEmpty && now.timeIntervalSince(hostsReadAt) >= Self.hostRereadEvery
        if rereadHosts {
            hostsReadAt = now
            let hostKeys = Set(domainReads.compactMap { k, v in (v?.isEmpty == false) ? k : nil })
            targets += procs.values.filter { hostKeys.contains($0.key) }
            // Asked about now: the hosts' domains read next either list them or they have none.
            for o in orphans { domainAsked.insert(o.key) }
        }
        guard !targets.isEmpty else { return }
        let jobs = targets.map { ($0.pid, $0.start, $0.key, $0.uid == getuid(), $0.path) }
        let keyOf = procs.mapValues(\.key)
        readingDomains = true
        let helper = helperState.isRunning
        Task.detached(priority: .utility) {
            let perf0 = PerfStages.begin()
            var acc: [String: [String]?] = [:]
            var hostPaths: Set<String> = [], emptyPaths: Set<String> = []
            for (pid, start, key, own, path) in jobs {
                let kids = PidDomain.read(pid, ownedByUser: own, viaHelper: helper)
                // The pid was reused while reading: the domain belongs to someone else; the next pass asks again.
                guard Native.isSame(pid, start: start) else { continue }
                // .some keeps "couldn't be read" (nil) cached, as for argv.
                let services = kids.map { $0.compactMap { keyOf[$0] }.filter { $0 != key } }
                acc[key] = .some(services)
                if let path, let services { if services.isEmpty { emptyPaths.insert(path) } else { hostPaths.insert(path) } }
            }
            let found = acc, paths = hostPaths, empties = emptyPaths.subtracting(hostPaths)
            PerfStages.end(.fillDomains, perf0)
            await MainActor.run {
                let perfM = PerfStages.begin(); defer { PerfStages.end(.fillMerge, perfM) }
                self.domainReads.merge(found) { _, b in b }
                let live = Set(self.procs.values.map(\.key))
                self.domainReads = self.domainReads.filter { live.contains($0.key) }
                self.domainAsked = self.domainAsked.filter(live.contains)
                if !paths.isSubset(of: self.domainHostPaths) {
                    self.domainHostPaths.formUnion(paths)
                    UserDefaults.standard.set(Array(self.domainHostPaths.prefix(400)).sorted(), forKey: Self.domainHostPathsKey)
                }
                let newEmpties = empties.subtracting(self.domainHostPaths)
                let stale = self.domainEmptyPaths.intersection(paths)
                if !newEmpties.isSubset(of: self.domainEmptyPaths) || !stale.isEmpty {
                    self.domainEmptyPaths.formUnion(newEmpties)
                    self.domainEmptyPaths.subtract(paths)
                    // Written every so often, not per read: the sweep adds one path per refresh.
                    self.domainEmptyUnsaved += 1
                    if self.domainEmptyUnsaved >= 30 || !stale.isEmpty { self.saveDomainEmptyPaths() }
                } else if self.domainEmptyUnsaved > 0, found.count > 0 {
                    self.saveDomainEmptyPaths()
                }
                var hostOf: [String: String] = [:]
                for (host, kids) in self.domainReads { for k in kids ?? [] { hostOf[k] = host } }
                let changed = hostOf != self.domainHostOf
                self.domainHostOf = hostOf
                if changed, self.publishFill(found.count) {
                    var procs = self.procs
                    Self.applyDomainOwners(&procs, hostOf)
                    self.procs = procs
                }
                self.readingDomains = false
            }
        }
    }

    /// Reads launchd's `parent bundle identifier` for each third-party job process not read yet. Apple's jobs
    /// and LaunchServices app launches (`application.…`) are skipped: none has one.
    private func fillJobParents() {
        guard !readingJobParents else { return }
        let todo = procs.values.compactMap { p -> (pid_t, String, String, String)? in
            guard let l = p.launchdLabel, let d = p.launchdDomain, jobParentCache[p.key] == nil,
                  !l.hasPrefix("com.apple."), !l.hasPrefix("application.") else { return nil }
            return (p.pid, p.key, l, d)
        }
        let live = Set(procs.values.map(\.key))
        jobParentCache = jobParentCache.filter { live.contains($0.key) }
        guard !todo.isEmpty else { return }
        readingJobParents = true
        Task.detached(priority: .utility) {
            let perf0 = PerfStages.begin()
            var found: [String: String?] = [:]
            for (_, key, label, domain) in todo {
                // .some keeps "has none" (nil) cached, as for argv: the bare optional removed the key, so every
                // such job was asked about again on every refresh, one launchctl each.
                found[key] = .some(Launchd.parentBundle(label, domain: domain))
            }
            let result = found
            PerfStages.end(.fillJobParents, perf0)
            await MainActor.run {
                let perfM = PerfStages.begin(); defer { PerfStages.end(.fillMerge, perfM) }
                self.jobParentCache.merge(result) { _, b in b }
                guard self.publishFill(result.count) else { self.readingJobParents = false; return }
                var procs = self.procs
                var changed = false
                for (pid, p) in procs {
                    if let b = result[p.key], p.launchdParentBundle != b { procs[pid]!.launchdParentBundle = b; changed = true }
                }
                if changed { self.procs = procs }
                self.readingJobParents = false
            }
        }
    }

    /// Sets domainOwner on each process from child key → host key, when the host is still the same process.
    nonisolated static func applyDomainOwners(_ procs: inout [pid_t: ProcInfo], _ hostOf: [String: String]) {
        for (pid, p) in procs {
            var owner: ProcInfo?
            if let hk = hostOf[p.key], let hp = hk.split(separator: ":").first.flatMap({ pid_t($0) }),
               let h = procs[hp], h.key == hk, hp != pid { owner = h }
            if procs[pid]!.domainOwner != owner?.pid { procs[pid]!.domainOwner = owner?.pid }
            if procs[pid]!.domainOwnerName != owner?.name { procs[pid]!.domainOwnerName = owner?.name }
        }
    }

    /// argv as one line: arguments with spaces, quotes or nothing in them are single-quoted, as a shell would.
    nonisolated static func joinArgs(_ args: [String]) -> String {
        args.map { a in
            let plain = !a.isEmpty && !a.contains { $0.isWhitespace || "'\"\\$`;&|<>()*?!#~".contains($0) }
            return plain ? a : "'" + a.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }

    func loadBTM() {
        guard !btmLoading else { return }
        btmLoading = true
        let useHelper = helperState.isRunning
        Task.detached {
            // As root the helper's sfltool doesn't need to prompt; without it, sfltool asks for a password.
            let (items, error) = BTM.load(viaHelper: useHelper)
            await MainActor.run {
                if let error {
                    self.btmError = error   // keep the previous list, if any
                } else {
                    self.btm = items; self.btmError = nil; self.btmLoaded = true
                }
                self.btmLoading = false
            }
        }
    }

    func signInfo(for p: ProcInfo) -> SignInfo? { signCache[p.codeKey] }

    // MARK: Snapshot (off main thread)

    /// A value computed on a background queue, collected later with wait().
    final class Pending<T: Sendable>: @unchecked Sendable {
        private var value: T?
        private let done = DispatchSemaphore(value: 0)
        init(_ work: @escaping @Sendable () -> T?) {
            DispatchQueue.global(qos: .userInitiated).async { self.value = work(); self.done.signal() }
        }
        func wait() -> T? { done.wait(); done.signal(); return value }
    }

    struct Snapshot: Sendable {
        var procs: [pid_t: ProcInfo]
        var ls: [LSApp]
        var jobs: [LaunchdJob]
        var otherJobs: [LaunchdJob] = []
        var samples: [String: Sample]
        /// Set when the process list couldn't be read; `procs` is then empty and must not be published.
        var error: String?
    }

    /// `ls` / `jobs`: reuse these instead of re-reading LaunchServices / launchd (nil = read them now).
    /// Longest a refresh waits for the helper's metrics; under the 2 s refresh interval.
    nonisolated static let helperBudget = 1.5
    /// What a refresh found unset or unreadable for a process (not sandboxed, no responsible process, no login
    /// session, no coalition) is asked for again every recheckEvery refreshes and by a full refresh, not every
    /// time; the sandbox also while the process is younger than sandboxSettle.
    nonisolated static let sandboxSettle: TimeInterval = 30
    private static let recheckEvery = 30
    @ObservationIgnored private var ticksSinceRecheck = 0
    @ObservationIgnored private var refreshTick = 0

    /// `priv`: helper metrics, asked for only after the local pass so a slow helper delays just the merge.
    nonisolated static func snapshot(prev: [String: Sample], signCache: [String: SignInfo],
                                     argvCache: [String: String?] = [:],
                                     jobParents: [String: String?] = [:],
                                     domainHosts: [String: String] = [:],
                                     extras: ExtraReads = [],
                                     priv privSource: () -> [Int32: PrivMetrics]? = { nil },
                                     ls: [LSApp]? = nil, jobs: [LaunchdJob]? = nil,
                                     otherJobs: [LaunchdJob]? = nil, recheck: Bool = true,
                                     reuse: [pid_t: ProcInfo] = [:], skip: Set<pid_t> = []) -> Snapshot {
        let ls = ls ?? LSAppInfo.list()
        let jobs = jobs ?? Launchd.list()
        let otherJobs = otherJobs ?? Launchd.otherDomains()
        var labelByPid: [pid_t: LaunchdJob] = [:]
        // gui first: a pid listed in more than one domain keeps its gui label.
        for j in jobs + otherJobs { if let p = j.pid, labelByPid[p] == nil { labelByPid[p] = j } }
        var lsByPid: [pid_t: LSApp] = [:]
        for a in ls { if let p = a.pid { lsByPid[p] = a } }

        // Whole-system reads, one call each, only when a shown column needs them.
        let assertions = extras.contains(.assertions) ? ExtraRead.assertionsByPid() : nil
        let gpu = extras.contains(.gpu) ? ExtraRead.gpuNanosByPid() : nil
        // The native reader runs anyway, so its rates and totals are always taken: one lookup per process.
        let readNet = extras.contains(.network) || NetSampler.alwaysOn
        NetSampler.shared.want(readNet)
        let net = readNet ? NetSampler.shared.current() : nil
        let mach = extras.contains(.machPorts) ? MachLoader.current() : nil
        // Root only: nil (one failed call) in the app, which gets it from the helper instead.
        let jetsam = extras.contains(.jetsam) ? Jetsam.all() : nil

        let now = DispatchTime.now().uptimeNanoseconds
        var users: [uid_t: String] = [:]
        var built: [ProcInfo] = []
        var samples: [String: Sample] = [:]

        let list: [Native.KProc]
        switch Native.listProcesses() {
        case .success(let l): list = l
        case .failure(let e): return Snapshot(procs: [:], ls: ls, jobs: jobs, otherJobs: otherJobs, samples: prev, error: e.message)
        }
        built.reserveCapacity(list.count)
        samples.reserveCapacity(list.count)
        // Indices of `built` taken over from the last refresh as they were (`skip`).
        var reused: Set<Int> = []
        for k in list where k.pid >= 0 {
            // A process that used no CPU at its last reading isn't read on this refresh (Tuning.idleReadEvery):
            // it keeps the last refresh's figures and its sample, so its next reading's rates cover the whole
            // stretch. Only what other processes decide is worked out again: who is left behind, hung, hosted.
            if skip.contains(k.pid), var p = reuse[k.pid], p.start == k.start, let s = prev[p.key] {
                p.ppid = k.ppid
                p.leftBehindGroup = nil; p.leftBehindApp = nil; p.leftBehindPid = nil; p.leftBehindTags = []
                p.notResponding = false
                if let j = labelByPid[k.pid] { p.launchdLabel = j.label; p.launchdDomain = j.domain }
                if let a = lsByPid[k.pid] { p.lsAppName = a.name; p.lsTags = a.stateTags; p.lsType = a.type }
                samples[p.key] = s
                reused.insert(built.count)
                built.append(p)
                continue
            }
            let user = users[k.uid] ?? { let u = Native.userName(k.uid); users[k.uid] = u; return u }()
            var p = ProcInfo(pid: k.pid, ppid: k.ppid, pgid: k.pgid, uid: k.uid, user: user, comm: k.comm,
                             path: nil, start: k.start, stat: k.stat, pflags: k.flags)
            p.cdhash = Native.cdhash(k.pid)
            // What can't change while the same code runs comes from the last refresh: re-reading it for every
            // process was over a quarter of each refresh. An exec (new cdhash) reads it all again.
            // The cdhash is unreadable for some processes (another user's, without the helper); the kernel's name
            // for the process changes on exec too.
            let fixed = prev[p.key]?.fixed.flatMap { $0.cdhash == p.cdhash && $0.comm == k.comm ? $0 : nil }
            if let fixed, let path = fixed.path {
                p.path = path
                p.extensionPoint = fixed.extensionPoint
            } else {
                p.path = Native.path(k.pid)
                if let path = p.path { p.extensionPoint = ExtensionInfo.point(forExecutable: path) }
            }
            // What couldn't be read last time (another user's process, without the helper) is not asked for again
            // on every refresh either: only when `recheck` says so.
            let ask = fixed == nil || recheck
            p.responsible = fixed?.responsible ?? (ask ? Native.responsible(k.pid) : nil)
            p.asid = fixed?.asid ?? (ask ? LoginSessions.asid(k.pid) : nil)
            if let c = fixed?.coalition { p.coalition = c; p.jetsamCoalition = fixed?.jetsamCoalition }
            else if ask, let c = Native.coalition(k.pid) { p.coalition = c.0; p.jetsamCoalition = c.1 }
            _ = p.fill(from: .read(k.pid))
            if let j = labelByPid[k.pid] { p.launchdLabel = j.label; p.launchdDomain = j.domain }
            if let b = jobParents[p.key] { p.launchdParentBundle = b }
            if let a = lsByPid[k.pid] { p.lsAppName = a.name; p.lsTags = a.stateTags; p.lsType = a.type }
            if k.tty != -1 { p.tty = k.tty }   // NODEV: no controlling terminal
            if let s = signCache[p.codeKey] { p.signer = s.shortSigner; p.signID = s.identifier }
            if let c = argvCache[p.codeKey] { p.commandLine = c; p.commandLineRead = true }
            if extras.contains(.openFiles) { p.openFiles = ExtraRead.openFiles(k.pid) }
            if extras.contains(.nice) { p.nice = ExtraRead.nice(k.pid) }
            if extras.contains(.compressed) { p.compressed = ExtraRead.compressed(k.pid) }
            if extras.contains(.suspended) { p.suspendCount = TaskBasic.suspendCount(k.pid) }
            if let assertions { p.assertions = assertions[k.pid] ?? [] }
            // A process with no GPU clients has used no GPU time, and one NetSampler didn't list moved no bytes.
            if let gpu { p.gpuNanos = gpu[k.pid] ?? 0 }
            if let net {
                p.netIn = net[k.pid]?.inPerSec ?? 0; p.netOut = net[k.pid]?.outPerSec ?? 0
                // A process the reader hasn't seen a socket of has moved nothing since it started reading.
                let native = NetSampler.shared.since != nil
                p.netInTotal = net[k.pid]?.inTotal ?? (native ? 0 : nil)
                p.netOutTotal = net[k.pid]?.outTotal ?? (native ? 0 : nil)
            }
            // A pid reused since the snapshot would get another process's ports.
            if let mach, p.start <= mach.at { p.machPorts = mach.counts[k.pid] }
            if let jetsam { p.jetsam = jetsam[k.pid] }
            if extras.contains(.idleExit) { p.idleExit = IdleExitState.read(k.pid) }
            built.append(p)
        }
        let priv = privSource()
        let wall = Date()
        // Into an array first: writing back into a dictionary being iterated copied all of it.
        for i in built.indices where !reused.contains(i) {
            var p = built[i]
            let pid = p.pid
            if let m = priv?[pid] {
                // Field by field: a value read locally stays, and the helper fills only what's missing.
                // (task info and rusage can fail independently, and the helper's own entry may be empty.)
                p.viaHelper = p.fill(from: m)
                if p.responsible == nil { p.responsible = m.responsible }
                if p.asid == nil { p.asid = m.asid }
            }
            let before = prev[p.key]
            // sandbox check is cheap but noisy for zombies. A process can enter a sandbox but never leave it, so
            // one seen sandboxed isn't asked again: confirming a "yes" costs a sysctl (Native.isSame).
            // One seen not sandboxed, or that couldn't be asked about, is asked again while it is young (a process
            // enters its sandbox as it starts up) and after that only now and then (`recheck`): the check is
            // ~7 µs a process.
            if before?.sandboxed == true { p.sandboxed = true }
            else if let before, !recheck, wall.timeIntervalSince(p.start) > Self.sandboxSettle {
                p.sandboxed = before.sandboxed
            }
            // The helper answers this once per process (HelperAsk), so its answer is kept from then on.
            else if !p.isZombie { p.sandboxed = Native.sandboxed(pid, start: p.start) ?? priv?[pid]?.sandboxed ?? before?.sandboxed }
            let sample = Sample(p, at: now)
            if let before, now > before.at {
                let r = Rates(from: before, to: sample)
                p.cpuPercent = r.cpuPercent
                p.rates = r
            }
            samples[p.key] = sample
            built[i] = p
        }
        let sessions = LoginSessions.describe(Set(built.lazy.compactMap(\.asid)))
        var out = [pid_t: ProcInfo](minimumCapacity: built.count)
        for var p in built {
            p.session = p.asid.flatMap { sessions[$0] }
            out[p.pid] = p
        }
        built = []
        if !domainHosts.isEmpty { applyDomainOwners(&out, domainHosts) }
        for pid in Responsiveness.unresponsive(out.values.lazy.filter { Responsiveness.isCandidate(lsType: $0.lsType) }.map(\.pid)) {
            out[pid]?.notResponding = true
        }
        return Snapshot(procs: out, ls: ls, jobs: jobs, otherJobs: otherJobs, samples: samples)
    }

    // MARK: Derived views

    /// Processes whose responsible process is gone — e.g. helpers an app left behind when it quit.
    var ghosts: [Ghost] { Self.ghosts(procs: procs, lsApps: lsApps) }

    /// Tags every survivor of a Left Behind group with its dead app, so the LEFT badge, the Responsible
    /// column and the Responsible tree agree with the Left Behind filter. On macOS 27 a leftover reports
    /// itself as its own responsible process, so "responsible pid is dead" alone no longer finds it.
    /// Returns how many Left Behind groups there are, for the sidebar's badge.
    @discardableResult
    nonisolated static func markLeftBehind(_ procs: inout [pid_t: ProcInfo], lsApps: [LSApp]) -> Int {
        let found = ghosts(procs: procs, lsApps: lsApps)
        for g in found {
            for s in g.survivors {
                procs[s.pid]?.leftBehindGroup = g.id
                procs[s.pid]?.leftBehindApp = g.name
                procs[s.pid]?.leftBehindPid = g.deadPid
                procs[s.pid]?.leftBehindTags = g.lsApp?.stateTags ?? []
            }
        }
        return found.count
    }

    /// For the sidebar badge: a stored value that is only written when it changes, so the sidebar
    /// doesn't re-render on every refresh.
    private(set) var ghostCount = 0


    /// Four signals: (1) responsible pid points at a dead process; (2) LaunchServices marks an app
    /// `exited-with-subordinates` — survivors share its coalition, or (2b) run a launchd job the app loaded
    /// itself (`loadedJobs`, e.g. Rex's server agent, bootstrapped from a plist in Application Support), unless
    /// a live app loaded the same job too (CoreSimulatorService and simdiskimaged); (3) a running app lists a *different*
    /// coalition under relatedCoalitionIDs — an earlier instance's, whose processes outlived it (LaunchServices
    /// drops the exited entry once the app is launched again). lsappinfo's `coalition:` is the *jetsam*
    /// coalition id, so match against both ids. On macOS 27 a leftover reports itself as its own
    /// responsible process, so (1) rarely fires; (2) and (3) do the work.
    nonisolated static func ghosts(procs: [pid_t: ProcInfo], lsApps: [LSApp]) -> [Ghost] {
        var survivors: [Int: [pid_t: ProcInfo]] = [:]   // group id -> survivors by pid
        var meta: [Int: (dead: pid_t?, name: String?, ls: LSApp?)] = [:]
        let lsByPid = Dictionary(lsApps.compactMap { a in a.pid.map { ($0, a) } }, uniquingKeysWith: { a, _ in a })
        func deadGroup(_ pid: pid_t) -> Int { -Int(pid) - 1 }

        for p in procs.values {
            if let r = p.responsible, r != p.pid, procs[r] == nil {
                survivors[deadGroup(r), default: [:]][p.pid] = p
                meta[deadGroup(r)] = (r, lsByPid[r]?.name, lsByPid[r])
            }
        }
        // Survivors found by coalition are merged with any found through the responsible pid for the same app.
        let liveJobs = Set(lsApps.lazy.filter { !$0.exited }.flatMap(\.loadedJobs))
        for a in lsApps where a.exited {
            guard let pid = a.pid else { continue }
            let listed = Set(a.coalitionPIDs + a.relatedCoalitionPIDs)
            let jobs = Set(a.loadedJobs).subtracting(liveJobs)
            for p in procs.values where listed.contains(p.pid)
                || (a.coalition != nil && (p.coalition == a.coalition || p.jetsamCoalition == a.coalition))
                || p.launchdLabel.map(jobs.contains) == true {
                survivors[deadGroup(pid), default: [:]][p.pid] = p
            }
            meta[deadGroup(pid)] = (pid, a.name, a)
        }
        for a in lsApps where !a.exited {
            guard let own = a.coalition else { continue }
            for prior in a.relatedCoalitionIDs where prior != own {
                let gid = -1_000_000 - Int(prior)
                for p in procs.values where p.jetsamCoalition == prior || p.coalition == prior {
                    survivors[gid, default: [:]][p.pid] = p
                }
                meta[gid] = (nil, a.name, nil)
            }
        }
        // An exited app with nothing left running isn't "left behind".
        return survivors.filter { !$0.value.isEmpty }.map { gid, ps in
            let m = meta[gid]
            return Ghost(id: gid, deadPid: m?.dead, name: m?.name ?? "unknown (pid \(m?.dead.map(String.init) ?? "?"))",
                         lsApp: m?.ls, survivors: ps.values.sorted { $0.pid < $1.pid })
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// `columns`: the shown columns, whose group-row values are worked out (the others cost nothing).
    /// `predicate`: a filter in the PredicateCompiler language; one that doesn't parse filters nothing.
    ///
    /// A timer refresh has already built this tree in the background (see refresh), so this returns it; the tree is
    /// built here, on the main thread, only when the view itself changed (sort, filter, columns, a pin) or a
    /// background read patched the data between refreshes.
    func nodes(grouping: Grouping, filter: String, predicate: String = "", sort: ColumnSort,
               columns: Set<String> = []) -> [ProcNode] {
        let spec = TreeSpec(grouping: grouping, filter: filter, predicate: predicate, sort: sort, columns: columns)
        let pins = Pins.shared.ranks
        if let c = nodesCache, c.gen == dataGen, c.pins == pins.version, c.spec == spec { return c.nodes }
        // Keeps predicateReads in step with the filter in force.
        _ = self.predicate(predicate)
        let ctx = context
        let out = PerfStages.measure(.treeBuild) { TreeBuilder.build(spec, ctx, pins: pins) }
        nodesCache = (dataGen, pins.version, spec, out)
        nodesVersion &+= 1
        treeSpec = spec
        return out
    }

    /// The data as the columns read it, made once per change of the data.
    var context: TableContext {
        if let c = contextCache, c.gen == dataGen { return c.ctx }
        let ctx = TableContext(procs: procs, lsApps: lsApps, btmOwners: btmOwners, signs: signCache)
        contextCache = (dataGen, ctx)
        compiledPredicates.removeAll()
        return ctx
    }
    // MARK: Actions

    /// Signals `p` only if its pid still belongs to the same process (same start time): the pid may have
    /// been reused since the row or dialog showed it. Refuses pid <= 0: kill(0, …) signals ProcXRay's own
    /// process group and kill(-n, …) a whole group, never the kernel_task row the user clicked.
    func send(_ s: ProcSignal, to p: ProcInfo) -> String? {
        guard p.pid > 0 else { return "pid \(p.pid) can't be signalled" }
        guard let live = Native.process(p.pid) else { return "process \(p.pid) has exited" }
        guard live.start == p.start else { return "pid \(p.pid) now belongs to a different process" }
        guard case .unix(let sig) = s else {
            // The quit Apple Event, as ⌘Q. `true` only means it was sent: the app may still ask to save or refuse.
            guard let app = NSRunningApplication(processIdentifier: p.pid) else { return "\(p.name) isn't an app that can be asked to quit." }
            return app.terminate() ? nil : "\(p.name) didn't accept the request to quit."
        }
        guard kill(p.pid, sig) != 0 else { return nil }
        let e = errno
        return e == EPERM ? "Operation not permitted: the process belongs to another user or is protected by macOS."
                          : String(cString: strerror(e))
    }
}

enum Fmt {
    static func bytes(_ v: UInt64?) -> String {
        guard let v else { return "—" }
        if v == 0 { return "0" }
        return plainBytes ? bytesText(v) : systemBytes(v)
    }

    /// ByteCountFormatter's text (memory style: "1,023 bytes", "12 KB", "5.1 MB", "10.05 GB").
    static func systemBytes(_ v: UInt64) -> String { byteFormatter.string(fromByteCount: Int64(clamping: v)) }
    nonisolated(unsafe) private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .memory; return f
    }()

    /// The same text worked out here. ByteCountFormatter looks its unit up in a bundle on every call, which made
    /// it a twelfth of a table rebuild (it formats every group row's sums); the tests hold this to its output.
    /// Only where numbers are written the English way: elsewhere the system's formatter decides.
    static func bytesText(_ v: UInt64) -> String {
        if v < 1024 { return v == 1 ? "1 byte" : grouped(v) + " bytes" }
        // Whole KB, one decimal of MB, two from GB up; a value that rounds to 1,024 moves to the next unit.
        var x = Double(v) / 1024
        var unit = 0
        while true {
            let scale: Double = unit == 0 ? 1 : unit == 1 ? 10 : 100
            let r = (x * scale).rounded()
            if r >= 1024 * scale, unit < byteUnits.count - 1 { x /= 1024; unit += 1; continue }
            let whole = UInt64(r / scale), frac = Int(r - Double(whole) * scale)
            var s = grouped(whole)
            if frac > 0 {
                // Trailing zeros dropped: 1.50 → 1.5.
                s += unit == 1 ? ".\(frac)" : frac % 10 == 0 ? ".\(frac / 10)" : frac < 10 ? ".0\(frac)" : ".\(frac)"
            }
            return s + byteUnits[unit]
        }
    }
    private static let byteUnits = [" KB", " MB", " GB", " TB", " PB", " EB"]
    private static let plainBytes: Bool = {
        let l = Locale.current
        return l.language.languageCode?.identifier == "en" && l.decimalSeparator == "." && l.groupingSeparator == ","
    }()
    /// 1234567 → "1,234,567".
    private static func grouped(_ v: UInt64) -> String {
        if v < 1000 { return String(v) }
        var digits = Array(String(v)), out: [Character] = []
        out.reserveCapacity(digits.count + digits.count / 3)
        let lead = digits.count % 3
        for (i, c) in digits.enumerated() {
            if i > 0, (i - lead) % 3 == 0 { out.append(",") }
            out.append(c)
        }
        digits.removeAll()
        return String(out)
    }
    /// A count with thousands separators, or "—".
    static func count<T: BinaryInteger>(_ v: T?) -> String {
        guard let v else { return "—" }
        return Int64(clamping: v).formatted()
    }

    /// CPU-style durations: "12.34 s" below a minute, then "m:ss", "h:mm:ss", "Nd h:mm:ss".
    static func secs(_ nanos: UInt64?) -> String {
        guard let nanos else { return "—" }
        let s = Double(nanos) / 1e9
        if s < 60 { return String(format: "%.2f s", s) }
        let t = Int(s)
        let (d, h, m, sec) = (t / 86400, t % 86400 / 3600, t % 3600 / 60, t % 60)
        if d > 0 { return String(format: "%dd %d:%02d:%02d", d, h, m, sec) }
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    static func pct(_ v: Double?) -> String {
        guard let v else { return "—" }
        // Keep "didn't run" (exactly 0) apart from "ran a little" (would round to 0.0).
        if v == 0 { return "0" }
        if v > 0 && v < 0.05 { return "<0.1" }
        return String(format: "%.1f", v)
    }
    static let date: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d HH:mm:ss"; return f
    }()
    /// Processes started before the clock was set at boot report 1970/1976 start times ("18487d" old).
    /// Nothing ran before boot, so for display such a start is the boot time. The raw value stays in
    /// ProcInfo.start: it is part of the process's identity and must not move when boot time does.
    static func shownStart(_ d: Date) -> Date {
        // Called for every process under every group row of a Started column: plain statics and the uptime clock,
        // not an optional tuple and Date() per call (4 % of a table rebuild).
        let now = DispatchTime.now().uptimeNanoseconds
        if bootReadAt == 0 || now &- bootReadAt > 5_000_000_000 { bootTime = Native.bootTime(); bootReadAt = now }
        guard let boot = bootTime, d < boot else { return d }
        return boot
    }
    nonisolated(unsafe) private static var bootTime: Date?
    nonisolated(unsafe) private static var bootReadAt: UInt64 = 0

    static func age(_ d: Date) -> String {
        // A start time after now (the clock was set back since) is shown as just started, not negative.
        let s = max(0, Int(Date().timeIntervalSince(shownStart(d))))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86400)d \(s % 86400 / 3600)h"
    }
}

/// The counters a rate is worked out from, for one process at one moment.
struct Sample: Sendable {
    var at: UInt64                    // uptime nanoseconds
    var cpu, waiting, diskRead, diskWrite, energy, wakeups: UInt64?
    var pCore, instructions, cycles, logicalWrites, gpu: UInt64?
    var qos: [UInt64]?
    var contextSwitches, faults, pageins, machMsgsSent, machMsgsReceived, unixSyscalls, machSyscalls: UInt32?
    /// Carried to the next refresh, which reuses it instead of reading it again (see Store.snapshot).
    var fixed: Fixed?
    var sandboxed: Bool?
    var pid: pid_t
    /// The app couldn't read this process itself: the next refresh asks the helper for it (HelperAsk).
    var needsHelper: Bool

    /// What doesn't change while a process runs the same code (`cdhash`).
    struct Fixed: Sendable {
        var cdhash: String?
        var comm: String
        var path: String?
        var extensionPoint: String?
        var responsible: pid_t?
        var coalition, jetsamCoalition: UInt64?
        /// Changes only through audit_session_join, which sshd and login call before they exec.
        var asid: Int32?
    }

    init(_ p: ProcInfo, at: UInt64) {
        self.at = at
        pid = p.pid
        needsHelper = p.viaHelper || !p.isInspectable
        fixed = Fixed(cdhash: p.cdhash, comm: p.comm, path: p.path, extensionPoint: p.extensionPoint, responsible: p.responsible,
                      coalition: p.coalition, jetsamCoalition: p.jetsamCoalition, asid: p.asid)
        sandboxed = p.sandboxed
        cpu = p.cpuNanos; waiting = p.counters?.waitingNanos
        diskRead = p.diskRead; diskWrite = p.diskWrite; energy = p.energyNJ; wakeups = p.wakeups
        let c = p.counters
        contextSwitches = c?.contextSwitches; faults = c?.faults; pageins = c?.pageins
        machMsgsSent = c?.machMsgsSent; machMsgsReceived = c?.machMsgsReceived
        unixSyscalls = c?.unixSyscalls; machSyscalls = c?.machSyscalls
        pCore = c?.pCoreNanos; instructions = c?.instructions; cycles = c?.cycles; logicalWrites = c?.logicalWrites
        gpu = p.gpuNanos
        qos = c?.qosNanos
    }
}

/// Change per second between two samples of one process. A rate is nil when either reading is missing.
struct Rates: Hashable, Sendable {
    var cpuPercent: Double?
    /// Time runnable but not running, as a percentage of one core (like CPU %, it can pass 100).
    var waitingPercent: Double?
    var contextSwitches, faults, pageins: Double?
    var diskRead, diskWrite: Double?          // bytes per second
    var watts: Double?
    var wakeups, syscalls, machMsgs: Double?
    var unixSyscalls, machSyscalls, machMsgsSent, machMsgsReceived: Double?
    var logicalWrites: Double?               // bytes per second
    /// Share of the interval's CPU time spent on performance cores, in percent (nil when it used none).
    var pCoreShare: Double?
    /// Instructions per cycle over the interval.
    var ipc: Double?
    /// CPU cycles per second.
    var cycles: Double?
    /// Instructions retired per second.
    var instructions: Double?
    /// GPU time over the interval, as a percentage of the interval.
    var gpuPercent: Double?
    /// CPU per QoS class over the interval, percent of one core, in `Counters.qosClasses` order.
    var qosPercent: [Double]?

    init(from a: Sample, to b: Sample) {
        let secs = Double(b.at - a.at) / 1e9
        // 64-bit lifetime totals only grow; a drop means the reading is off, so no rate.
        func d64(_ x: UInt64?, _ y: UInt64?) -> Double? {
            guard let x, let y, y >= x else { return nil }
            return Double(y - x)
        }
        // proc_taskinfo keeps these as 32-bit ints that wrap. Subtracting modulo 2^32 gives the true change
        // as long as fewer than 2^32 events happen between two refreshes (seconds apart), so a wrap still
        // gives the right rate.
        func d32(_ x: UInt32?, _ y: UInt32?) -> Double? {
            guard let x, let y else { return nil }
            return Double(y &- x)
        }
        func sum(_ x: Double?, _ y: Double?) -> Double? { x.flatMap { a in y.map { a + $0 } } }
        cpuPercent = d64(a.cpu, b.cpu).map { $0 / 1e9 / secs * 100 }
        waitingPercent = d64(a.waiting, b.waiting).map { $0 / 1e9 / secs * 100 }
        contextSwitches = d32(a.contextSwitches, b.contextSwitches).map { $0 / secs }
        faults = d32(a.faults, b.faults).map { $0 / secs }
        pageins = d32(a.pageins, b.pageins).map { $0 / secs }
        diskRead = d64(a.diskRead, b.diskRead).map { $0 / secs }
        diskWrite = d64(a.diskWrite, b.diskWrite).map { $0 / secs }
        watts = d64(a.energy, b.energy).map { $0 / 1e9 / secs }   // nanojoules → joules per second
        wakeups = d64(a.wakeups, b.wakeups).map { $0 / secs }
        syscalls = sum(d32(a.unixSyscalls, b.unixSyscalls), d32(a.machSyscalls, b.machSyscalls)).map { $0 / secs }
        machMsgs = sum(d32(a.machMsgsSent, b.machMsgsSent), d32(a.machMsgsReceived, b.machMsgsReceived)).map { $0 / secs }
        unixSyscalls = d32(a.unixSyscalls, b.unixSyscalls).map { $0 / secs }
        machSyscalls = d32(a.machSyscalls, b.machSyscalls).map { $0 / secs }
        machMsgsSent = d32(a.machMsgsSent, b.machMsgsSent).map { $0 / secs }
        machMsgsReceived = d32(a.machMsgsReceived, b.machMsgsReceived).map { $0 / secs }
        logicalWrites = d64(a.logicalWrites, b.logicalWrites).map { $0 / secs }
        if let pc = d64(a.pCore, b.pCore), let c = d64(a.cpu, b.cpu), c > 0 { pCoreShare = min(100, pc / c * 100) }
        if let i = d64(a.instructions, b.instructions), let c = d64(a.cycles, b.cycles), c > 0 { ipc = i / c }
        cycles = d64(a.cycles, b.cycles).map { $0 / secs }
        // A process that starts using the GPU has no earlier reading: count it from zero.
        if b.gpu != nil { gpuPercent = d64(a.gpu ?? 0, b.gpu).map { $0 / 1e9 / secs * 100 } }
        if let qa = a.qos, let qb = b.qos, qa.count == qb.count {
            qosPercent = zip(qa, qb).map { (d64($0, $1) ?? 0) / 1e9 / secs * 100 }
        }
        instructions = d64(a.instructions, b.instructions).map { $0 / secs }
    }
}

/// The last few minutes of one process, for the graphs: one entry per refresh, oldest first. How many are kept
/// is a setting (Tuning.historyLength).
struct History: Sendable {
    private var ring: SeriesRing

    init(capacity: Int) { ring = SeriesRing(lanes: 5, capacity: capacity) }

    var cpu: [Double?] { ring.values(0) }       // percent of one core
    var memory: [Double?] { ring.values(1) }    // footprint, bytes
    var disk: [Double?] { ring.values(2) }      // read + written, bytes per second
    var power: [Double?] { ring.values(3) }     // watts
    var network: [Double?] { ring.values(4) }   // received + sent, bytes per second; nil while not read

    mutating func append(_ p: ProcInfo, capacity: Int) {
        if ring.capacity != capacity { ring.resize(capacity) }
        let r = p.rates
        ring.push { lane in
            switch lane {
            case 0: r?.cpuPercent
            case 1: p.footprint.map { Double($0) }
            case 2: r.flatMap { r in r.diskRead.flatMap { a in r.diskWrite.map { a + $0 } } }
            case 3: r?.watts
            default: p.netIn.flatMap { i in p.netOut.map { i + $0 } }
            }
        }
    }
}
