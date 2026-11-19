import Darwin
import SwiftUI

/// TaskDetail for one process: read directly for the user's own processes, through the helper for other users'.
enum TaskDetailLoad: Equatable {
    case reading, read(TaskDetail, viaHelper: Bool), unreadable

    static func load(_ pid: pid_t, helper: Bool) async -> TaskDetailLoad {
        await Task.detached { () -> TaskDetailLoad in
            if let d = TaskDetail.read(pid) { return .read(d, viaHelper: false) }
            if helper, let d = HelperClient.shared.taskDetail(pid) { return .read(d, viaHelper: true) }
            return .unreadable
        }.value
    }

    var detail: TaskDetail? { if case .read(let d, _) = self { d } else { nil } }
    var via: FactRow.Via { if case .read(_, true) = self { .helper } else { .direct } }

    /// The text a card shows while there's nothing to show.
    @MainActor static func placeholder(_ s: TaskDetailLoad, exited: Bool, helper: Bool, part: String? = nil) -> Text {
        if exited { return Text("The process exited before this was read.") }
        switch s {
        case .reading: return Text("Reading…")
        case .read: return Text("Not readable: the helper reads \(part ?? "this") only for an admin user.")
        case .unreadable:
            return Text(helper ? "Not readable: the helper couldn't read it either."
                        : "Not readable (another user's process; the privileged helper can read it).")
        }
    }
}

/// The Security tab's task cards: the audit token with its session, and changes made from outside.
struct TaskDetailCards: View {
    @Environment(Store.self) var store
    let proc: ProcInfo
    var exited = false
    @State private var state: TaskDetailLoad = .reading

    var body: some View {
        let helper = store.helperState.isRunning
        Group {
            AuditTokenCard(proc: proc, state: state, exited: exited)
            Card(title: "Changes from outside", systemImage: "hand.point.up.left", trailing: extmodTrailing) {
                if let x = state.detail?.extmod {
                    FactGrid(rows: Self.extmodRows(x, via: state.via))
                } else {
                    TaskDetailLoad.placeholder(state, exited: exited, helper: helper, part: "another user's task").foregroundStyle(.secondary)
                }
            }
        }
        .task(id: "\(proc.key)|\(exited)|\(helper)") {
            guard !exited else { if state == .reading { state = .unreadable }; return }
            state = await TaskDetailLoad.load(proc.pid, helper: helper)
        }
    }

    private var extmodTrailing: String? {
        guard let x = state.detail?.extmod else { return nil }
        return x.anyFromOutside ? "reached into" : "none"
    }

    static func extmodRows(_ x: TaskExtmod, via: FactRow.Via) -> [FactRow] {
        let src = "task_info TASK_EXTMOD_INFO"
        func n(_ v: Int64) -> KVValue { .text(Fmt.count(v)) }
        return [
            FactRow("Task port taken by others", n(x.taskPortLookups), src, via: via,
                    help: "Times another process got this one's task port (task_for_pid): full control of it, as a debugger has."),
            FactRow("Threads created from outside", n(x.threadsCreatedFromOutside), src, via: via,
                    help: "Threads another process started inside this one: how code is injected."),
            FactRow("Registers set from outside", n(x.threadStateSets), src, via: via,
                    help: "Times another process set the registers of one of its threads (thread_set_state), as a debugger does at a breakpoint."),
            FactRow("Task ports it took", n(x.taskPortLookupsMade), src, via: via, help: "The same, done by this process to others."),
            FactRow("Threads it created elsewhere", n(x.threadsCreatedElsewhere), src, via: via),
            FactRow("Registers it set elsewhere", n(x.threadStateSetsMade), src, via: via),
            FactRow("Executable UUID", .text(x.uuid), src, via: via,
                    help: "The task's UUID, which is its main executable's (LC_UUID): two runs of /bin/sleep, on the Mac and in a VM, had the same one."),
        ]
    }
}

/// The process's audit token, and the audit session it names. The session's own record (flags, masks, terminal) is
/// readable by anyone.
struct AuditTokenCard: View {
    @Environment(Store.self) var store
    let proc: ProcInfo
    let state: TaskDetailLoad
    var exited = false

