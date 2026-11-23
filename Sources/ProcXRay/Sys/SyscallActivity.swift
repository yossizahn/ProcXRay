import Darwin
import Foundation

/// What a call is about, for the overview's colours and the filter by kind.
enum TraceKind: Int, CaseIterable, Sendable {
    case files, network, messages, other, waits

    var title: String {
        switch self {
        case .files: "Files"
        case .network: "Network"
        case .messages: "Messages"
        case .other: "Other"
        case .waits: "Waits"
        }
    }
}

/// Which of a trace's calls the views show: the same for Activity, Calls, Lanes and Summary.
struct TraceScope: Sendable, Equatable {
    var errorsOnly = false
    /// None: every thread.
    var threads: Set<UInt64> = []
    /// None: every kind.
    var kinds: Set<TraceKind> = []
    /// Calls that started in this stretch (ns since the trace started); nil: the whole trace.
    var range: ClosedRange<UInt64>?

    func admits(_ r: SyscallRecord, _ context: SyscallActivity.Context) -> Bool {
        if errorsOnly && !r.failed { return false }
        if !threads.isEmpty && !threads.contains(r.thread) { return false }
        if let range, !range.contains(r.time) { return false }
        return kinds.isEmpty || kinds.contains(SyscallActivity.kind(r, context))
    }
}

/// One activity: a descriptor's life (its open, what was done with it, its close), a burst of the same call on
/// the same target, or one call. IDs remain stable while new calls join.
struct SyscallActivity: Identifiable, Sendable {
    enum Operation: String, Sendable {
        case read = "Read", write = "Write", readWrite = "Read and write", open = "Open", list = "List directory"
        case lookup = "Look up", xattr = "Read extended attributes", metadata = "Change metadata"
        case sync = "Flush to disk", lock = "Lock"
        case rename = "Rename", remove = "Remove", mkdir = "Create directory", link = "Create link", copy = "Copy"
        case connect = "Connect", connection = "Connection", listen = "Listen", accept = "Accept connection"
        case send = "Send", receive = "Receive"
        case message = "Message", launch = "Launch", signal = "Signal", inspect = "Inspect process"
        case loadImage = "Load libraries", initializers = "Run initializers", openLibrary = "Open library (dlopen)"
        case closeLibrary = "Close library (dlclose)", symbol = "Look up symbols (dlsym)", address = "Find an address's library (dladdr)"
        case kernelCall = "Kernel call"
        case dyldSetup = "Launch setup (dyld)", mainStarts = "main() starts"
        case waits = "Waits and event polls"
    }

    /// What the build knows besides the records.
    struct Context: Sendable {
        /// The traced process.
        var pid: Int32 = 0
        /// Port names in the traced process's port space → the process holding the receive right (MachPortNames).
        var ports: [UInt32: Int32] = [:]
        var processNames: [Int32: String] = [:]
        /// Port names that lead to no other process: "task port", "IOKit connection (…)", "own port".
        var portKinds: [UInt32: String] = [:]
        /// The traced process's thread names: "main thread", "com.apple.NSEventThread".
        var threadNames: [UInt64: String] = [:]
        /// The traced process's working directory as the trace started, when it could be read: what its relative
        /// paths start from until it changes directory.
        var cwd: String?

        func process(_ pid: Int32) -> String {
            if pid == self.pid { return "itself" }
            return processNames[pid].map { "\($0) (\(pid))" } ?? "pid \(pid)"
        }

        /// Where a mach_msg2_trap send goes: "cfprefsd (412)", "Kernel: task port", "Own port", "Reply to
        /// cfprefsd (412)" for an answer to a request (its send-once right is used up by the send, so no listing
        /// finds it), or one label for all sends nothing names.
        ///
        /// The port listings first, then the call itself: the process of the thread the send woke, else a kernel
        /// object when a send-and-receive got its reply without blocking (SyscallDecoder.sched). Seen in Finder:
        /// runs of new port names (thread ports from task_threads), each asked a question or two and released
        /// within a millisecond, before any listing.
        func destination(_ port: UInt32, sendOnce: Bool = false, call r: SyscallRecord? = nil) -> String {
            if !sendOnce, let p = ports[port] { return process(p) }
            if !sendOnce, let k = portKinds[port] { return k == "own port" ? Self.ownPort : "Kernel: " + k }
            if let p = r?.receiver { return (sendOnce ? "Reply to " : "") + process(p) }
            if sendOnce { return "Reply (send-once)" }
            if let r, Self.answeredInKernel(r) { return "Kernel object (port gone before any listing)" }
            // One label for all of them: each is usually a new name used once, so naming the port made a one-call
            // row per send (~80 in a trace of a Shortcuts run). The call's own arguments still show the port.
            return Self.unknownDestination
        }

