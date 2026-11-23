import SwiftUI

/// The ports between this process and one peer, both directions, from the helper's last lsmp run
/// (HelperClient.machPortDetail). Shown in a popover from a Mach peer row's menu in Files & Ports.
struct MachPortDetailView: View {
    let pid: Int32
    let peer: Int32
    let peerName: String
    @State private var result: Swift.Result<MachPortDetailReply, MachLoader.Failure>?

    private struct Row: Identifiable {
        let id: Int
        let d: MachPortDetail
        let pidOfUs: Int32
        /// This process holds the send right; the peer receives.
        var toPeer: Bool { d.sender == pidOfUs }
        var direction: String { toPeer ? "we → it" : "it → us" }
        var ourName: String { Self.name(toPeer ? d.senderName : d.receiverName) }
        var theirName: String { Self.name(toPeer ? d.receiverName : d.senderName) }
        /// lsmp gives a port inside a port set no name of its own (all 14,218 on the machine measured).
        static func name(_ n: String) -> String { n.isEmpty ? "in a port set" : n }
        var right: String { d.sendOnce ? "send-once" : d.sendRefs > 1 ? "send ×\(d.sendRefs)" : "send" }
        var full: Bool { d.queueLimit > 0 && d.queued >= d.queueLimit }
        /// A limit of 0 (21,773 of 87,780 receive rights on the machine measured) prints as the count alone.
        var queue: String { d.queueLimit > 0 ? "\(d.queued) of \(d.queueLimit)" : "\(d.queued)" }
        var queuedSort: Int { d.queued }
        var flags: String { d.flags.joined(separator: ", ") }
        var notifications: String { d.notifications.joined(separator: ", ") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch result {
            case nil:
                HStack { ProgressView().controlSize(.small); Text("Reading ports…") }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failure(let e)?:
                Text(e.message).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .success(let r)?:
                let rows = r.ports.enumerated().map { Row(id: $0.offset, d: $0.element, pidOfUs: pid) }
                    // Full queues first, then our rights to its ports, then the most messages waiting.
                    .sorted { ($0.full ? 0 : 1, $0.toPeer ? 0 : 1, -$0.d.queued, $0.ourName) < ($1.full ? 0 : 1, $1.toPeer ? 0 : 1, -$1.d.queued, $1.ourName) }
                let out = rows.filter(\.toPeer).count, full = rows.filter(\.full).count
                Text("\(peerName) \(peer): \(out) rights of ours to its ports, \(rows.count - out) of its rights to ours\(full > 0 ? " · \(full) full queue\(full == 1 ? "" : "s")" : "") · lsmp run at \(r.at.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
                // No column sorted to begin with: the order worked out above.
                DataTable(rows: rows, columns: [
                    .text("direction", "Direction", width: 56) { $0.direction },
                    .text("ourName", "Our name", width: 88, mono: true) { $0.ourName },
                    .text("theirName", "Its name", width: 88, mono: true) { $0.theirName },
                    .text("right", "Right", width: 66) { $0.right },
                    DataColumn(id: "queue", title: "Queue", width: 66, numeric: true, text: { $0.queue },
                               color: { $0.full ? .systemOrange : nil },
                               tooltip: { r in "\(r.queue). " + (r.full ? "Full: senders block or time out until the receiver takes a message" : "Messages waiting, of the queue's limit") },
                               less: { $0.d.queued < $1.d.queued }),
                    .number("boosts", "Boosts", width: 48, value: { $0.d.boosts > 0 ? $0.d.boosts : nil }, format: { String($0) }),
                    DataColumn(id: "flags", title: "Flags · receiver asked for", width: 180, minWidth: 100,
                               help: "Port flags, then the notifications the receiving process asked for. \"no sender\" is how a server notices its clients going away.",
                               text: { r in [r.flags, r.notifications].filter { !$0.isEmpty }.joined(separator: " · ") },
                               color: { _ in .secondaryLabelColor },
                               less: { ($0.flags, $0.notifications) < ($1.flags, $1.notifications) }),
                ], initialSort: ("", true), exportName: "Mach ports \(pid) and \(peer)")
            }
        }
        .padding(10)
        // The columns' ideal widths plus spacing come to ~710 points.
        .frame(width: 780, height: 380)
        .task {
            let (pid, peer) = (pid, peer)
            result = await Task.detached { HelperClient.shared.machPortDetail(pid: pid, peer: peer) }.value
        }
    }
}