    var body: some View {
        Card(title: "Audit token", systemImage: "person.badge.key", trailing: trailing) {
            if let t = state.detail?.token {
                let s = AuditSessionRecord.read(t.asid)
                VStack(alignment: .leading, spacing: 8) {
                    FactGrid(rows: Self.tokenRows(t, via: state.via))
                    Divider()
                    FactGrid(rows: sessionRows(t, s))
                    let members = store.procs.values.filter { $0.asid == t.asid && $0.pid != proc.pid }.sorted { $0.pid < $1.pid }
                    if !members.isEmpty, members.count <= 60 {
                        Text("Also in this session").font(.subheadline).foregroundStyle(.secondary)
                        ChipFlow(procs: members)
                    }
                }
            } else {
                TaskDetailLoad.placeholder(state, exited: exited, helper: store.helperState.isRunning).foregroundStyle(.secondary)
            }
        }
    }

    private var trailing: String? { state.detail?.token.map { "session \($0.asid)" } }

    private static func user(_ uid: UInt32) -> String { "\(Native.userName(uid)) (\(uid))" }
    private static func group(_ gid: UInt32) -> String {
        guard let g = getgrgid(gid) else { return String(gid) }
        return "\(String(cString: g.pointee.gr_name)) (\(gid))"
    }

    static func tokenRows(_ t: AuditToken, via: FactRow.Via) -> [FactRow] {
        let src = "task_info TASK_AUDIT_TOKEN"
        return [
            FactRow("Audit user (auid)", .text(t.auid == UInt32.max ? "not set (AU_DEFAUDITID)" : user(t.auid)), src, via: via,
                    help: "Who logged in to the session: kept across su, sudo and setuid, unlike the user ids below."),
            FactRow("Effective user / group", .text("\(user(t.euid)) / \(group(t.egid))"), src, via: via,
                    help: "What permission checks use."),
            FactRow("Real user / group", .text("\(user(t.ruid)) / \(group(t.rgid))"), src, via: via,
                    help: "Who started it; differs from the effective ids in a setuid or setgid program."),
            FactRow("PID / version", .text("\(t.pid) / \(t.pidVersion)"), src, via: via,
                    help: "The version goes up on every exec: a service that checks callers by token tells one program run from the next, even under the same pid."),
            FactRow("Session ID (asid)", .text(String(t.asid)), src, via: via,
                    help: "The audit session it belongs to; children inherit it."),
        ]
    }

    private func sessionRows(_ t: AuditToken, _ s: AuditSessionRecord?) -> [FactRow] {
        let src = "auditon A_GETSINFO_ADDR"
        var rows: [FactRow] = []
        let session = proc.asid == t.asid ? proc.session : nil
        if let session {
            rows.append(FactRow("Login session", .text(session.label + (session.isOwn ? ", Proc X-Ray's own" : "")), column: "session"))
        }
        guard let s else {
            rows.append(FactRow("Session record", .text("not readable"), src))
            return rows
        }
        rows.append(FactRow("Session flags (AU_SESSION_FLAG)", .text(String(format: "0x%llx: ", s.flags) + s.flagText), src,
                            help: AuditSessionRecord.flagNames.map { "\($0.1): \($0.2)" }.joined(separator: "\n")))
        if s.auid != t.auid {
            rows.append(FactRow("Session's audit user", .text(s.auid == UInt32.max ? "not set" : Self.user(s.auid)), src,
                                help: "The session's record, where it differs from the token's."))
        }
        rows.append(FactRow("Audit masks", .text(String(format: "success 0x%08x, failure 0x%08x", s.maskSuccess, s.maskFailure)), src,
                            help: "Preselection masks: the audit event classes recorded for the session, on success and on failure."))
        rows.append(FactRow("Terminal (termid)", .text(s.terminalText), src,
                            help: "Where the login came from: a remote login's address, or the port it used."))
        return rows
    }
}

/// TASK_VM_INFO in full, under the Usage tab's Memory section: what the footprint is made of.
struct TaskMemoryCard: View {
    @Environment(Store.self) var store
    let proc: ProcInfo
    var exited = false
    @State private var state: TaskDetailLoad = .reading