        static let ownPort = "Own port"
        static let unknownDestination = "Unknown destination (port not in any listing)"

        /// Where a mach_msg2_trap send went, for a call on its own (the Calls table): the kernel routine that handled
        /// it ("task_info (kernel)"), else as `destination` names it. nil for other calls and receives.
        func messageTarget(_ r: SyscallRecord) -> String? {
            guard r.name == "mach_msg2_trap", let a = r.args, let m = Self.messagePort(a) else { return nil }
            if let k = r.kernelRoutine { return MIGRoutines.name(k) + " (kernel)" }
            return destination(m.port, sendOnce: m.sendOnce, call: r)
        }

        /// A send-and-receive that succeeded without its thread giving up the CPU: a process's answer needs the
        /// receiver to run, so the kernel answered it.
        static func answeredInKernel(_ r: SyscallRecord) -> Bool {
            guard r.blocked == false, r.error == 0, let a = r.args, a.count > 1 else { return false }
            let both = UInt64(MACH_SEND_MSG | MACH_RCV_MSG)
            return a[1] & both == both
        }

        /// The listings and the call itself say nothing about where this send went.
        func unnamed(_ port: UInt32, sendOnce: Bool, call r: SyscallRecord) -> Bool {
            !sendOnce && ports[port] == nil && portKinds[port] == nil && r.receiver == nil && r.kernelRoutine == nil
                && !Self.answeredInKernel(r)
        }

        /// A send's destination port and whether it is a send-once right (MACH_MSG_TYPE_MOVE_SEND_ONCE: a reply).
        static func messagePort(_ a: [UInt64]) -> (port: UInt32, sendOnce: Bool)? {
            guard a.count > 3, a[1] & UInt64(MACH_SEND_MSG) != 0 else { return nil }
            return (UInt32(truncatingIfNeeded: a[3]), a[2] & 0x1f == UInt64(MACH_MSG_TYPE_MOVE_SEND_ONCE))
        }
    }

    var operation: Operation
    var target: String
    var calls: [SyscallRecord]
    /// Read or received, and written or sent, by the calls that succeeded. Messages: bytes sent.
    var bytesIn: UInt64 = 0
    var bytesOut: UInt64 = 0
    /// Calls that failed, leaving out "try again" (EAGAIN) and a non-blocking connect under way (EINPROGRESS).
    var failures = 0
    var threads: Set<UInt64> = []
    var longest: UInt64?
    /// Set for a descriptor's life: everything done with this descriptor from its open (or first use) to its close.
    var fd: Int32?
    /// A descriptor from socket() or accept(), or one used for socket calls.
    var socket = false
    /// Each call's own operation, for naming a descriptor's life after what was done with it.
    var kinds: Set<Operation> = []
    /// Messages: time spent in calls that also waited for the reply.
    var replyTime: UInt64 = 0
    /// The target is a stand-in ("Socket", "fd 4") that the first label of the descriptor replaces.
    private var provisional = false
    /// A roll-up (`rollUp`): how many paths under `target`, a directory, a burst of this operation touched. 0: none.
    var paths = 0
    /// Recurs (`mergeRecurring`): about this often (ns), `rounds` times so far. Such activities hold every round's
    /// calls and stay at the end of the list, above the waits, instead of at their first round's time.
    var period: UInt64?
    var rounds = 0
    var id: Int { calls[0].id }
    /// Kept at the end of the list whatever its time: the waits, and what recurs.
    var pinned: Bool { operation == .waits || period != nil }

    /// What stands where a row's time does: when it started, how often it recurs, nothing for the waits.
    var when: String {
        if operation == .waits { return "" }
        if let period { return "every " + Self.interval(period) }
        return calls[0].start.map(SyscallTraceView.seconds) ?? "before"
    }

    /// "1.0 s", "250 ms": a period, which is never exact enough for more digits.
    static func interval(_ ns: UInt64) -> String {
        ns >= 1_000_000_000 ? String(format: "%.1f s", Double(ns) / 1e9) : String(format: "%.0f ms", Double(ns) / 1e6)
    }

    var bytes: UInt64 { bytesIn + bytesOut }
    var allFailed: Bool { failures > 0 && failures == calls.count }

