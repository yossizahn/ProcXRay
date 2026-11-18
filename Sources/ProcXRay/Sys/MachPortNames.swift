import Foundation

/// Which process each port name in one process's port space leads to: for each send right it holds, the process
/// holding the receive right. From a fresh run of the helper's port listing (lsmp, or the native walk with SIP
/// off: MachSnapshot), then each peer's ports (MachPortDetail). Names the destinations of mach_msg2_trap sends in
/// a syscall trace, whose fourth argument carries the destination port's name.
///
/// Rights to kernel objects (task, thread, IOKit connections) and to the process's own ports pair with no other
/// process and stay unnamed, as do ports made after the listing.
enum MachPortNames {
    typealias Names = (ports: [UInt32: Int32], names: [Int32: String])

    /// Through the helper.
    static func resolve(pid: Int32) -> Result<Names, MachLoader.Failure> {
        HelperClient.shared.machPorts().map { snapshot in
            names(pid: pid, snapshot: snapshot) { peer in
                if case .success(let d) = HelperClient.shared.machPortDetail(pid: pid, peer: peer, timeout: 10) { return d.ports }
                return []
            }
        }
    }

    /// In this process, as root (`--trace … --activity`).
    static func resolveHere(pid: Int32) -> Result<Names, MachLoader.Failure> {
        MachPortCache.run(cancel: nil).map { snapshot in
            let ports = MachPortCache.last()?.ports ?? [:]
            return names(pid: pid, snapshot: snapshot) { ports[PortPair(pid, $0)] ?? [] }
        }
    }

    private static func names(pid: Int32, snapshot: MachSnapshot, detail: (Int32) -> [MachPortDetail]) -> Names {
        var ports: [UInt32: Int32] = [:]
        var names: [Int32: String] = [:]
        for peer in snapshot.peers(of: pid) where peer.sendsTo > 0 {
            for p in detail(peer.pid) where p.sender == pid {
                if let name = number(p.senderName) { ports[name] = p.receiver }
            }
            if let path = Native.path(peer.pid) { names[peer.pid] = (path as NSString).lastPathComponent }
        }
        return (ports, names)
    }

    /// lsmp's "0x00001a03".
    static func number(_ s: String) -> UInt32? {
        s.hasPrefix("0x") ? UInt32(s.dropFirst(2), radix: 16) : nil
    }
}
