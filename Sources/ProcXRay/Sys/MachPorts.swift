import Foundation

/// Mach port links between processes, from `lsmp -a -j` run as root by the helper (docs/ipc-map-proposal.md,
/// Layer 2). Unprivileged, lsmp reads no process at all; as root it reads every one, in ~3 s.
///
/// Every port entry carries an `ipc-object` id that is the same in every process holding a right to that port.
/// A send or send-once right joined to the receive right with the same id is a link: the sender can message the
/// receiver. Rights to kernel objects (task, thread, IOKit, memory entries…) have no receive right in any
/// process and drop out. Most pairs hold rights both ways (request port one way, reply port the other), so a
/// link only says who can send to whom, not which side is the client.
struct MachLink: Codable, Hashable, Sendable {
    /// Holds send or send-once rights…
    let from: Int32
    /// …to ports this process holds the receive right of.
    let to: Int32
    /// Distinct ports.
    var ports: Int
    /// Messages waiting on those ports, not yet received by `to`.
    var queued: Int
}

/// A memory entry (VM object handed out as a port) that 2…`MachSnapshot.fewHolders` processes hold.
struct SharedMemoryEntry: Codable, Hashable, Sendable {
    var holders: [Int32]
    /// From lsmp's description ("VM-MAP-COPY(0x…, 16KiB)"); nil when it gives none.
    var bytes: UInt64?
}

/// `holder` has a right to `target`'s task port: control (can read and write its memory, start threads), read
/// or inspect, by lsmp's type. Name ports (identity only) and ID tokens are only counted in `kernelObjects`.
struct TaskPortRight: Codable, Hashable, Sendable {
    let holder: Int32
    let target: Int32
    let flavor: String
}

/// One process's port space, from lsmp's per-process totals (`total` is Activity Monitor's "Ports").
struct MachPortCounts: Codable, Hashable, Sendable {
    var total = 0
    var send = 0
    var receive = 0
    /// Send-once rights held: mostly replies this process owes to whoever sent it a request. Tens of
    /// thousands is a reply leak (1Password Browser Helper: 14,561, measured 2026-11-13).
    var sendOnce = 0
    var portSets = 0
    /// Rights to ports whose receiver died, not yet released (WindowServer: 21,173).
    var deadNames = 0
    var deadNameRequests = 0
    var vouchers = 0
    /// Receive rights whose queue is full (msg_count ≥ queue_limit): senders block or time out.
    var fullQueues = 0
}

struct MachSnapshot: Codable, Sendable {
    var links: [MachLink] = []
    /// Per receiver, how many other processes can send to it.
    var senders: [Int32: Int] = [:]
    var processCount = 0
    var at = Date()
    /// Per process, its port space totals.
    var counts: [Int32: MachPortCounts] = [:]

    // Kernel objects: rights to ports the kernel receives on, which pair with no process.

    /// Per process, IOKit user client class → connections (IOKIT-CONNECT: an open driver connection).
    var iokit: [Int32: [String: Int]] = [:]
    /// Memory entries few processes share; ones shared more widely only counted, per process, in `widelyShared`.
    var sharedMemory: [SharedMemoryEntry] = []
    var widelyShared: [Int32: Int] = [:]
    /// Task ports a process holds for another process.
    var taskRights: [TaskPortRight] = []

    /// Holders of so many processes' task ports (coreservicesd: 63 % of them) that holding ours says
    /// nothing about this process; folded like a common service. Same share as `commonShare`.
    func isCommonTaskHolder(_ pid: Int32) -> Bool {
        guard processCount > 0 else { return false }
        let n = Set(taskRights.lazy.filter { $0.holder == pid }.map(\.target)).count
        return Double(n) >= Self.commonShare * Double(processCount)
    }
    func taskTargets(of pid: Int32) -> Int { Set(taskRights.lazy.filter { $0.holder == pid }.map(\.target)).count }
    /// Per process, every kernel object type it holds rights to → count (threads, semaphores, vouchers, its own
    /// task port, memory entries…), except IOKit connections, which `iokit` lists by class.
    var kernelObjects: [Int32: [String: Int]] = [:]

    /// A memory entry held by more processes than this is a system-wide mapping (shared caches, fonts), not a
    /// link between the few that hold it. The proposal measured 69 pairs at 6 or fewer.
    static let fewHolders = 6

    /// A peer that at least this share of processes can send to is a common service (launchd, logd, notifyd,
    /// cfprefsd…): it is on every process's map and says nothing about this one. 10 % folded 36 peers on the
    /// machine measured in the proposal, leaving a median of 6 peers per process.
    static let commonShare = 0.10

    func isCommon(_ pid: Int32) -> Bool {
        processCount > 0 && Double(senders[pid] ?? 0) >= Self.commonShare * Double(processCount)
    }
    func share(_ pid: Int32) -> Double { processCount > 0 ? Double(senders[pid] ?? 0) / Double(processCount) : 0 }

