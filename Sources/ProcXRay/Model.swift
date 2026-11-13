import AppKit
import Darwin
import Foundation
import Observation
import SwiftUI

struct ProcInfo: Identifiable, Hashable, Sendable {
    var id: pid_t { pid }
    var pid: pid_t
    var ppid: pid_t
    var pgid: pid_t
    var uid: uid_t
    var user: String
    var comm: String
    var path: String?
    var start: Date
    var stat: Int8
    var pflags: Int32

    var responsible: pid_t?
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
    /// Power assertion types held (IOPMCopyAssertionsByProcess); empty when it holds none.
    var assertions: [String]?
    /// GPU time since the process started, nanoseconds; nil when it has never used the GPU.
    var gpuNanos: UInt64?
    /// Network bytes per second from nettop's latest pair of samples (NetSampler).
    var netIn: Double?
    var netOut: Double?
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
    /// Set when this process outlived the app that launched it (see Store.ghosts): the Left Behind
    /// group's id, and the app's name and pid where known.
    var leftBehindGroup: Int?
    var leftBehindApp: String?
    var leftBehindPid: pid_t?
    var leftBehindText: String? {
        guard leftBehindGroup != nil else { return nil }
        return "\(leftBehindApp ?? "exited app") (\(leftBehindPid.map { "pid \($0)" } ?? "previous instance"))"
    }

    var key: String { "\(pid):\(start.timeIntervalSince1970)" }
    /// CDHash of the running code (see Native.cdhash); changes when the process execs something else.
    var cdhash: String?
    /// Key for signing details: pid and start time survive exec, so the running code is part of it.
    /// Without it a process could show an Apple signature while running unsigned code it exec'd.
    var codeKey: String { "\(key):\(cdhash ?? path ?? comm)" }
    var name: String {
        if let p = path { return (p as NSString).lastPathComponent }
        return comm
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
        fill(\.compressed, m.compressed)
        return took
    }

    /// Bundle (.app) that owns the executable, if any.
    var bundlePath: String? {
        guard let p = path, let r = p.range(of: ".app/", options: .backwards) else { return nil }
        return String(p[..<r.lowerBound]) + ".app"
    }