    var detail: String {
        let count = calls.count
        var parts = [String]()
        func size(_ n: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file) }
        let first = calls[0]
        if operation == .waits {
            parts.append("\(threads.count) thread\(threads.count == 1 ? "" : "s")")
            if let longest { parts.append("longest " + SyscallTraceView.duration(longest)) }
        } else if allFailed || (count == 1 && first.state == .inProgress) {
            if rounds > 0 { parts.append("\(rounds.formatted()) times") }
            if paths > 0 { parts.append("\(paths.formatted()) paths") }
            parts.append(first.resultText)
        } else {
            if rounds > 0 { parts.append("\(rounds.formatted()) times") }
            if paths > 0 {
                var p = "\(paths.formatted()) paths"
                // A burst's own length; what recurs has its period instead.
                if period == nil, let a = calls.first?.start, let b = calls.lazy.compactMap(\.end).max(), b > a {
                    p += " in " + SyscallTraceView.duration(b - a)
                }
                parts.append(p)
            }
            switch operation {
            case .readWrite: parts += ["read " + size(bytesIn), "wrote " + size(bytesOut)]
            case .read: parts.append(size(bytesIn))
            case .write: parts.append(size(bytesOut))
            case .connection:
                if bytesOut > 0 { parts.append("sent " + size(bytesOut)) }
                if bytesIn > 0 { parts.append("received " + size(bytesIn)) }
            case .message:
                if bytesOut > 0 { parts.append(size(bytesOut) + " sent") }
                if replyTime > 0 { parts.append("replies took " + SyscallTraceView.duration(replyTime)) }
            case .kernelCall:
                if replyTime > 0 { parts.append("took " + SyscallTraceView.duration(replyTime)) }
            case .mainStarts:
                parts.append(first.resultText)
            default: break
            }
            if fd != nil {
                if kinds.contains(.sync) && operation != .sync { parts.append("flushed to disk") }
                if kinds.contains(.lock) && operation != .lock { parts.append("locked") }
            }
            if failures > 0 {
                // Why, from the first failure: "1 failed: ECONNREFUSED (Connection refused)".
                let why = calls.first { $0.failed && $0.error != Int64(EAGAIN) && $0.error != Int64(EINPROGRESS) }
                    .map { $0.resultText.hasPrefix("-1 ") ? String($0.resultText.dropFirst(3)) : $0.resultText }
                parts.append("\(failures.formatted()) failed" + (why.map { ": " + $0 } ?? ""))
            }
            if calls.last?.state == .inProgress { parts.append("in progress") }
            if Self.libraryOperations.contains(operation) {
                let total = calls.compactMap(\.duration).reduce(0, +)
                if total > 0 { parts.append("took " + SyscallTraceView.duration(total)) }
            }
            if parts.isEmpty { parts.append("Succeeded") }
        }
        if count > 1 {
            let unit = switch operation {
            case .loadImage: "images"
            case .initializers: "initializers"
            case .symbol: "symbols"
            default: "calls"
            }
            parts.append("\(count.formatted()) " + unit)
        }
        return parts.joined(separator: " · ")
    }

    /// dyld's work, from its trace events rather than syscalls (SyscallRecord.isLibraryCall).
    static let libraryOperations: Set<Operation> = [.loadImage, .initializers, .openLibrary, .closeLibrary, .symbol, .address,
                                                     .dyldSetup]

    /// A descriptor's calls more than this far apart are separate activities: a log file kept open for the whole
    /// trace shows as its bursts of writes, not one activity at its open.
    static let descriptorGap: UInt64 = 1_000_000_000
    /// Repeats of a one-off call (the same lookup, the same message destination) this close join one activity.
    static let repeatGap: UInt64 = 500_000_000

    /// `threads`: only those threads' calls make activities (none: every thread's). A close on any thread still
    /// ends its descriptor's life (as with `errorsOnly`), so a descriptor number another thread closed and reused
    /// starts a new activity.
    static func build(_ records: [SyscallRecord], filter: String, errorsOnly: Bool, threads: Set<UInt64> = [],
                      context: Context = Context()) -> [Self] {
        matching(build(records, scope: TraceScope(errorsOnly: errorsOnly, threads: threads), context: context), filter)
    }

    /// The activities with `filter` in their own text or in a call's.
    static func matching(_ groups: [Self], _ filter: String) -> [Self] {
        guard !filter.isEmpty else { return groups }
        return groups.filter { g in
            [g.operation.rawValue, g.target, g.detail, g.when].contains { $0.localizedCaseInsensitiveContains(filter) } ||
            g.calls.contains { r in
                [r.name, r.argsText, r.resultText, r.caller].contains { $0.localizedCaseInsensitiveContains(filter) }
            }
        }
    }

    /// Every activity of the calls `scope` lets through, newest first, then what recurs, then the waits. A close
    /// outside the scope still ends its descriptor's life.
    static func build(_ records: [SyscallRecord], scope: TraceScope, context: Context = Context()) -> [Self] {
        var groups: [Self] = []
        var waits: Self?
        /// Descriptor → its activity, until its close.
        var sessions: [Int32: Int] = [:]
        /// Thread, operation, target and error of a one-off call → its activity, for repeats.
        var recent: [String: Int] = [:]
        /// The working directory, followed through the trace's chdir calls: a program walking a tree changes into
        /// each directory and names what is in it ("5.9", "functions"), which alone says nothing.
        var cwd = context.cwd
        /// Threads with a working directory of their own (pthread_chdir): their relative paths stay as given.
        var ownDirectory = Set<UInt64>()
        /// The activity holding the messages to the process's own ports.
        var ownPorts: Int?
        // Start order also puts calls still pending at trace stop in their proper position.
        for r in records.sorted(by: { ($0.time, $0.id) < ($1.time, $1.id) }) {
            let name = r.name.hasSuffix("_nocancel") ? String(r.name.dropLast(9)) : r.name
            let skip = !scope.admits(r, context)
            if isWait(name, r) {
                if skip { continue }
                if waits == nil { waits = Self(operation: .waits, target: "", calls: []) }
                waits?.append(r, kind: nil)
                continue
            }
            let a = r.args ?? []
            let arg0 = a.first.map { Int32(truncatingIfNeeded: $0) }
            if r.state == .done, r.error == 0 {
                if name == "chdir", let p = r.paths.first { cwd = absolute(p, in: cwd) }
                if name == "fchdir" { cwd = r.firstFDLabel.flatMap { $0.hasPrefix("/") ? $0 : nil } }
            }
            if ["__pthread_chdir", "__pthread_fchdir", "pthread_chdir", "pthread_fchdir"].contains(name) { ownDirectory.insert(r.thread) }
            // An …at call's path starts from its descriptor's directory, unless that is AT_FDCWD (-2).
            let cwd = ownDirectory.contains(r.thread) ? nil : cwd
            let base = atCalls.contains(name) ? (arg0 == -2 ? cwd : r.firstFDLabel.flatMap { $0.hasPrefix("/") ? $0 : nil }) : cwd
            // A close, or a descriptor replaced by dup2, ends that descriptor's life.
            if name == "close" || name == "guarded_close_np" || name == "dup2" || name == "dup3" {
                let fd = name.hasPrefix("dup") ? (a.count > 1 ? Int32(truncatingIfNeeded: a[1]) : nil) : arg0
                if let fd, let i = sessions.removeValue(forKey: fd), !skip, name.hasSuffix("close") { groups[i].append(r, kind: nil) }
                continue
            }
            if skip { continue }
            let found = operation(name, r)
            let op = found?.0, onFD = found?.1 ?? false

            // A call that makes a descriptor starts its life.
            if r.state == .done, r.error == 0, let made = createdDescriptor(name, r) {
                var g = Self(operation: op ?? .open, target: "", calls: [])
                g.fd = made
                if op == .open {
                    g.target = r.paths.first.map { absolute($0, in: base) } ?? "Path unavailable"
                } else {
                    g.socket = true
                    g.provisional = true
                    g.target = name == "accept" ? "Accepted connection" : "Socket"
                }
                g.append(r, kind: op)
                sessions[made] = groups.count
                groups.append(g)
                continue
            }

            // A call on a descriptor joins its life.
            let usesFD = onFD || (op == nil && FdLabeler.fdArgs(r).contains { $0.0 == 0 })
            if usesFD, let fd = arg0, fd >= 0 {
                if let i = sessions[fd], let last = groups[i].calls.last, r.time <= (last.end ?? last.time) + descriptorGap {
                    groups[i].append(r, kind: op)
                    groups[i].relabel(r)
                } else if let op {
                    var g = Self(operation: op, target: r.firstFDLabel ?? "fd \(fd)", calls: [])
                    g.fd = fd
                    g.provisional = r.firstFDLabel == nil
                    g.append(r, kind: op)
                    sessions[fd] = groups.count
                    groups.append(g)
                }
                continue
            }
            guard let op else { continue }

            let target = target(op, name, r, context, base: base)
            // Messages to its own ports are one activity for the whole trace, whichever thread sent them and
            // whenever: each burst was a row of its own, and a Finder or a Bun makes hundreds.
            if op == .message, target == Context.ownPort {
                if let i = ownPorts { groups[i].append(r, kind: op) } else {
                    var g = Self(operation: op, target: target, calls: [])
                    g.append(r, kind: op)
                    ownPorts = groups.count
                    groups.append(g)
                }
                continue
            }
            var g = Self(operation: op, target: target, calls: [])
            // One-off calls a thread repeats on the same target, with the same result, join one activity. Another
            // thread's are its own: two threads asking the same service are separate work that shares a destination.
            let key = String(r.thread) + "\u{0}" + op.rawValue + "\u{0}" + target + "\u{0}" + String(r.error)
            if repeats.contains(op), let i = recent[key], let last = groups[i].calls.last,
               last.state == .done, r.state == .done, r.time - last.time <= repeatGap {
                groups[i].append(r, kind: op)
                continue
            }
            g.append(r, kind: op)
            if repeats.contains(op) { recent[key] = groups.count }
            groups.append(g)
        }
        for i in groups.indices where groups[i].fd != nil { groups[i].settle() }
        groups = mergeRecurring(rollUp(groups))
        let recurring = groups.filter { $0.period != nil }.sorted { ($0.period!, $0.calls[0].time) < ($1.period!, $1.calls[0].time) }
        groups.removeAll { $0.period != nil }
        groups.reverse()
        groups += recurring
        if let waits { groups.append(waits) }
        return groups
    }

    // MARK: Roll-ups

    /// The same operation on paths this close in time (start to start) is one burst.
    static let burstGap: UInt64 = 50_000_000
    /// A directory takes a burst's activities once they touch this many paths under it.
    static let burstPaths = 4
    private static let rollable: Set<Operation> = [.lookup, .xattr, .metadata, .open, .list, .read, .write, .readWrite,
                                                   .remove, .mkdir, .sync]

    /// A program walking a directory tree looks up hundreds of paths within milliseconds, each a row of its own:
    /// a burst of one operation becomes one activity per directory holding its paths ("Look up /a/skills · 735
    /// paths in 14 ms"), whichever threads made the calls (a scan is often spread over a pool). `groups` oldest first.
    static func rollUp(_ groups: [Self]) -> [Self] {
        var byOperation: [Operation: [Int]] = [:]
        for (i, g) in groups.enumerated() where rollable.contains(g.operation) && g.target.hasPrefix("/") {
            byOperation[g.operation, default: []].append(i)
        }
        var out = groups
        var gone = Set<Int>()
        for (_, indexes) in byOperation where indexes.count >= burstPaths {
            var burst: [Int] = []
            func close() {
                defer { burst = [] }
                guard burst.count >= burstPaths else { return }
                var clusters: [(dir: String, members: [Int])] = []
                directories(burst.map { (groups[$0].target.split(separator: "/"), $0) }, depth: 0, into: &clusters)
                for c in clusters {
                    var g = groups[c.members[0]]
                    g.paths = Set(c.members.map { groups[$0].target }).count
                    g.target = c.dir
                    g.fd = nil
                    for m in c.members.dropFirst() { g.absorb(groups[m]); gone.insert(m) }
                    g.calls.sort { ($0.time, $0.id) < ($1.time, $1.id) }
                    out[c.members[0]] = g
                }
            }
            for i in indexes {
                if let last = burst.last, groups[i].calls[0].time - groups[last].calls[0].time > burstGap { close() }
                burst.append(i)
            }
            close()
        }
        return gone.isEmpty ? out : out.enumerated().filter { !gone.contains($0.offset) }.map(\.element)
    }

    /// The directories that take a burst's paths: going down from the root, the first one whose paths are spread
    /// over its entries. One entry holding four fifths of them is the tree being walked, so the search goes on
    /// inside it (and inside its siblings, for theirs); "/" and its entries hold everything and say nothing.
    private static func directories(_ items: [(parts: [Substring], index: Int)], depth: Int,
                                    into out: inout [(dir: String, members: [Int])]) {
        guard Set(items.map { $0.parts }).count >= burstPaths else { return }
        var entries: [Substring: [(parts: [Substring], index: Int)]] = [:]
        for it in items where it.parts.count > depth { entries[it.parts[depth], default: []].append(it) }
        let most = entries.values.map(\.count).max() ?? 0
        if depth < 2 || most * 5 >= items.count * 4 {
            for (_, e) in entries.sorted(by: { $0.key < $1.key }) { directories(e, depth: depth + 1, into: &out) }
            return
        }
        out.append(("/" + items[0].parts[..<depth].joined(separator: "/"), items.map(\.index).sorted()))
    }

    /// Fewer rounds than this are a coincidence, not a rhythm.
    static let recurringRounds = 3

    /// What a program does on a timer (re-reading a config file every second) came as one row a round, scattered
    /// through the list: activities with the same operation and target at even intervals become one, "every 1.0 s".
    /// Repeats closer than `repeatGap` on one thread are one activity already. `groups` oldest first.
    static func mergeRecurring(_ groups: [Self]) -> [Self] {
        var same: [String: [Int]] = [:]
        for (i, g) in groups.enumerated() where g.calls.last?.state == .done && g.calls[0].start != nil {
            same[g.operation.rawValue + "\u{0}" + g.target, default: []].append(i)
        }
        var out = groups
        var gone = Set<Int>()
        for (_, indexes) in same where indexes.count >= recurringRounds {
            let starts = indexes.map { groups[$0].calls[0].time }
            let gaps = zip(starts.dropFirst(), starts).map { $0 - $1 }
            let period = gaps.sorted()[gaps.count / 2]
            guard period >= burstGap else { continue }
            // Even: within 15% of the usual gap. A long trace may have a late round in five.
            let slack = max(period * 15 / 100, 2_000_000)
            let odd = gaps.filter { $0 > period + slack || $0 + slack < period }.count
            guard gaps.count < 5 ? odd == 0 : odd * 5 <= gaps.count else { continue }
            var g = groups[indexes[0]]
            g.period = period
            g.rounds = indexes.count
            g.fd = nil
            g.paths = indexes.map { groups[$0].paths }.max() ?? 0
            for m in indexes.dropFirst() { g.absorb(groups[m]); gone.insert(m) }
            out[indexes[0]] = g
        }
        return gone.isEmpty ? out : out.enumerated().filter { !gone.contains($0.offset) }.map(\.element)
    }

    /// Takes another activity's calls and counts.
    private mutating func absorb(_ o: Self) {
        calls += o.calls
        bytesIn += o.bytesIn; bytesOut += o.bytesOut
        failures += o.failures
        replyTime += o.replyTime
        threads.formUnion(o.threads)
        kinds.formUnion(o.kinds)
        if let l = o.longest { longest = max(longest ?? 0, l) }
    }

    private static let repeats: Set<Operation> = [.lookup, .xattr, .metadata, .message, .inspect, .signal, .open,
                                                  .loadImage, .initializers, .openLibrary, .closeLibrary, .symbol, .address,
                                                  .kernelCall]

    private mutating func append(_ r: SyscallRecord, kind: Operation?) {
        calls.append(r)
        if operation == .waits {
            threads.insert(r.thread)
            if let duration = r.duration { longest = max(longest ?? 0, duration) }
            return
        }
        if let kind {
            kinds.insert(kind)
            if [.connect, .send, .receive, .listen, .accept].contains(kind) { socket = true }
        }
        if r.failed && r.error != Int64(EAGAIN) && r.error != Int64(EINPROGRESS) { failures += 1 }
        guard r.state != .inProgress, r.error == 0 else { return }
        switch kind {
        case .read, .receive: bytesIn += SyscallFormat.wide(r)
        case .write, .send: bytesOut += SyscallFormat.wide(r)
        case .message, .kernelCall:
            guard let a = r.args, a.count > 2 else { break }
            // A vector send (MACH64_MSG_VECTOR: XPC) has its vector count there, not its size.
            if a[1] & 0x1_0000_0000 == 0 { bytesOut += a[2] >> 32 }
            if a[1] & UInt64(MACH_RCV_MSG) != 0, let d = r.duration { replyTime += d }
        default: break
        }
    }

    /// A socket's label gains its endpoints on connect: the latest wins. A file keeps the path it was opened with.
    private mutating func relabel(_ r: SyscallRecord) {
        guard let label = r.firstFDLabel, !label.isEmpty, provisional || socket else { return }
        target = label
        provisional = false
    }

    /// Names a descriptor's life after what was done with it.
    private mutating func settle() {
        let k = kinds
        if socket {
            if k.contains(.listen) { operation = .listen }
            else if !k.isDisjoint(with: [.send, .receive, .read, .write]) { operation = .connection }
            else if k.contains(.connect) { operation = .connect }
            else if k.contains(.accept) { operation = .accept }
            else { operation = .connection }
            return
        }
        let reads = k.contains(.read), writes = k.contains(.write)
        if reads && writes { operation = .readWrite }
        else if writes { operation = .write }
        else if reads { operation = .read }
        else { operation = [Operation.list, .sync, .lock, .metadata, .xattr, .copy, .lookup, .open].first(where: k.contains) ?? .open }
    }

    /// The descriptor a successful call made: open's, socket's, accept's.
    private static func createdDescriptor(_ name: String, _ r: SyscallRecord) -> Int32? {
        switch name {
        case "open", "openat", "open_dprotected_np", "openat_dprotected_np", "guarded_open_np", "guarded_open_dprotected_np",
             "open_extended", "socket", "accept":
            let fd = Int32(truncatingIfNeeded: r.ret)
            return fd >= 0 ? fd : nil
        default: return nil
        }
    }

    /// Calls whose first argument is the directory their path starts from.
    private static let atCalls: Set<String> = [
        "openat", "openat_dprotected_np", "fstatat", "fstatat64", "faccessat", "readlinkat", "unlinkat", "mkdirat", "fchmodat",
        "fchownat", "utimensat", "setattrlistat", "getattrlistat", "linkat", "renameat", "renameatx_np", "symlinkat",
        "clonefileat", "mkfifoat", "mknodat"]

    /// "5.9" in /usr/share/zsh → "/usr/share/zsh/5.9"; a path that is absolute, or relative to a directory nobody
    /// knows, stays as it is.
    static func absolute(_ path: String, in directory: String?) -> String {
        guard !path.hasPrefix("/"), !path.isEmpty, let directory, directory.hasPrefix("/") else { return path }
        var parts = directory.split(separator: "/")
        for c in path.split(separator: "/") where c != "." {
            if c == ".." { _ = parts.popLast() } else { parts.append(c) }
        }
        return "/" + parts.joined(separator: "/")
    }

    private static func target(_ op: Operation, _ name: String, _ r: SyscallRecord, _ context: Context, base: String? = nil) -> String {
        let a = r.args ?? []
        switch op {
        case .message:
            return Context.messagePort(a).map { context.destination($0.port, sendOnce: $0.sendOnce, call: r) } ?? "Destination unavailable"
        case .signal:
            guard a.count > 1 else { return "Target unavailable" }
            return SyscallFormat.signalName(Int32(truncatingIfNeeded: a[1])) + " to " + context.process(Int32(truncatingIfNeeded: a[0]))
        case .inspect:
            return a.count > 1 ? context.process(Int32(truncatingIfNeeded: a[1])) : "Target unavailable"
        case .launch where name == "fork" || name == "vfork":
            return r.state == .done && r.error == 0 ? "child pid \(Int32(truncatingIfNeeded: r.ret))" : "child process"
        case .connection:
            return "Socket"
        case .openLibrary, .closeLibrary:
            // dlopen(NULL) opens the main program.
            return r.paths.first ?? (r.argValues.first == "NULL" ? "Main program" : "Library unavailable")
        case .symbol:
            if let p = r.paths.first { return p }
            switch r.argValues.first {
            case "RTLD_DEFAULT": return "Any loaded library (RTLD_DEFAULT)"
            case "RTLD_NEXT": return "Libraries after the caller's (RTLD_NEXT)"
            case "RTLD_SELF": return "The caller's library onward (RTLD_SELF)"
            case "RTLD_MAIN_ONLY": return "Main program (RTLD_MAIN_ONLY)"
            default: return "A library opened before the trace"
            }
        case .loadImage, .initializers, .address:
            return ""
        case .dyldSetup, .mainStarts:
            return r.paths.first ?? ""
        case .kernelCall:
            return r.kernelRoutine.map(MIGRoutines.name) ?? "Kernel routine unavailable"
        case .read, .write, .send, .receive, .connect, .listen, .accept:
            return r.firstFDLabel ?? "Unknown descriptor"
        default:
            return r.paths.isEmpty ? "Path unavailable" : r.paths.count == 1 ? absolute(r.paths[0], in: base) : r.pathText
        }
    }

    static func kind(_ r: SyscallRecord, _ context: Context) -> TraceKind {
        let name = r.name.hasSuffix("_nocancel") ? String(r.name.dropLast(9)) : r.name
        if isWait(name, r) { return .waits }
        guard let (op, onFD) = operation(name, r) else { return .other }
        switch op {
        case .message, .kernelCall: return .messages
        case .connect, .connection, .listen, .accept, .send, .receive: return .network
        case .launch, .signal, .inspect, .loadImage, .initializers, .openLibrary, .closeLibrary, .symbol, .address,
             .dyldSetup, .mainStarts, .waits:
            return .other
        default:
            // read, write, fstat… on a descriptor: by what the descriptor is, when that is known.
            guard onFD else { return .files }
            guard let label = r.firstFDLabel else { return .other }
            if label.hasPrefix("/") { return .files }
            if label.hasSuffix(" socket") || ["TCP", "UDP", "unix ", "ICMP"].contains(where: label.hasPrefix) { return .network }
            return .other   // a pipe, a kqueue
        }
    }

    /// What one call does, and whether its first argument is the descriptor it acts on.
    private static func operation(_ name: String, _ r: SyscallRecord) -> (Operation, Bool)? {
        switch name {
        case "read", "pread", "readv", "preadv": return (.read, true)
        case "write", "pwrite", "writev", "pwritev": return (.write, true)
        case "recvfrom", "recvmsg", "recvmsg_x": return (.receive, true)
        case "sendto", "sendmsg", "sendmsg_x": return (.send, true)
        case "connect", "connectx": return (.connect, true)
        case "bind", "listen": return (.listen, true)
        case "accept": return (.accept, true)
        case "socket": return (.connection, false)
        case "fstat", "fstat64", "fgetattrlist", "fstatfs", "fstatfs64": return (.lookup, true)
        case "stat", "lstat", "stat64", "lstat64", "fstatat", "fstatat64", "access", "faccessat", "getattrlist",
             "readlink", "readlinkat", "statfs", "statfs64", "pathconf":
            return (.lookup, false)
        case "getdirentries", "getdirentries64", "getdirentriesattr", "getattrlistbulk": return (.list, true)
        case "fgetxattr", "flistxattr": return (.xattr, true)
        case "getxattr", "listxattr": return (.xattr, false)
        case "fsetxattr", "fremovexattr", "fchmod", "fchown", "futimes", "futimens", "fsetattrlist", "fchflags", "ftruncate":
            return (.metadata, true)
        case "setxattr", "removexattr", "chmod", "chown", "lchown", "utimes", "lutimes", "setattrlist", "setattrlistat",
             "chflags", "lchflags", "fchmodat", "fchownat", "utimensat", "truncate":
            return (.metadata, false)
        case "fsync", "fdatasync": return (.sync, true)
        case "flock": return (.lock, true)
        case "fcntl":
            guard let a = r.args, a.count > 1 else { return nil }
            switch Int32(truncatingIfNeeded: a[1]) {
            case F_FULLFSYNC, 85: return (.sync, true)                             // 85: F_BARRIERFSYNC
            case F_SETLK, F_SETLKW, 10, 90, 91, 93: return (.lock, true)            // F_SETLKWTIMEOUT, F_OFD_SETLK(W)(TIMEOUT)
            default: return nil
            }
        case "open", "openat", "open_dprotected_np", "openat_dprotected_np", "guarded_open_np", "guarded_open_dprotected_np",
             "open_extended":
            return (.open, false)
        case "rename", "renameat", "renameatx_np", "exchangedata": return (.rename, false)
        case "unlink", "unlinkat", "rmdir": return (.remove, false)
        case "mkdir", "mkdirat", "mkdir_extended": return (.mkdir, false)
        case "link", "linkat", "symlink", "symlinkat": return (.link, false)
        case "clonefile", "clonefileat", "fclonefileat", "copyfile": return (.copy, false)
        case "posix_spawn", "execve", "__mac_execve", "fork", "vfork": return (.launch, false)
        case "kill": return (.signal, false)
        case "proc_info", "proc_info_extended_id":
            // PIDINFO, PIDFDINFO, PIDFILEPORTINFO, PIDRUSAGE about another process; the rest list or control.
            guard let a = r.args, a.count > 1, [2, 3, 6, 9].contains(a[0]) else { return nil }
            let pid = Int32(truncatingIfNeeded: a[1])
            return pid > 0 ? (.inspect, false) : nil
        case "mach_msg2_trap":
            guard let a = r.args, a.count > 3, a[1] & UInt64(MACH_SEND_MSG) != 0 else { return nil }
            return (r.kernelRoutine != nil ? .kernelCall : .message, false)
        case "load image" where r.isLibraryCall: return (.loadImage, false)
        case "initializer" where r.isLibraryCall: return (.initializers, false)
        case "dlopen" where r.isLibraryCall: return (.openLibrary, false)
        case "dlclose" where r.isLibraryCall: return (.closeLibrary, false)
        case "dlsym" where r.isLibraryCall: return (.symbol, false)
        case "dladdr" where r.isLibraryCall: return (.address, false)
        case "dyld setup" where r.isLibraryCall: return (.dyldSetup, false)
        case "main()" where r.isLibraryCall: return (.mainStarts, false)
        default: return nil
        }
    }

    static func isWait(_ name: String, _ r: SyscallRecord) -> Bool {
        switch name {
        case "kevent", "kevent64", "kevent_qos", "kevent_id", "select", "pselect", "poll",
             "ulock_wait", "ulock_wait2", "psynch_cvwait", "psynch_mutexwait", "mach_wait_until",
             "semaphore_wait_trap", "semaphore_timedwait_trap",
             // sleep() and nanosleep(), waiting for a signal, waiting for a child to exit.
             // (The trace names some of these without their underscores.)
             "__semwait_signal", "semwait_signal", "sigsuspend", "__sigwait", "sigwait", "wait4", "waitid": return true
        case "workq_kernreturn": return r.args?.first == 4 // WQOPS_THREAD_RETURN
        case "mach_msg2_trap", "mach_msg_trap", "mach_msg_overwrite_trap":
            guard let args = r.args, args.count > 1 else { return false }
            return args[1] & UInt64(MACH_RCV_MSG) != 0 && args[1] & UInt64(MACH_SEND_MSG) == 0
        default: return false
        }
    }
}
