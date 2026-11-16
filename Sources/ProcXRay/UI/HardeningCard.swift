import SwiftUI

/// The runtime hardening the kernel turned on for the process (SecurityConfig): read directly for the user's
/// own processes, through the helper for other users'.
struct HardeningCard: View {
    @Environment(Store.self) var store
    let proc: ProcInfo
    var exited = false
    @State private var state: Loaded = .reading

    enum Loaded: Equatable { case reading, read(SecurityConfig, viaHelper: Bool), unreadable }

    var body: some View {
        Card(title: "Runtime hardening", systemImage: "shield.lefthalf.filled", trailing: trailing) {
            switch state {
            case .reading:
                Text(exited ? "The process exited before this was read." : "Reading…").foregroundStyle(.secondary)
            case .unreadable:
                Text(exited ? "The process exited before this was read."
                     : store.helperState.isRunning ? "Not readable: the helper couldn't read it either."
                     : "Not readable (another user's process; the privileged helper can read it).")
                    .foregroundStyle(.secondary)
            case .read(let c, let viaHelper):
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(SecurityConfig.all, id: \.0.rawValue) { flag, name, about in
                        let on = c.contains(flag)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: on ? "checkmark.circle.fill" : "minus.circle")
                                .foregroundStyle(on ? Color.green : Color.secondary)
                            Text(name).foregroundStyle(on ? .primary : .secondary)
                            Text(about).font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                    }
                    Text("From the kernel (os_security_config_get_for_proc)\(viaHelper ? ", read as root through the privileged helper" : "").")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .task(id: "\(proc.key)|\(exited)|\(store.helperState.isRunning)") { await load() }
    }

    private var trailing: String? {
        guard case .read(let c, _) = state else { return nil }
        return "\(SecurityConfig.all.filter { c.contains($0.0) }.count) of \(SecurityConfig.all.count)"
    }

    private func load() async {
        guard !exited else { if state == .reading { state = .unreadable }; return }
        let pid = proc.pid, helper = store.helperState.isRunning
        state = await Task.detached { () -> Loaded in
            if let c = SecurityConfig.read(pid) { return .read(c, viaHelper: false) }
            if helper, let c = HelperClient.shared.securityConfig(pid) { return .read(c, viaHelper: true) }
            return .unreadable
        }.value
    }
}