    /// For an app extension inside an app: that app's name.
    var containingAppName: String? {
        guard path?.contains(".appex/") == true, let b = bundlePath else { return nil }
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
enum Grouping: String, CaseIterable, Identifiable {
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
    var id: String { rawValue }
    var label: String { self == .responsible ? "Responsible / parent tree" : rawValue }
    static let trees: [Grouping] = [.smart, .responsible, .flat]
    static let pivots: [Grouping] = [.bySigner, .byUser, .byDomain, .bySandbox, .byArch]
    /// The pivot's field name, for the submenu ("Signer").
    var pivotTitle: String {
        switch self {
        case .bySigner: "Signer"
        case .byUser: "User"
        case .byDomain: "launchd domain"
        case .bySandbox: "Sandbox"
        case .byArch: "Architecture"
        default: label
        }
    }
}

/// A row in the process table: a real process, or a synthetic group (dead responsible app / coalition).
struct ProcNode: Identifiable, Sendable {
    enum Kind: UInt8, Sendable {
        case process
        case group      // coalition, sub-group of a Smart category
        case ghost      // Left Behind group
        case category   // Smart tree top level
        case unit       // Smart tree: an app or job with its helpers; stands for `rootPid`
    }

    var id: Int
    var proc: ProcInfo?
    var title: String
    var subtitle: String = ""
    var isGhost = false
    var children: [ProcNode]?
    var kind: Kind = .process
    var category: ProcCategory?
    /// The process a unit row stands for (selecting the row selects it).
    var rootPid: pid_t?
    /// Rows with a fixed order sort before their siblings, in this order, whatever the sort column.
    var fixedOrder: Int?
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
    var btm: [BTMItem] = [] { didSet { btmOwners = BTM.ownerIndex(btm); dataGen &+= 1 } }
    /// BTM.ownerIndex of btm, for the Smart tree.
    @ObservationIgnored private(set) var btmOwners: [String: [String]] = [:]
    var btmLoading = false
    /// Set once a load finished and produced a record list (possibly empty), so "nothing loaded yet",
    /// "loaded, no records" and "failed" (btmError) look different.
    var btmLoaded = false
    var btmError: String?
    var paused = false
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
    /// The Kind column's labels, rebuilt when the data changes (see `kind(of:)`).
    @ObservationIgnored var kindCache: (gen: Int, map: [pid_t: String], roots: [pid_t: pid_t])?
    /// Bumps each time nodes() actually rebuilds, so views can skip work when it returned the cached tree.
    @ObservationIgnored private(set) var nodesVersion = 0
    @ObservationIgnored private var nodesCache: (gen: Int, grouping: Grouping, filter: String, chips: Set<FilterChip>,
                                                 sort: ColumnSort, columns: Set<String>, nodes: [ProcNode])?

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
    /// The extra reads the shown columns need (see Column.reads); set by the process table.
    @ObservationIgnored var extraReads: ExtraReads = []
    /// Each process's counters at the last refresh, by key: CPU % and the rate columns divide the change
    /// by the time between the two readings.
    @ObservationIgnored private var prevSamples: [String: Sample] = [:]
    /// Recent values per process key, for sparklines (see History).
    @ObservationIgnored private(set) var history: [String: History] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var signing = false
    var helperState: HelperClient.State = .notInstalled
    var helperError: String?
    @ObservationIgnored private var probeTimer: Timer?

    init() {
        // A dropped helper connection (helper died, disabled, replaced): re-probe right away rather than
        // keep showing it as running until the next probe.
        HelperClient.shared.onConnectionLost = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.probeHelper() } }
        }
        probeHelper()
        refresh()
        schedule()
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSApplication.didHideNotification, NSApplication.didUnhideNotification,
            NSApplication.didChangeOcclusionStateNotification,
        ]
        visibilityObservers = names.map { name in
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
    @ObservationIgnored private var visibilityObservers: [NSObjectProtocol] = []

    private func visibilityChanged() {
        let visible = !NSApp.isHidden && NSApp.windows.contains {
            $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
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

    func probeHelper() {
        probeGen &+= 1
        let gen = probeGen
        Task.detached {
            let s = HelperClient.shared.probe()
            await MainActor.run {
                guard gen == self.probeGen else { return }
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
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.paused else { return }
                self.refresh(full: false)
            }
        }
        t.tolerance = interval * 0.2   // lets the system coalesce our wakeups with others
        RunLoop.main.add(t, forMode: .default)   // as before: no refreshes mid-scroll or while a menu is open
        timer = t
    }

    /// LaunchServices and launchd state changes rarely and costs two subprocess spawns to read
    /// (`lsappinfo` alone is ~25 ms of CPU plus work in launchservicesd), so timer ticks re-read it only
    /// every `slowEvery` ticks. Manual refreshes and coming back on screen always read everything.
    private static let slowEvery = 5
    @ObservationIgnored private var ticksSinceSlow = 0

    func refresh(full: Bool = true) {
        guard !refreshing else { return }
        refreshing = true
        let prev = prevSamples
        let cache = signCache
        let argv = argvCache
        let jobParents = jobParentCache
        let hosts = domainHostOf
        let extras = extraReads
        let useHelper = helperState.isRunning
        let readSlow = full || ticksSinceSlow + 1 >= Self.slowEvery || lsApps.isEmpty
        ticksSinceSlow = readSlow ? 0 : ticksSinceSlow + 1
        let ls = readSlow ? nil : lsApps
        let jobs = readSlow ? nil : self.jobs
        let otherJobs = readSlow ? nil : self.otherJobs
        Task.detached(priority: .userInitiated) {
            let t0 = DispatchTime.now().uptimeNanoseconds
            // Ask the helper first, but collect local data while it answers; the snapshot waits for the
            // helper only after that, and never longer than helperBudget (it normally takes ~10 ms).
            let priv = useHelper ? Pending { HelperClient.shared.allMetrics(extras: extras, timeout: Self.helperBudget) } : nil
            var marked = Self.snapshot(prev: prev, signCache: cache, argvCache: argv, jobParents: jobParents, domainHosts: hosts, extras: extras, priv: { priv?.wait() },
                                       ls: ls, jobs: jobs, otherJobs: otherJobs)
            Self.markLeftBehind(&marked.procs, lsApps: marked.ls)
            let snap = marked
            let ms = Int((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
            await MainActor.run {
                self.refreshError = snap.error
                guard snap.error == nil else {
                    // Keep showing the last good snapshot rather than an empty table.
                    self.refreshing = false
                    return
                }
                self.procs = snap.procs
                if readSlow {
                    self.lsApps = snap.ls
                    self.jobs = snap.jobs
                    self.otherJobs = snap.otherJobs
                }
                self.prevSamples = snap.samples
                self.recordHistory(snap.procs)
                if full { self.fullRefreshGen &+= 1 }
                self.updateGhostCount()
                self.lastRefresh = Date()
                self.refreshMillis = ms
                self.refreshing = false
                self.fillSignatures()
                self.fillCommandLines()
                self.fillPidDomains()
                self.fillJobParents()
            }
        }
    }

    /// Appends this refresh to each process's history and forgets processes that are gone.
    private func recordHistory(_ procs: [pid_t: ProcInfo]) {
        var next: [String: History] = [:]
        next.reserveCapacity(procs.count)
        for p in procs.values {
            var h = history[p.key] ?? History()
            h.append(p)
            next[p.key] = h
        }
        history = next
    }

    /// Code-signing lookups are the slow part; do the missing ones in the background and merge.
    private func fillSignatures() {
        guard !signing else { return }
        let missing = procs.values.filter { signCache[$0.codeKey] == nil }.map { ($0.codeKey, $0.pid, $0.path, $0.cdhash) }
        guard !missing.isEmpty else { return }
        signing = true
        Task.detached(priority: .utility) {
            var acc: [String: SignInfo] = [:]
            for (k, pid, path, expected) in missing {
                let info = CodeSign.inspect(pid: pid, path: path)
                // An exec between the snapshot and this lookup: the details belong to other code. Skip;
                // the next snapshot carries the new cdhash and asks again.
                if let e = expected, let got = info.cdHash, e != got { continue }
                acc[k] = info
            }
            let found = acc
            await MainActor.run {
                self.signCache.merge(found) { a, _ in a }
                let live = Set(self.procs.values.map(\.codeKey))
                self.signCache = self.signCache.filter { live.contains($0.key) }
                // snapshot() already applied every older cache entry; patch only the processes that were
                // just inspected, on a local copy, and publish once. Writing self.procs[pid] in a loop
                // copied the whole dictionary per write and invalidated the table ~700 times.
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

    /// Reads argv for processes not in argvCache yet, in the background, and merges it like signatures.
    private func fillCommandLines() {
        guard !readingArgv else { return }
        let missing = procs.values.filter { argvCache[$0.codeKey] == nil }.map { ($0.codeKey, $0.pid, $0.start, $0.cdhash) }
        guard !missing.isEmpty else { return }
        readingArgv = true
        let helper = helperState.isRunning
        Task.detached(priority: .utility) {
            var acc: [String: String?] = [:]
            var buf: [UInt8] = []
            for (k, pid, start, expected) in missing {
                let args = Native.argsEnv(pid, buffer: &buf)?.args
                    ?? (helper ? HelperClient.shared.argsEnv(pid)?.args : nil)
                // Read from another process (the pid was reused) or other code (it exec'd since the
                // snapshot): leave it for the next refresh, whose key matches what's running.
                guard Native.isSame(pid, start: start), Native.cdhash(pid) == expected else { continue }
                acc[k] = args.map(Self.joinArgs)
            }
            let found = acc
            await MainActor.run {
                self.argvCache.merge(found) { a, _ in a }
                let live = Set(self.procs.values.map(\.codeKey))
                self.argvCache = self.argvCache.filter { live.contains($0.key) }
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

    /// Reads the launchd pid domain of every process not read yet, in the background. A process that appears
    /// may have been launched into a domain read earlier, so every domain that listed services is read again
    /// when a new process is a child of launchd; most domains are empty (54 hosts among ~480 processes measured).
    private func fillPidDomains() {
        guard !readingDomains else { return }
        let missing = procs.values.filter { $0.pid > 0 && !$0.isZombie && domainReads[$0.key] == nil }
        guard !missing.isEmpty else { return }
        // launchd starts what runs in a pid domain, so only a new child of launchd can be in one read before.
        let hostKeys = missing.contains { $0.ppid == 1 }
            ? Set(domainReads.compactMap { k, v in (v?.isEmpty == false) ? k : nil }) : []
        let targets = missing + procs.values.filter { hostKeys.contains($0.key) }
        let jobs = targets.map { ($0.pid, $0.start, $0.key, $0.uid == getuid()) }
        let keyOf = procs.mapValues(\.key)
        readingDomains = true
        let helper = helperState.isRunning
        Task.detached(priority: .utility) {
            var acc: [String: [String]?] = [:]
            for (pid, start, key, own) in jobs {
                let kids = PidDomain.read(pid, ownedByUser: own, viaHelper: helper)
                // The pid was reused while reading: the domain belongs to someone else; the next pass asks again.
                guard Native.isSame(pid, start: start) else { continue }
                acc[key] = kids.map { $0.compactMap { keyOf[$0] }.filter { $0 != key } }
            }
            let found = acc
            await MainActor.run {
                self.domainReads.merge(found) { _, b in b }
                let live = Set(self.procs.values.map(\.key))
                self.domainReads = self.domainReads.filter { live.contains($0.key) }
                var hostOf: [String: String] = [:]
                for (host, kids) in self.domainReads { for k in kids ?? [] { hostOf[k] = host } }
                let changed = hostOf != self.domainHostOf
                self.domainHostOf = hostOf
                if changed {
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
            var found: [String: String?] = [:]
            for (_, key, label, domain) in todo {
                found[key] = Launchd.parentBundle(label, domain: domain)
            }
            let result = found
            await MainActor.run {
                self.jobParentCache.merge(result) { _, b in b }
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

    /// `priv`: helper metrics, asked for only after the local pass so a slow helper delays just the merge.
    nonisolated static func snapshot(prev: [String: Sample], signCache: [String: SignInfo],
                                     argvCache: [String: String?] = [:],
                                     jobParents: [String: String?] = [:],
                                     domainHosts: [String: String] = [:],
                                     extras: ExtraReads = [],
                                     priv privSource: () -> [Int32: PrivMetrics]? = { nil },
                                     ls: [LSApp]? = nil, jobs: [LaunchdJob]? = nil,
                                     otherJobs: [LaunchdJob]? = nil) -> Snapshot {
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
        NetSampler.shared.want(extras.contains(.network))
        let net = extras.contains(.network) ? NetSampler.shared.current() : nil

        let now = DispatchTime.now().uptimeNanoseconds
        var users: [uid_t: String] = [:]
        var out: [pid_t: ProcInfo] = [:]
        var samples: [String: Sample] = [:]

        let list: [Native.KProc]
        switch Native.listProcesses() {
        case .success(let l): list = l
        case .failure(let e): return Snapshot(procs: [:], ls: ls, jobs: jobs, otherJobs: otherJobs, samples: prev, error: e.message)
        }
        for k in list where k.pid >= 0 {
            let user = users[k.uid] ?? { let u = Native.userName(k.uid); users[k.uid] = u; return u }()
            var p = ProcInfo(pid: k.pid, ppid: k.ppid, pgid: k.pgid, uid: k.uid, user: user, comm: k.comm,
                             path: Native.path(k.pid), start: k.start, stat: k.stat, pflags: k.flags)
            p.cdhash = Native.cdhash(k.pid)
            p.responsible = Native.responsible(k.pid)
            if let c = Native.coalition(k.pid) { p.coalition = c.0; p.jetsamCoalition = c.1 }
            _ = p.fill(from: .read(k.pid))
            if let j = labelByPid[k.pid] { p.launchdLabel = j.label; p.launchdDomain = j.domain }
            if let b = jobParents[p.key] { p.launchdParentBundle = b }
            if let a = lsByPid[k.pid] { p.lsAppName = a.name; p.lsTags = a.stateTags; p.lsType = a.type }
            if k.tty != -1 { p.tty = k.tty }   // NODEV: no controlling terminal
            if let path = p.path { p.extensionPoint = ExtensionInfo.point(forExecutable: path) }
            if let s = signCache[p.codeKey] { p.signer = s.shortSigner; p.signID = s.identifier }
            if let c = argvCache[p.codeKey] { p.commandLine = c; p.commandLineRead = true }
            if extras.contains(.openFiles) { p.openFiles = ExtraRead.openFiles(k.pid) }
            if extras.contains(.nice) { p.nice = ExtraRead.nice(k.pid) }
            if extras.contains(.compressed) { p.compressed = ExtraRead.compressed(k.pid) }
            if let assertions { p.assertions = assertions[k.pid] ?? [] }
            // A process with no GPU clients has used no GPU time, and one nettop didn't list had no sockets.
            if let gpu { p.gpuNanos = gpu[k.pid] ?? 0 }
            if let net { p.netIn = net[k.pid]?.inPerSec ?? 0; p.netOut = net[k.pid]?.outPerSec ?? 0 }
            out[k.pid] = p
        }
        let priv = privSource()
        for (pid, var p) in out {
            if let m = priv?[pid] {
                // Field by field: a value read locally stays, and the helper fills only what's missing.
                // (task info and rusage can fail independently, and the helper's own entry may be empty.)
                p.viaHelper = p.fill(from: m)
                if p.responsible == nil { p.responsible = m.responsible }
            }
            let sample = Sample(p, at: now)
            if let before = prev[p.key], now > before.at {
                let r = Rates(from: before, to: sample)
                p.cpuPercent = r.cpuPercent
                p.rates = r
            }
            samples[p.key] = sample
            // sandbox check is cheap but noisy for zombies
            if !p.isZombie { p.sandboxed = Native.sandboxed(pid, start: p.start) ?? priv?[pid]?.sandboxed }
            out[pid] = p
        }
        if !domainHosts.isEmpty { applyDomainOwners(&out, domainHosts) }
        return Snapshot(procs: out, ls: ls, jobs: jobs, otherJobs: otherJobs, samples: samples)
    }

    // MARK: Derived views

    /// Processes whose responsible process is gone — e.g. helpers an app left behind when it quit.
    var ghosts: [Ghost] { Self.ghosts(procs: procs, lsApps: lsApps) }

    /// Tags every survivor of a Left Behind group with its dead app, so the LEFT badge, the Responsible
    /// column and the Responsible tree agree with the Left Behind section. On macOS 27 a leftover reports
    /// itself as its own responsible process, so "responsible pid is dead" alone no longer finds it.
    nonisolated static func markLeftBehind(_ procs: inout [pid_t: ProcInfo], lsApps: [LSApp]) {
        for g in ghosts(procs: procs, lsApps: lsApps) {
            for s in g.survivors {
                procs[s.pid]?.leftBehindGroup = g.id
                procs[s.pid]?.leftBehindApp = g.name
                procs[s.pid]?.leftBehindPid = g.deadPid
            }
        }
    }

    /// For the sidebar badge: a stored value that is only written when it changes, so the sidebar
    /// doesn't re-render on every refresh.
    private(set) var ghostCount = 0
    private func updateGhostCount() {
        let n = ghosts.count
        if n != ghostCount { ghostCount = n }
    }

    /// Three signals: (1) responsible pid points at a dead process; (2) LaunchServices marks an app
    /// `exited-with-subordinates` — survivors share its coalition; (3) a running app lists a *different*
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
        for a in lsApps where a.exited {
            guard let pid = a.pid else { continue }
            let listed = Set(a.coalitionPIDs + a.relatedCoalitionPIDs)
            for p in procs.values where listed.contains(p.pid)
                || (a.coalition != nil && (p.coalition == a.coalition || p.jetsamCoalition == a.coalition)) {
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
    func nodes(grouping: Grouping, filter: String, chips: Set<FilterChip> = [], sort: ColumnSort,
               columns: Set<String> = []) -> [ProcNode] {
        if let c = nodesCache, c.gen == dataGen, c.grouping == grouping, c.filter == filter, c.chips == chips,
           c.sort == sort, c.columns == columns { return c.nodes }
        let out = buildNodes(grouping: grouping, filter: filter, chips: chips, sort: sort, columns: columns)
        nodesCache = (dataGen, grouping, filter, chips, sort, columns, out)
        nodesVersion &+= 1
        return out
    }

    private func buildNodes(grouping: Grouping, filter: String, chips: Set<FilterChip>, sort: ColumnSort,
                            columns: Set<String>) -> [ProcNode] {
        let all = Array(procs.values)
        var roots: [ProcNode]
        switch grouping {
        case .smart:
            roots = SmartTree.build(.init(procs: procs, lsApps: lsApps, btmOwners: btmOwners))
        case .flat:
            roots = all.map { ProcNode(id: Int($0.pid), proc: $0, title: $0.name) }
        case .responsible:
            let lsByPid = Dictionary(lsApps.compactMap { a in a.pid.map { ($0, a) } }, uniquingKeysWith: { a, _ in a })
            var ghostIDs: [pid_t: Int] = [:]
            var leftGroups: [Int: String] = [:]   // Left Behind group id -> title
            var up: [pid_t: Int] = [:]
            for p in all {
                if let g = p.leftBehindGroup, let t = p.leftBehindText {
                    leftGroups[g] = t
                    up[p.pid] = g
                } else if let r = p.responsible, r != p.pid {
                    if self.procs[r] != nil { up[p.pid] = Int(r) } else {
                        ghostIDs[r] = -Int(r) - 1
                        up[p.pid] = -Int(r) - 1
                    }
                } else if p.ppid > 1, p.ppid != p.pid, self.procs[p.ppid] != nil {
                    // No responsible process of its own (or it's its own): its parent, as the Parent tree had
                    // it. launchd (1) and kernel_task (0) parent nearly everything, so their children stay roots.
                    up[p.pid] = Int(p.ppid)
                }
            }
            // Mixing the two links can close a loop (A responsible for B, B the parent of A), and a process
            // on a loop would never be reached from a root. Cut each loop at the process where it's found.
            for p in all {
                var seen: Set<pid_t> = [p.pid]
                var cur = p.pid
                while let u = up[cur], u > 0 {
                    let next = pid_t(u)
                    if !seen.insert(next).inserted { up[cur] = nil; break }
                    cur = next
                }
            }
            roots = tree(all) { up[$0.pid] }
            // tree() put orphans-of-ghosts under synthetic ids; materialize those groups.
            var extra: [ProcNode] = []
            let byParent = Dictionary(grouping: roots.filter { $0.id < 0 }, by: \.id)
            roots.removeAll { $0.id < 0 }
            for (dead, gid) in ghostIDs where leftGroups[gid] == nil {
                let kids = byParent[gid]?.flatMap { $0.children ?? [] } ?? []
                let name = lsByPid[dead]?.name ?? "?"
                extra.append(ProcNode(id: gid, proc: nil, title: "† \(name) — exited pid \(dead)",
                                      subtitle: "responsible process is gone", isGhost: true, children: kids))
            }
            for (gid, text) in leftGroups {
                let kids = byParent[gid]?.flatMap { $0.children ?? [] } ?? []
                extra.append(ProcNode(id: gid, proc: nil, title: "† \(text) — exited",
                                      subtitle: "app is gone; these outlived it", isGhost: true, children: kids))
            }
            roots += extra
        case .bySigner, .byUser, .byDomain, .bySandbox, .byArch:
            roots = TreeExtras.pivot(grouping, all)
        }
        if grouping != .flat { roots = TreeExtras.collapseIdentical(roots) }
        roots = roots.map(Self.counted)
        if !filter.isEmpty || !chips.isEmpty { roots = TreeExtras.prune(roots, text: filter, chips: chips, now: Date()) }
        let shown = Column.all.filter { columns.contains($0.id) && $0.id != "name" && $0.id != "context" }
        return sorted(roots, sort, shown: shown, sortColumn: Column.byID[sort.id], memo: ColumnMemo()).nodes
    }

    /// Sets totalCount (processes in the subtree) before the search filter prunes anything.
    private static func counted(_ n: ProcNode) -> ProcNode {
        var m = n
        m.children = n.children?.map(counted)
        m.totalCount = (n.proc == nil ? 0 : 1) + (m.children?.reduce(0) { $0 + $1.totalCount } ?? 0)
        return m
    }

    /// Build a forest using `parentOf`; unknown parents (negative ids) become temporary placeholder roots.
    private func tree(_ all: [ProcInfo], parentOf: (ProcInfo) -> Int?) -> [ProcNode] {
        var kids: [Int: [ProcInfo]] = [:]
        var roots: [ProcInfo] = []
        var placeholders: [Int: [ProcInfo]] = [:]
        for p in all {
            if let par = parentOf(p) {
                if par < 0 { placeholders[par, default: []].append(p) } else { kids[par, default: []].append(p) }
            } else { roots.append(p) }
        }
        func build(_ p: ProcInfo, depth: Int) -> ProcNode {
            let c = depth < 64 ? (kids[Int(p.pid)] ?? []).map { build($0, depth: depth + 1) } : []
            return ProcNode(id: Int(p.pid), proc: p, title: p.name, children: c.isEmpty ? nil : c)
        }
        var out = roots.map { build($0, depth: 0) }
        for (gid, ps) in placeholders {
            out.append(ProcNode(id: gid, proc: nil, title: "", children: ps.map { build($0, depth: 1) }))
        }
        return out
    }

    /// Ties are broken by row id. Without that, rows that tie (every group row has the same pidKey)
    /// kept Dictionary iteration order, which reshuffles whenever a process comes or goes; the table then
    /// saw hundreds of moved rows per refresh and spent seconds rebuilding and re-measuring row views.
    /// Children are sorted first so each node's cpuKey/memKey (subtree totals) is set before it is compared.
    /// Also fills each group row's value for every shown column (by the column's group rule) and each
    /// row's value in the sort column. Returns the processes under `nodes`, for the parent's group values.
    private func sorted(_ nodes: [ProcNode], _ sort: ColumnSort, shown: [Column], sortColumn: Column?,
                        memo: ColumnMemo) -> (nodes: [ProcNode], members: [ProcInfo]) {
        var allMembers: [ProcInfo] = []
        let out = nodes.map { n in
            var m = n
            var members: [ProcInfo] = []
            if let c = n.children {
                let r = sorted(c, sort, shown: shown, sortColumn: sortColumn, memo: memo)
                m.children = r.nodes
                members = r.members
            }
            if let p = n.proc { members.append(p) }
            allMembers += members
            if n.proc == nil {
                for (i, col) in shown.enumerated() {
                    m.groupValues[col.id] = col.groupValue(m, members: members, store: self) { memo.value(i, col, $0, self) }
                }
            }
            if sort.id == "name" {
                m.sortValue = .text(n.title)
            } else if let col = sortColumn {
                m.sortValue = n.proc.map { col.sortValue($0, self) } ?? m.groupValues[col.id]
                    ?? col.groupValue(m, members: members, store: self) { col.value($0, self) }
            }
            let kids = m.children ?? []
            if let p = n.proc {
                m.cpuKey = p.cpuPercent ?? 0
                m.memKey = p.footprint ?? 0
                m.diskKey = ProcNode.disk(p)
            } else {
                m.cpuKey = kids.reduce(0) { $0 + $1.cpuKey }
                m.memKey = kids.reduce(0) { $0 + $1.memKey }
                let known = kids.map(\.diskKey).filter { $0 >= 0 }
                m.diskKey = known.isEmpty ? -1 : known.reduce(0, &+)
            }
            m.shownCount = (n.proc == nil ? 0 : 1) + kids.reduce(0) { $0 + $1.shownCount }
            m.unitCount = kids.reduce(0) { $0 + ($1.kind == .group ? $1.unitCount : 1) }
            return m
        }.sorted { a, b in
            if a.fixedOrder != nil || b.fixedOrder != nil, a.fixedOrder != b.fixedOrder {
                return (a.fixedOrder ?? .max) < (b.fixedOrder ?? .max)
            }
            // Rows without a value go last, whichever way the column is sorted.
            let av = a.sortValue.hasValue, bv = b.sortValue.hasValue
            if av != bv { return av }
            if av {
                switch CellValue.compare(a.sortValue, b.sortValue) {
                case .orderedAscending: return sort.ascending
                case .orderedDescending: return !sort.ascending
                case .orderedSame: break
                }
            }
            return a.id < b.id
        }
        return (out, allMembers)
    }

    // MARK: Actions

    /// Signals `p` only if its pid still belongs to the same process (same start time): the pid may have
    /// been reused since the row or dialog showed it. Refuses pid <= 0: kill(0, …) signals ProcXRay's own
    /// process group and kill(-n, …) a whole group, never the kernel_task row the user clicked.
    func send(_ sig: Int32, to p: ProcInfo) -> String? {
        guard p.pid > 0 else { return "pid \(p.pid) can't be signalled" }
        guard let live = Native.process(p.pid) else { return "process \(p.pid) has exited" }
        guard live.start == p.start else { return "pid \(p.pid) now belongs to a different process" }
        guard kill(p.pid, sig) != 0 else { return nil }
        let e = errno
        return e == EPERM ? "Operation not permitted: the process belongs to another user or is protected by macOS."
                          : String(cString: strerror(e))
    }
}

enum Fmt {
    static func bytes(_ v: UInt64?) -> String {
        guard let v else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: v), countStyle: .memory)
    }
    /// A count with thousands separators, or "—".
    static func count<T: BinaryInteger>(_ v: T?) -> String {
        guard let v else { return "—" }
        return Int64(clamping: v).formatted()
    }

    static func secs(_ nanos: UInt64?) -> String {
        nanos.map { String(format: "%.2f s", Double($0) / 1e9) } ?? "—"
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
        if bootCache == nil || Date().timeIntervalSince(bootCache!.at) > 5 { bootCache = (Date(), Native.bootTime()) }
        guard let boot = bootCache?.boot, d < boot else { return d }
        return boot
    }
    nonisolated(unsafe) private static var bootCache: (at: Date, boot: Date?)?

    static func age(_ d: Date) -> String {
        // A start time after now (the clock was set back since) is shown as just started, not negative.
        let s = max(0, Int(Date().timeIntervalSince(shownStart(d))))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86400)d \(s % 86400 / 3600)h"
    }
}

/// Each process's value per shown column, worked out once per tree build: a process is a member of
/// every group row above it.
@MainActor
final class ColumnMemo {
    private var values: [[pid_t: CellValue]] = []
    func value(_ i: Int, _ col: Column, _ p: ProcInfo, _ store: Store) -> CellValue {
        while values.count <= i { values.append([:]) }
        if let v = values[i][p.pid] { return v }
        let v = col.value(p, store)
        values[i][p.pid] = v
        return v
    }
}

/// The counters a rate is worked out from, for one process at one moment.
struct Sample: Sendable {
    var at: UInt64                    // uptime nanoseconds
    var cpu, waiting, diskRead, diskWrite, energy, wakeups: UInt64?
    var pCore, instructions, cycles, logicalWrites, gpu: UInt64?
    var qos: [UInt64]?
    var contextSwitches, faults, pageins, machMsgsSent, machMsgsReceived, unixSyscalls, machSyscalls: UInt32?

    init(_ p: ProcInfo, at: UInt64) {
        self.at = at
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

/// The last few minutes of one process, for sparklines: one entry per refresh, oldest first.
struct History: Sendable {
    static let capacity = 120             // four minutes at the 2 s refresh
    var cpu: [Double?] = []               // percent of one core
    var memory: [Double?] = []            // footprint, bytes
    var disk: [Double?] = []              // read + written, bytes per second
    var power: [Double?] = []             // watts

    mutating func append(_ p: ProcInfo) {
        let r = p.rates
        func push(_ a: inout [Double?], _ v: Double?) {
            a.append(v)
            if a.count > Self.capacity { a.removeFirst(a.count - Self.capacity) }
        }
        push(&cpu, r?.cpuPercent)
        push(&memory, p.footprint.map { Double($0) })
        push(&disk, r.flatMap { r in r.diskRead.flatMap { a in r.diskWrite.map { a + $0 } } })
        push(&power, r?.watts)
    }
}
