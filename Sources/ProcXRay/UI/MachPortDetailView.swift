import SwiftUI

/// A button on a Mach peer row in Connections that lists the ports behind the link.
struct MachPortsButton: View {
    let pid: Int32
    let peer: Int32
    let peerName: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: { Image(systemName: "list.bullet.rectangle") }
            .buttonStyle(.borderless)
            .help("List the ports behind this link: their names, rights, queues, boosts and flags")
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                MachPortDetailView(pid: pid, peer: peer, peerName: peerName)
            }
    }
}

/// The ports between this process and one peer, both directions, from the helper's last lsmp run
/// (HelperClient.machPortDetail).
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
                Table(rows) {
                    TableColumn("Direction") { r in Text(r.direction) }.width(min: 52, ideal: 56)
                    TableColumn("Our name") { r in Text(r.ourName).monospaced().lineLimit(1) }.width(min: 80, ideal: 88)
                    TableColumn("Its name") { r in Text(r.theirName).monospaced().lineLimit(1) }.width(min: 80, ideal: 88)
                    TableColumn("Right") { r in Text(r.right) }.width(min: 60, ideal: 66)
                    TableColumn("Queue") { r in
                        Text(r.queue).monospacedDigit().foregroundStyle(r.full ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                            .help(r.full ? "Full: senders block or time out until the receiver takes a message" : "Messages waiting, of the queue's limit")
                    }.width(min: 60, ideal: 66)
                    TableColumn("Boosts") { r in Text(r.d.boosts > 0 ? "\(r.d.boosts)" : "").monospacedDigit() }.width(min: 44, ideal: 48)
                    TableColumn("Flags · receiver asked for") { r in
                        let both = [r.flags, r.notifications].filter { !$0.isEmpty }.joined(separator: " · ")
                        Text(both).foregroundStyle(.secondary).lineLimit(1)
                            .help("Port flags (\(r.flags.isEmpty ? "none" : r.flags)), then the notifications the receiving process asked for (\(r.notifications.isEmpty ? "none" : r.notifications)). \"no sender\" is how a server notices its clients going away.")
                    }.width(min: 100, ideal: 180)
                }
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
