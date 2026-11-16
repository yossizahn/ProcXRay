import SwiftUI

/// The runtime hardening the kernel turned on for the process (SecurityDetail): read directly for the user's
/// own processes, through the helper for other users'.
struct HardeningCard: View {
    @Environment(Store.self) var store
    let proc: ProcInfo
    var exited = false
    @State private var state: Loaded = .reading

    enum Loaded: Equatable { case reading, read(SecurityDetail, viaHelper: Bool), unreadable }

    var body: some View {
        Card(title: "Hardened process (kernel)", systemImage: "shield.lefthalf.filled", trailing: trailing) {
            switch state {
            case .reading:
                Text(exited ? "The process exited before this was read." : "Reading…").foregroundStyle(.secondary)
            case .unreadable:
                Text(exited ? "The process exited before this was read."
                     : store.helperState.isRunning ? "Not readable: the helper couldn't read it either."
                     : "Not readable (another user's process; the privileged helper can read it).")
                    .foregroundStyle(.secondary)
            case .read(let d, let viaHelper):
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(SecurityConfig.all, id: \.0.rawValue) { flag, name, about in
                        let on = d.config.contains(flag)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: on ? "checkmark.circle.fill" : "minus.circle")
                                .foregroundStyle(on ? Color.green : Color.secondary)
                            Text(name).foregroundStyle(on ? .primary : .secondary)
                            Text(on ? "on" : "off").foregroundStyle(on ? .primary : .secondary)
                            Spacer(minLength: 0)
                        }
                        .help(about)
                    }
                    if d.kernel != nil || d.ipcPolicy != nil {
                        Divider()
                        FactGrid(rows: Self.kernelRows(d))
                    }
                    Text("From the kernel (os_security_config_get_for_proc; TASK_SECURITY_CONFIG_INFO and TASK_IPC_SPACE_POLICY_INFO, "
                         + "decoded from what each hardened-process entitlement sets)\(viaHelper ? ", read as root through the privileged helper" : "").")
                        .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task(id: "\(proc.key)|\(exited)|\(store.helperState.isRunning)") { await load() }
    }

    /// The kernel records' fields beyond the five public flags.
    static func kernelRows(_ d: SecurityDetail) -> [(String, KVValue)] {
        let onOff = { (b: Bool) in b ? "on" : "off" }
        var rows: [(String, KVValue)] = []
        if let k = d.kernel {
            rows.append(("Enhanced security", .text(k.enhancedSecurityVersion == 0 ? "off"
                                                    : "version \(k.enhancedSecurityVersion)")))
            let pr: String = switch k.platformRestrictions {
            case 0: "none"
            case 2: "level 2 (the platform-restrictions entitlement)"
            case 3: "level 3 (Apple's default for its own binaries)"
            default: "level \(k.platformRestrictions)"
            }
            rows.append(("Platform restrictions", .text(pr)))
            rows.append(("IPC containment", .text(onOff(k.ipcContainment))))
            rows.append(("Copy-on-write defeatured", .text(onOff(k.vmCopyOnWriteDefeatured))))
            rows.append(("No tagged receive (MTE)", .text(onOff(k.noTaggedReceive))))
            var raw = String(format: "0x%05x", k.raw)
            if k.unexplained != 0 { raw += String(format: " (unexplained bits 0x%x)", k.unexplained) }
            rows.append(("Kernel config", .text(raw)))
        }
        if let p = d.ipcPolicy {
            var s = String(format: "0x%03x: level %u", p.raw, p.level)
            if p.withoutTPRO { s += "; bit 0x80, seen only on Apple arm64e processes running without TPRO" }
            rows.append(("IPC space policy", .text(s)))
        }
        return rows
    }

    private var trailing: String? {
        guard case .read(let d, _) = state else { return nil }
        return "\(SecurityConfig.all.filter { d.config.contains($0.0) }.count) of \(SecurityConfig.all.count)"
    }

    private func load() async {
        guard !exited else { if state == .reading { state = .unreadable }; return }
        let pid = proc.pid, helper = store.helperState.isRunning
        state = await Task.detached { () -> Loaded in
            // Locally first; the helper too when the task records couldn't be read (another user's process).
            let local = SecurityDetail.read(pid)
            if let local, local.kernel != nil { return .read(local, viaHelper: false) }
            if helper, let d = HelperClient.shared.securityDetail(pid) { return .read(d, viaHelper: true) }
            return local.map { .read($0, viaHelper: false) } ?? .unreadable
        }.value
    }
}