    /// One process's Mach peers, both directions merged per peer, most ports first.
    func peers(of pid: Int32) -> [MachPeer] {
        var by: [Int32: MachPeer] = [:]
        for l in links {
            if l.from == pid {
                by[l.to, default: MachPeer(pid: l.to)].sendsTo += l.ports
                by[l.to]!.queuedThere += l.queued
            } else if l.to == pid {
                by[l.from, default: MachPeer(pid: l.from)].receivesFrom += l.ports
                by[l.from]!.queuedHere += l.queued
            }
        }
        for k in by.keys { by[k]!.common = isCommon(k); by[k]!.share = share(k) }
        return by.values.sorted { ($0.sendsTo + $0.receivesFrom, $1.pid) > ($1.sendsTo + $1.receivesFrom, $0.pid) }
    }

    /// Pairs the rights in `lsmp -j` output. Nil when it isn't lsmp's JSON.
    static func parse(_ data: Data) -> MachSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let procs = root["processes"] as? [[String: Any]] else { return nil }
        var recv: [String: (pid: Int32, queued: Int)] = [:]
        var sends: [(pid: Int32, obj: String)] = []
        var iokit: [Int32: [String: Int]] = [:]
        var kobjects: [Int32: [String: Int]] = [:]
        var memory: [String: (holders: Set<Int32>, bytes: UInt64?)] = [:]
        var fullQueues: [Int32: Int] = [:]
        // Task ports by flavor: ipc-object → holders, and each process's lowest-named right of the flavor.
        var taskHolders: [String: [String: Set<Int32>]] = [:]
        var lowestTask: [String: [Int32: (name: UInt64, obj: String)]] = [:]
        func walk(_ pid: Int32, _ q: [String: Any]) {
            if let o = q["ipc-object"] as? String, let r = q["rights"] as? [String] {
                if r.contains("recv") {
                    let queued = (q["msg_count"] as? NSNumber)?.intValue ?? 0
                    recv[o] = (pid, queued)
                    if let limit = (q["queue_limit"] as? NSNumber)?.intValue, limit > 0, queued >= limit { fullQueues[pid, default: 0] += 1 }
                }
                if r.contains("send") || r.contains("send once") {
                    sends.append((pid, o))
                    // A typed right is a kernel object; "port" / "UNKNOWN" are ports a process receives on.
                    if let t = q["type"] as? String, !["port", "port set", "dead name", "UNKNOWN"].contains(t) {
                        let desc = q["description"] as? String
                        if t == "IOKIT-CONNECT" {
                            iokit[pid, default: [:]][Self.className(desc) ?? "unknown user client", default: 0] += 1
                        } else {
                            kobjects[pid, default: [:]][t, default: 0] += 1
                        }
                        if t.contains("MEMORY") {
                            memory[o, default: ([], Self.size(desc))].holders.insert(pid)
                        }
                        if Self.taskFlavors.contains(t) {
                            taskHolders[t, default: [:]][o, default: []].insert(pid)
                            if let n = (q["name"] as? String).flatMap({ UInt64($0.dropFirst(2), radix: 16) }),
                               n < lowestTask[t]?[pid]?.name ?? .max {
                                lowestTask[t, default: [:]][pid] = (n, o)
                            }
                        }
                    }
                }
            }
            // A port set's member ports are listed inside it.
            for m in q["members"] as? [[String: Any]] ?? [] { walk(pid, m) }
        }
        for p in procs {
            guard let pid = (p["pid"] as? NSNumber)?.int32Value else { continue }
            for q in p["ports"] as? [[String: Any]] ?? [] { walk(pid, q) }
        }
        struct Pair: Hashable { let from, to: Int32 }
        var ports: [Pair: Set<String>] = [:]
        for s in sends {
            guard let r = recv[s.obj], r.pid != s.pid else { continue }
            ports[Pair(from: s.pid, to: r.pid), default: []].insert(s.obj)
        }
        var snap = MachSnapshot()
        snap.processCount = procs.count
        for p in procs {
            guard let pid = (p["pid"] as? NSNumber)?.int32Value else { continue }
            func n(_ k: String) -> Int { (p[k] as? NSNumber)?.intValue ?? 0 }
            snap.counts[pid] = MachPortCounts(total: n("total"), send: n("send_rights"), receive: n("receive_rights"),
                                              sendOnce: n("send_once_rights"), portSets: n("port_sets"), deadNames: n("dead_names"),
                                              deadNameRequests: n("dead_name requests"), vouchers: n("vouchers"),
                                              fullQueues: fullQueues[pid] ?? 0)
        }
        snap.links = ports.map { k, objs in
            MachLink(from: k.from, to: k.to, ports: objs.count, queued: objs.reduce(0) { $0 + (recv[$1]?.queued ?? 0) })
        }
        for l in snap.links { snap.senders[l.to, default: 0] += 1 }
        snap.iokit = iokit
        snap.kernelObjects = kobjects
        snap.taskRights = Self.taskRights(holders: taskHolders, lowest: lowestTask)
        for m in memory.values where m.holders.count > 1 {
            if m.holders.count <= fewHolders {
                snap.sharedMemory.append(SharedMemoryEntry(holders: m.holders.sorted(), bytes: m.bytes))
            } else {
                for h in m.holders { snap.widelyShared[h, default: 0] += 1 }
            }
        }
        return snap
    }

    /// Task port types paired across processes.
    static let taskFlavors: Set<String> = ["TASK-CONTROL", "TASK-READ", "TASK-INSPECT"]

    /// Who holds whose task port. lsmp's `pid` on a task right is the holder's own pid, not the target's, so
    /// the target comes from the join: a process's own task port (mach_task_self) is its lowest-named right
    /// of that flavor, `0x203` for most and `0x103` for a few. Measured on 802 processes: every one of the 801
    /// control ports got exactly one owner, and 565 rights to another process's control port were found.
    static func taskRights(holders: [String: [String: Set<Int32>]],
                           lowest: [String: [Int32: (name: UInt64, obj: String)]]) -> [TaskPortRight] {
        var out: Set<TaskPortRight> = []
        for (type, objs) in holders {
            var owner: [String: Int32] = [:]
            for (pid, own) in lowest[type] ?? [:] { owner[own.obj] = pid }
            let flavor = String(type.dropFirst(5)).lowercased()
            for (obj, pids) in objs where pids.count > 1 {
                guard let target = owner[obj] else { continue }
                for h in pids where h != target { out.insert(TaskPortRight(holder: h, target: target, flavor: flavor)) }
            }
        }
        return Array(out)
    }

    /// "RootDomainUserClient(0x100001031)" → "RootDomainUserClient".
    static func className(_ desc: String?) -> String? {
        guard let d = desc, !d.isEmpty else { return nil }
        return String(d.prefix { $0 != "(" })
    }

    /// The size in "VM-MAP-COPY(0xa6b4af5fca787fd5, 16KiB)": the last comma-separated field in the parentheses.
    static func size(_ desc: String?) -> UInt64? {
        guard let d = desc, let open = d.firstIndex(of: "("), d.hasSuffix(")") else { return nil }
        guard let field = d[d.index(after: open)..<d.index(before: d.endIndex)].split(separator: ",").last?
            .trimmingCharacters(in: .whitespaces) else { return nil }
        let units: [(String, UInt64)] = [("GiB", 1 << 30), ("MiB", 1 << 20), ("KiB", 1 << 10), ("B", 1)]
        for (u, m) in units where field.hasSuffix(u) {
            guard let n = Double(field.dropLast(u.count)) else { return nil }
            return UInt64(n * Double(m))
        }
        return nil
    }

    /// One process's memory entries shared with few others: per other holder, the entries and their bytes.
    func sharedMemory(of pid: Int32) -> [(pid: Int32, entries: Int, bytes: UInt64, holders: Int)] {
        var by: [Int32: (entries: Int, bytes: UInt64, holders: Int)] = [:]
        for m in sharedMemory where m.holders.contains(pid) {
            for h in m.holders where h != pid {
                var v = by[h] ?? (0, 0, 0)
                v.entries += 1
                v.bytes += m.bytes ?? 0
                v.holders = max(v.holders, m.holders.count)
                by[h] = v
            }
        }
        return by.map { ($0.key, $0.value.entries, $0.value.bytes, $0.value.holders) }.sorted { ($0.entries, $1.pid) > ($1.entries, $0.pid) }
    }
}

