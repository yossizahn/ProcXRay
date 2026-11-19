import SwiftUI

/// A row of the Activity outline: an activity, a thread of the waits, or one call under either. Calls carry
/// their parent so a row's identity stays unique and stable while the trace grows.
enum ActivityRowID: Hashable {
    case group(Int)
    case thread(group: Int, tid: UInt64)
    case call(group: Int, tid: UInt64?, id: Int)
}

private struct ActivityNode: Identifiable {
    enum Kind {
        case group(SyscallActivity)
        case thread(group: Int, tid: UInt64, calls: [SyscallRecord])
        case call(SyscallRecord)
    }
    let id: ActivityRowID
    let kind: Kind

    /// Built when the outline asks, so a collapsed activity of thousands of calls costs nothing.
    var children: [ActivityNode]? {
        switch kind {
        case .group(let g):
            if g.operation == .waits {
                return SyscallActivityView.threads(g.calls).map { tid, calls in
                    ActivityNode(id: .thread(group: g.id, tid: tid), kind: .thread(group: g.id, tid: tid, calls: calls))
                }
            }
            return g.calls.map { ActivityNode(id: .call(group: g.id, tid: nil, id: $0.id), kind: .call($0)) }
        case .thread(let gid, let tid, let calls):
            return calls.map { ActivityNode(id: .call(group: gid, tid: tid, id: $0.id), kind: .call($0)) }
        case .call:
            return nil
        }
    }
}

struct SyscallActivityView: View {
    let groups: [SyscallActivity]
    /// The traced process's thread names (SyscallActivity.Context.threadNames).
    var threadNames: [UInt64: String] = [:]
    let filtered: Bool
    @Binding var selection: Set<ActivityRowID>

    var body: some View {
        if groups.isEmpty {
            ContentUnavailableView(filtered ? "No matching activity" : "No activity to show",
                                   systemImage: "waveform.path.ecg",
                                   description: Text(filtered ? "Try another filter." : "Files, connections, Mach messages, launches and waits appear here. See Calls for the full trace."))
        } else {
            // List with children: an NSOutlineView, so the arrow keys move and ← → collapse and expand.
            List(groups.map { ActivityNode(id: .group($0.id), kind: .group($0)) }, children: \.children, selection: $selection) { node in
                switch node.kind {
                case .group(let g): GroupLabel(group: g)
                case .thread(_, let tid, let calls): Text(Self.threadLabel(tid, calls.count, name: threadNames[tid])).font(.callout)
                case .call(let r): ActivityCall(call: r, threadName: threadNames[r.thread])
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: ActivityRowID.self) { ids in
                Button("Copy") { Pasteboard.copy(Self.text(groups, only: ids, names: threadNames)) }
                    .disabled(ids.isEmpty)
            }
            .onCopyCommand { [ids = selection, threadNames] in
                [NSItemProvider(object: Self.text(groups, only: ids, names: threadNames) as NSString)]
            }
        }
    }

    nonisolated static func threads(_ calls: [SyscallRecord]) -> [(UInt64, [SyscallRecord])] {
        Dictionary(grouping: calls, by: \.thread).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    nonisolated static func threadLabel(_ tid: UInt64, _ count: Int, name: String? = nil) -> String {
        "Thread " + String(tid) + (name.map { " (\($0))" } ?? "") + " · " + count.formatted() + (count == 1 ? " call" : " calls")
    }

    nonisolated static func groupLine(_ g: SyscallActivity) -> String {
        var parts: [String] = []
        if g.operation != .waits { parts.append(g.calls[0].start.map(SyscallTraceView.seconds) ?? "before") }
        parts.append(g.operation.rawValue)
        if !g.target.isEmpty { parts.append(g.target) }
        return parts.joined(separator: "  ") + "  — " + g.detail
    }

    /// The activities as indented text, every call under its activity. With `only`, just the selected rows: an
    /// activity or thread brings its calls, a call under an activity that is also selected isn't repeated.
    nonisolated static func text(_ groups: [SyscallActivity], only: Set<ActivityRowID>? = nil, names: [UInt64: String] = [:]) -> String {
        var lines: [String] = []
        func want(_ id: ActivityRowID) -> Bool { only?.contains(id) ?? true }
        for g in groups {
            let whole = want(.group(g.id))
            if whole { lines.append(groupLine(g)) }
            if g.operation == .waits {
                for (tid, calls) in threads(g.calls) {
                    let thread = whole || want(.thread(group: g.id, tid: tid))
                    if thread { lines.append("    " + threadLabel(tid, calls.count, name: names[tid])) }
                    for r in calls where thread || want(.call(group: g.id, tid: tid, id: r.id)) {
                        lines.append("        " + SyscallTraceView.line(r))
                    }
                }
            } else {
                for r in g.calls where whole || want(.call(group: g.id, tid: nil, id: r.id)) {
                    lines.append("    " + SyscallTraceView.line(r))
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}

private struct GroupLabel: View {
    let group: SyscallActivity

    var body: some View {
        HStack(spacing: 8) {
            if group.operation != .waits {
                Text(group.calls[0].start.map(SyscallTraceView.seconds) ?? "before")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Text(group.operation.rawValue).fontWeight(.medium)
            if !group.target.isEmpty {
                Text(group.target).lineLimit(1).truncationMode(.middle).help(group.target)
            }
            Spacer(minLength: 8)
            Text(group.detail).foregroundStyle(group.allFailed ? Color.red : group.failures > 0 ? .orange : .secondary)
        }
        .font(.callout)
    }
}

private struct ActivityCall: View {
    let call: SyscallRecord
    var threadName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(call.start.map(SyscallTraceView.seconds) ?? "before")  [\(String(call.thread))\(threadName.map { " " + $0 } ?? "")]  \(call.name)(\(call.namedArgsText))")
            HStack {
                Text(call.resultText).foregroundStyle(call.failed ? Color.red : .secondary)
                if let duration = call.duration { Text(SyscallTraceView.duration(duration)) }
                if !call.caller.isEmpty { Text(call.caller) }
                if !call.paths.isEmpty { Text(call.pathText) }
            }
            .foregroundStyle(.secondary)
        }
        .font(.system(size: 11, design: .monospaced))
    }
}

enum Pasteboard {
    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
