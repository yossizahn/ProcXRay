import Foundation

/// Who is on the other end of a process's pipes and sockets, and who else has its files open, from one
/// `lsof -F` run over every process.
///
/// - Pipes and unix sockets: lsof prints each endpoint's kernel address (DEVICE) and its peer's (`->0x…`
///   in NAME). The peer is whoever holds the peer address, plus whoever names this address as theirs.
/// - TCP: both ends on this machine show the same address pair, reversed. A listener's clients are the
///   connections whose remote end is the listening address (any local host for a wildcard listener).
/// - Files: every other process with the same path open (mapped images left out: every process maps libc).
struct PeerIndex: Sendable {
    struct End: Hashable, Sendable {
        let pid: Int32
        let fd: String
    }
    enum Scope: Sendable { case allUsers, ownUser }

    /// Pipe / unix socket kernel address → descriptors holding it.
    var byAddress: [String: [End]] = [:]
    /// Peer address named in a descriptor's NAME (`->0x…`) → descriptors naming it.
    var namingAddress: [String: [End]] = [:]
    /// TCP remote endpoint ("127.0.0.1:6379") → (descriptor, its local endpoint).
    var tcpByRemote: [String: [(end: End, local: String)]] = [:]
    /// Hosts that appear on the local side of some TCP socket: this machine's own addresses.
    var localHosts: Set<String> = ["127.0.0.1", "[::1]", "localhost"]
    /// Path → pids with it open as a file or directory (not as a mapped image).
    var files: [String: Set<Int32>] = [:]
    var processCount = 0
    var scope = Scope.ownUser
    var at = Date()

    // MARK: lookups

    /// The other end(s) of a pipe or unix socket, excluding the descriptor itself.
    func peers(address: String, peerAddress: String?, pid: Int32, fd: String) -> [End] {
        var out: [End] = []
        if let pa = peerAddress { out += byAddress[pa] ?? [] }
        out += namingAddress[address] ?? []
        let me = End(pid: pid, fd: fd)
        var seen: Set<End> = []
        return out.filter { $0 != me && seen.insert($0).inserted }
    }

    /// The other end of a connected TCP socket.
    func tcpPeers(local: String, remote: String, pid: Int32, fd: String) -> [End] {
        let me = End(pid: pid, fd: fd)
        return (tcpByRemote[local] ?? []).filter { $0.local == remote && $0.end != me }.map(\.end)
    }

    /// Connections on this machine to a listening socket.
    func tcpClients(listening local: String) -> [End] {
        guard let (host, port) = Self.split(local) else { return [] }
        if !["*", "0.0.0.0", "[::]"].contains(host) { return (tcpByRemote[local] ?? []).map(\.end) }
        return tcpByRemote.flatMap { key, ends -> [End] in
            guard let (h, p) = Self.split(key), p == port, localHosts.contains(h) else { return [] }
            return ends.map(\.end)
        }
    }

    /// Other processes with this path open.
    func alsoOpen(_ path: String, except pid: Int32) -> [Int32] {
        (files[path] ?? []).filter { $0 != pid }.sorted()
    }

    /// "127.0.0.1:6379" → ("127.0.0.1", "6379"); "[::1]:80" → ("[::1]", "80").
    static func split(_ endpoint: String) -> (String, String)? {
        guard let colon = endpoint.lastIndex(of: ":") else { return nil }
        return (String(endpoint[..<colon]), String(endpoint[endpoint.index(after: colon)...]))
    }

    // MARK: parsing

    /// Parses `lsof -F pftdnPT`. Lines lsof didn't write as fields (warnings, a truncation note) are skipped.
    static func parse(_ text: String) -> PeerIndex {
        var ix = PeerIndex()
        var pid: Int32 = 0
        var pids: Set<Int32> = []
        var fd = "", type = "", device = "", name = "", proto = ""
        var open = false

        func commit() {
            defer { open = false; fd = ""; type = ""; device = ""; name = ""; proto = "" }
            guard open, pid > 0 else { return }
            let end = End(pid: pid, fd: fd)
            switch type {
            case "PIPE", "unix":
                guard device.hasPrefix("0x") else { return }
                ix.byAddress[device, default: []].append(end)
                if name.hasPrefix("->0x") { ix.namingAddress[String(name.dropFirst(2)), default: []].append(end) }
            case "IPv4", "IPv6":
                guard proto == "TCP" else { return }
                let parts = name.components(separatedBy: "->")
                if let (h, _) = split(parts[0]), !["*", "0.0.0.0", "[::]"].contains(h) { ix.localHosts.insert(h) }
                if parts.count == 2 { ix.tcpByRemote[parts[1], default: []].append((end, parts[0])) }
            case "REG", "DIR":
                guard fd != "txt", !name.isEmpty else { return }
                ix.files[name, default: []].insert(pid)
            default: break
            }
        }

        text.enumerateLines { line, _ in
            guard let c = line.first else { return }
            let v = String(line.dropFirst())
            switch c {
            case "p":
                commit()
                pid = Int32(v) ?? 0
                if pid > 0 { pids.insert(pid) }
            case "f":
                commit()
                fd = v
                open = true
            case "t": type = v
            case "d": device = v
            case "n": name = v
            case "P": proto = v
            default: break   // T (TCP state), warnings
            }
        }
        commit()
        ix.processCount = pids.count
        return ix
    }
}

/// Builds the index on demand, through the helper (every user's processes) when it's running and the user
/// is an admin, otherwise as the user. Kept for a few seconds, so following a peer to its own Connections
/// tab doesn't run lsof over everything again.
enum PeerIndexLoader {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (index: PeerIndex, viaHelper: Bool)?
    static let maxAge: TimeInterval = 5

    static func load(viaHelper: Bool, fresh: Bool = false) -> PeerIndex {
        lock.lock()
        if !fresh, let c = cached, c.viaHelper == viaHelper, -c.index.at.timeIntervalSinceNow < maxAge {
            lock.unlock()
            return c.index
        }
        lock.unlock()
        var ix: PeerIndex?
        if viaHelper, let out = HelperClient.shared.run(.lsofAll), !out.hasPrefix("helper:") {
            ix = PeerIndex.parse(out)
            ix?.scope = .allUsers
        }
        if ix == nil, let (path, args) = HelperTool.lsofAll.argv(pid: 0) {
            ix = PeerIndex.parse(Shell.run(path, args, mergeStderr: false, timeout: HelperTool.lsofAll.timeout))
            ix?.scope = .ownUser
        }
        let result = ix ?? PeerIndex()
        lock.lock()
        cached = (result, viaHelper)
        lock.unlock()
        return result
    }
}