/// One peer of a process, as the Connections tab shows it.
struct MachPeer: Hashable, Sendable {
    let pid: Int32
    /// Ports of the peer's that this process can send to, and the reverse.
    var sendsTo = 0
    var receivesFrom = 0
    /// Messages waiting on the peer's ports that this process can send to, and on this process's ports that
    /// the peer can send to (this process not draining its queue).
    var queuedThere = 0
    var queuedHere = 0
    var common = false
    var share = 0.0

    /// The Mach services the peer is known to offer (LaunchdServices), when this process can send to it.
    var services: [String] = []

    var direction: String {
        sendsTo > 0 && receivesFrom > 0 ? "Mach ⇄" : sendsTo > 0 ? "Mach →" : "Mach ←"
    }
    var summary: String {
        var parts: [String] = []
        if let first = services.first {
            parts.append(services.count == 1 ? first
                         : "one of \(services.count): " + services.prefix(3).joined(separator: ", ") + (services.count > 3 ? "…" : ""))
        }
        if sendsTo > 0 { parts.append("\(sendsTo) of its ports") }
        if receivesFrom > 0 { parts.append("\(receivesFrom) of ours to it") }
        if queuedThere > 0 { parts.append("\(queuedThere) queued there") }
        if queuedHere > 0 { parts.append("\(queuedHere) queued here") }
        if common { parts.append("common service, \(Int((share * 100).rounded())) % of processes") }
        return parts.joined(separator: " · ")
    }
}

