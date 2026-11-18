import SwiftUI

struct SyscallActivityView: View {
    let groups: [SyscallActivity]
    let filtered: Bool

    var body: some View {
        if groups.isEmpty {
            ContentUnavailableView(filtered ? "No matching activity" : "No activity to show",
                                   systemImage: "waveform.path.ecg",
                                   description: Text(filtered ? "Try another filter." : "File operations, connection attempts and waits appear here. See Calls for the full trace."))
        } else {
            List(groups) { group in
                DisclosureGroup {
                    if group.operation == .waits {
                        WaitThreads(calls: group.calls)
                    } else {
                        ForEach(group.calls) { call in ActivityCall(call: call) }
                    }
                } label: {
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
                        Text(group.detail).foregroundStyle(group.calls[0].failed && group.operation != .waits ? Color.red : .secondary)
                    }
                    .font(.callout)
                }
            }
            .listStyle(.inset)
        }
    }
}

private struct WaitThreads: View {
    let calls: [SyscallRecord]

    var body: some View {
        let threads = Dictionary(grouping: calls, by: \.thread)
        ForEach(threads.keys.sorted(), id: \.self) { tid in
            let records = threads[tid] ?? []
            DisclosureGroup("Thread " + String(tid) + " · " + records.count.formatted() + (records.count == 1 ? " call" : " calls")) {
                ForEach(records) { call in ActivityCall(call: call) }
            }
        }
    }
}

private struct ActivityCall: View {
    let call: SyscallRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(call.start.map(SyscallTraceView.seconds) ?? "before")  [\(String(call.thread))]  \(call.name)(\(call.namedArgsText))")
            HStack {
                Text(call.resultText).foregroundStyle(call.failed ? Color.red : .secondary)
                if let duration = call.duration { Text(SyscallTraceView.duration(duration)) }
                if !call.caller.isEmpty { Text(call.caller) }
                if !call.paths.isEmpty { Text(call.pathText) }
            }
            .foregroundStyle(.secondary)
        }
        .font(.system(size: 11, design: .monospaced))
        .textSelection(.enabled)
    }
}