    var body: some View {
        let helper = store.helperState.isRunning
        Card(title: "Memory breakdown", systemImage: "square.stack.3d.down.right", trailing: state.detail?.vm.map { Fmt.bytes($0.footprint) }) {
            if let v = state.detail?.vm {
                FactGrid(rows: Self.rows(v, basic: state.detail?.basic, via: state.via))
            } else {
                TaskDetailLoad.placeholder(state, exited: exited, helper: helper, part: "another user's memory").foregroundStyle(.secondary)
            }
        }
        // Read again with each refresh, like the Memory section above it.
        .task(id: "\(proc.key)|\(exited)|\(helper)|\(store.lastRefresh.timeIntervalSince1970)") {
            guard !exited else { if state == .reading { state = .unreadable }; return }
            state = await TaskDetailLoad.load(proc.pid, helper: helper)
        }
    }

    static func rows(_ v: TaskVMBreakdown, basic: TaskBasic?, via: FactRow.Via) -> [FactRow] {
        let src = "task_info TASK_VM_INFO"
        func b(_ x: UInt64) -> String { Fmt.bytes(x) }
        func b(_ x: Int64) -> String { Fmt.bytes(UInt64(max(0, x))) }
        func row(_ label: String, _ text: String, help: String? = nil, source: String = src) -> FactRow {
            FactRow(label, .text(text), source, via: via, help: help)
        }
        var rows = [
            row("Footprint", "\(b(v.footprint)), peak \(b(v.footprintPeak))",
                help: "What the system charges the process for: its own memory, resident or compressed, plus memory others hold on its behalf."),
            row("Resident", "\(b(v.resident)), peak \(b(v.residentPeak))" + (basic.map { ", most ever \(b($0.residentMax))" } ?? ""),
                help: "In RAM now, its own and shared (frameworks, the shared cache)."),
            row("Anonymous (internal)", "\(b(v.internal)), peak \(b(v.internalPeak))",
                help: "Memory with no file behind it: heaps, stacks. Most of the footprint."),
            row("File-backed (external)", "\(b(v.external)), peak \(b(v.externalPeak))",
                help: "Pages of mapped files in RAM; the system can drop them and read them again."),
            row("Reusable", "\(b(v.reusable)), peak \(b(v.reusablePeak))",
                help: "Freed by the allocator but kept mapped for reuse (madvise MADV_FREE_REUSABLE); not in the footprint."),
            row("Compressed", "\(b(v.compressed)), peak \(b(v.compressedPeak)), \(b(v.compressedLifetime)) over its life",
                help: "Its pages the memory compressor holds."),
            row("Decompressions", Fmt.count(Int64(v.decompressions)), help: "Pages brought back from the compressor."),
            row("Swapped in", b(v.swapins), help: "Memory read back from swap (a byte count: WindowServer measured 16 KB, one page)."),
            row("Purgeable", "volatile \(b(v.purgeableVolatileResident)) resident of \(b(v.purgeableVolatileVirtual)); nonvolatile \(b(v.purgeableNonvolatile))",
                help: "Caches the system may empty under memory pressure (volatile) or that the app has pinned for now (nonvolatile)."),
        ]
        if v.device > 0 { rows.append(row("Device", b(v.device), help: "Memory mapped from devices (IOKit).")) }
        // The kernel's owner-tag ledgers: what's in the footprint by kind, and memory with the tag it leaves out.
        let tags: [(String, Int64, Int64, Int64)] = [
            ("Graphics", v.graphics, v.graphicsCompressed, v.graphicsNoFootprint),
            ("Media", v.media, v.mediaCompressed, v.mediaNoFootprint),
            ("Neural Engine", v.neural, v.neuralCompressed, v.neuralNoFootprint),
            ("Network", v.network, v.networkCompressed, 0),
        ]
        for (name, fp, comp, outside) in tags where fp > 0 || outside > 0 {
            var s = b(fp)
            if comp > 0 { s += " (\(b(comp)) compressed)" }
            if outside > 0 { s += "; \(b(outside)) not in the footprint" }
            rows.append(row(name, s, help: "Memory its owner tagged \(name.lowercased()) (the kernel's ledgers), in the footprint above."))
        }
        rows.append(row("Limit left", v.limitRemaining == 0 ? "no limit" : b(v.limitRemaining),
                        help: "How far the footprint can grow before the memory limit (jetsam) stops it."))
        rows.append(row("Regions", "\(Fmt.count(Int64(v.regionCount))), \(b(UInt64(max(0, v.pageSize)))) pages"))
        return rows
    }
}