/// The last snapshot, shared by every Connections tab. Taking one costs ~3 s of root work, so it is reused
/// for `maxAge` unless asked for fresh.
enum MachLoader {
    enum Result: Sendable {
        case snapshot(MachSnapshot)
        /// Why there is none: no helper, not an admin, lsmp failed.
        case unavailable(String)
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: MachSnapshot?
    nonisolated(unsafe) private static var refreshing = false
    nonisolated(unsafe) private static var failedAt: Date?
    static let maxAge: TimeInterval = 30

    /// The last snapshot, whatever its age, without waiting; for the process table's Mach columns. When it is
    /// older than `maxAge` a new one is taken in the background, unless the last try failed (no helper, not
    /// an admin) less than `maxAge` ago.
    static func current() -> MachSnapshot? {
        lock.lock(); defer { lock.unlock() }
        let stale = cached.map { -$0.at.timeIntervalSinceNow >= maxAge } ?? true
        let backingOff = failedAt.map { -$0.timeIntervalSinceNow < maxAge } ?? false
        if stale, !refreshing, !backingOff {
            refreshing = true
            DispatchQueue.global(qos: .utility).async {
                let r = HelperClient.shared.machPorts()
                lock.lock()
                refreshing = false
                switch r {
                case .success(let s): cached = s; failedAt = nil
                case .failure: failedAt = Date()
                }
                lock.unlock()
            }
        }
        return cached
    }

    /// The last snapshot, if any, without starting one.
    static func peek() -> MachSnapshot? { lock.lock(); defer { lock.unlock() }; return cached }

    static func load(fresh: Bool = false) -> Result {
        lock.lock()
        if !fresh, let c = cached, -c.at.timeIntervalSinceNow < maxAge { lock.unlock(); return .snapshot(c) }
        lock.unlock()
        switch HelperClient.shared.machPorts() {
        case .success(let s):
            lock.lock(); cached = s; lock.unlock()
            return .snapshot(s)
        case .failure(let e):
            return .unavailable(e.message)
        }
    }

    struct Failure: Error { let message: String }
}

/// Mach service names: which names a process can be reached at, so a Mach link to it can be named.
///
/// - A launchd job declares its names in its plist's `MachServices` (2,115 names in 799 plists on the machine
///   measured in the proposal; 437 jobs declare exactly one, so the name is certain).
/// - An XPC service is looked up by its bundle identifier.
enum LaunchdServices {
    /// Job label → its MachServices names, from every LaunchDaemons / LaunchAgents folder. Read once.
    static let byLabel: [String: [String]] = {
        let dirs = ["/System/Library/LaunchDaemons", "/System/Library/LaunchAgents", "/Library/LaunchDaemons",
                    "/Library/LaunchAgents", NSHomeDirectory() + "/Library/LaunchAgents"]
        var out: [String: [String]] = [:]
        for d in dirs {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: d)) ?? [] where f.hasSuffix(".plist") {
                guard let data = FileManager.default.contents(atPath: d + "/" + f),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let label = plist["Label"] as? String,
                      let names = plist["MachServices"] as? [String: Any], !names.isEmpty else { continue }
                out[label, default: []] += names.keys.sorted()
            }
        }
        return out
    }()

    nonisolated(unsafe) private static var bundleIDs: [String: String?] = [:]
    private static let lock = NSLock()

    /// The names `p` serves on: its XPC service bundle identifier, else its launchd job's MachServices.
    static func names(of p: ProcInfo) -> [String] {
        if SmartTree.isXPCService(p), let path = p.path, let id = bundleID(ofExecutable: path) { return [id] }
        if let l = p.launchdLabel { return byLabel[l] ?? [] }
        return []
    }

    /// ".../Foo.xpc/Contents/MacOS/Foo" → the CFBundleIdentifier in Foo.xpc's Info.plist.
    private static func bundleID(ofExecutable path: String) -> String? {
        guard let r = path.range(of: "/Contents/MacOS/", options: .backwards) else { return nil }
        let bundle = String(path[..<r.lowerBound])
        lock.lock()
        if let c = bundleIDs[bundle] { lock.unlock(); return c }
        lock.unlock()
        let id = Bundle(path: bundle)?.bundleIdentifier
        lock.lock(); bundleIDs[bundle] = id; lock.unlock()
        return id
    }
}
