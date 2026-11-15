import Darwin
import Foundation

/// `lsof -n -P -p <pid>` and `lsof -n -P -F pftdnPT` from libproc, in lsof's own layouts so LsofParser,
/// PeerIndex.parse and the Raw switch work unchanged. libproc needs root for other users' processes, not a task
/// port, so it is used whenever the helper runs, SIP or not.
///
/// Per descriptor: PROC_PIDLISTFDS, then the type's PROC_PIDFD*INFO call. Also lsof's non-descriptor rows: the
/// working directory (cwd), a chroot (rtd), mapped files (txt, from the region walk) and descriptors held as
/// fileports (fp.). Kernel addresses (socket, pipe) are the permuted ones libproc returns, the same values lsof
/// prints, so pipe and socket ends pair across processes as before.
///
/// Checked against lsof on every process of a macOS 27.2 VM (707 processes, 12,894 rows): whole rows identical
/// except for files opened or closed between the two runs, and lsof's "twd" rows (a thread's own working
/// directory, per-thread state outside the descriptor table; 3 on the machine), which aren't produced.
enum NativeLsof {
    struct Item {
        var fd: String
        var mode = ""
        var type = ""
        var device = ""
        /// Hex kernel address: lsof's -F `d` field (only sockets and pipes have one).
        var address = ""
        var sizeOff = ""
        var node = ""
        var name = ""
        var proto = ""
        var tcpState = ""
    }

    static func available() -> Bool { getuid() == 0 }

    /// lsof's table for one process, or nil when not root.
    static func table(_ pid: pid_t) -> String? {
        guard available(), let items = items(pid) else { return nil }
        let cmd = command(pid), user = userName(pid)
        let rows = items.map { [cmd, String(pid), user, $0.fd + $0.mode, $0.type, $0.device, $0.sizeOff, $0.node] }
        let titles = ["COMMAND", "PID", "USER", "FD", "TYPE", "DEVICE", "SIZE/OFF", "NODE"]
        let widths = titles.indices.map { i in max(titles[i].count, rows.map { $0[i].count }.max() ?? 0) }
        // COMMAND and USER left-aligned, the rest right-aligned under their titles (LsofParser places blank
        // fields by the titles' right edges).
        func line(_ cells: [String], _ name: String) -> String {
            cells.indices.map { i in
                let c = cells[i], pad = String(repeating: " ", count: widths[i] - c.count)
                return i == 0 || i == 2 ? c + pad : pad + c
            }.joined(separator: " ") + " " + name
        }
        var out = line(titles, "NAME") + "\n"
        // The table puts a TCP (or vsock) state after the endpoints; -F gives it its own field.
        for (r, it) in zip(rows, items) { out += line(r, it.tcpState.isEmpty ? it.name : "\(it.name) (\(it.tcpState))") + "\n" }
        return out
    }

    /// lsof -F pftdnPT for every process.
    static func fields() -> String? {
        guard available() else { return nil }
        var out = ""
        for pid in NativeMach.allPids() where pid > 0 {
            guard let items = items(pid) else { continue }
            out += "p\(pid)\n"
            for it in items {
                out += "f\(it.fd)\n"
                if !it.type.isEmpty { out += "t\(it.type)\n" }
                if !it.address.isEmpty { out += "d\(it.address)\n" }
                if !it.proto.isEmpty { out += "P\(it.proto)\n" }
                out += "n\(it.name)\n"
                if !it.tcpState.isEmpty { out += "TST=\(it.tcpState)\n" }
            }
        }
        return out
    }

    // MARK: Items

    static func items(_ pid: pid_t) -> [Item]? {
        var out: [Item] = []
        var vp = proc_vnodepathinfo()
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vp, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 {
            if var i = vnodeItem(vp.pvi_cdir, offset: nil) { i.fd = "cwd"; out.append(i) }
            if path(vp.pvi_rdir).count > 0, var i = vnodeItem(vp.pvi_rdir, offset: nil) { i.fd = "rtd"; out.append(i) }
        } else if !Native.isAlive(pid) {
            return nil
        }
        out += mappedFiles(pid)

        let need = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        if need > 0 {
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(need) / MemoryLayout<proc_fdinfo>.size + 16)
            let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
            for f in fds.prefix(max(0, Int(got)) / MemoryLayout<proc_fdinfo>.size) {
                if let i = descriptor(pid, fd: f.proc_fd, type: f.proc_fdtype) { out.append(i) }
            }
        }
        out += fileports(pid)
        return out
    }

    private static func descriptor(_ pid: pid_t, fd: Int32, type: UInt32) -> Item? {
        var item: Item?
        switch Int32(type) {
        case PROX_FDTYPE_VNODE:
            var v = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, &v, Int32(MemoryLayout<vnode_fdinfowithpath>.size)) > 0 else { return nil }
            item = vnodeItem(v.pvip, offset: v.pfi.fi_offset)
            item?.mode = mode(v.pfi.fi_openflags)
        case PROX_FDTYPE_SOCKET:
            var s = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &s, Int32(MemoryLayout<socket_fdinfo>.size)) > 0 else { return nil }
            item = socketItem(s.psi)
            item?.mode = mode(s.pfi.fi_openflags)
        case PROX_FDTYPE_PIPE:
            var p = pipe_fdinfo()
            guard proc_pidfdinfo(pid, fd, PROC_PIDFDPIPEINFO, &p, Int32(MemoryLayout<pipe_fdinfo>.size)) > 0 else { return nil }
            item = pipeItem(p.pipeinfo)   // lsof shows no access mode for pipes
        case PROX_FDTYPE_KQUEUE:
            var k = kqueue_fdinfo()
            guard proc_pidfdinfo(pid, fd, PROC_PIDFDKQUEUEINFO, &k, Int32(MemoryLayout<kqueue_fdinfo>.size)) > 0 else { return nil }
            item = Item(fd: "", type: "KQUEUE", name: "count=\(k.kqueueinfo.kq_stat.vst_size), state=\(hex(UInt64(k.kqueueinfo.kq_state)))")
            item?.mode = mode(k.pfi.fi_openflags)
        case PROX_FDTYPE_PSHM:
            var m = pshm_fdinfo()
            guard proc_pidfdinfo(pid, fd, PROC_PIDFDPSHMINFO, &m, Int32(MemoryLayout<pshm_fdinfo>.size)) > 0 else { return nil }
            item = Item(fd: "", type: "PSXSHM", sizeOff: String(m.pshminfo.pshm_stat.vst_size), name: cString(m.pshminfo.pshm_name))
            item?.mode = mode(m.pfi.fi_openflags)
        case PROX_FDTYPE_PSEM:
            var m = psem_fdinfo()
            guard proc_pidfdinfo(pid, fd, PROC_PIDFDPSEMINFO, &m, Int32(MemoryLayout<psem_fdinfo>.size)) > 0 else { return nil }
            item = Item(fd: "", type: "PSXSEM", name: cString(m.pseminfo.psem_name))
            item?.mode = mode(m.pfi.fi_openflags)
        case PROX_FDTYPE_FSEVENTS: item = Item(fd: "", type: "FSEVENT")
        case PROX_FDTYPE_NETPOLICY: item = Item(fd: "", type: "NPOLICY")
        case PROX_FDTYPE_NEXUS: item = Item(fd: "", type: "NEXUS")
        case PROX_FDTYPE_CHANNEL:
            var ch = channel_fdinfo()
            guard proc_pidfdinfo(pid, fd, PROC_PIDFDCHANNELINFO, &ch, Int32(MemoryLayout<channel_fdinfo>.size)) > 0 else { return nil }
            item = channelItem(ch.channelinfo)
        case PROX_FDTYPE_ATALK: item = Item(fd: "", type: "ATALK")
        default: item = Item(fd: "", name: "unknown file type: \(type)")
        }
        item?.fd = String(fd)
        return item
    }

    /// Short descriptions of some of a process's descriptors, for a syscall trace's fd arguments: the path of a
    /// file, "TCP 10.0.0.2:52311->1.1.1.1:443 ESTABLISHED" for a socket, "pipe", "kqueue". Missing: closed fds.
    static func describe(_ pid: pid_t, fds wanted: Set<Int32>) -> [Int32: String] {
        let need = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard need > 0, !wanted.isEmpty else { return [:] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(need) / MemoryLayout<proc_fdinfo>.size + 16)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
        var out: [Int32: String] = [:]
        for f in fds.prefix(max(0, Int(got)) / MemoryLayout<proc_fdinfo>.size) where wanted.contains(f.proc_fd) {
            guard let i = descriptor(pid, fd: f.proc_fd, type: f.proc_fdtype) else { continue }
            switch i.type {
            case "IPv4", "IPv6": out[f.proc_fd] = [i.proto, i.name, i.tcpState].filter { !$0.isEmpty }.joined(separator: " ")
            case "unix": out[f.proc_fd] = "unix " + i.name
            case "PIPE": out[f.proc_fd] = "pipe"
            case "KQUEUE": out[f.proc_fd] = "kqueue"
            case "systm", "ndrv", "rte", "vsockp", "sock": out[f.proc_fd] = ([i.type] + (i.name.isEmpty ? [] : [i.name])).joined(separator: " ")
            default: out[f.proc_fd] = i.name.isEmpty ? i.type : i.name
            }
        }
        return out
    }

    /// Descriptors a process holds as fileports (launchd keeps sockets for its jobs this way): "fp." rows.
    private static func fileports(_ pid: pid_t) -> [Item] {
        let need = proc_pidinfo(pid, PROC_PIDLISTFILEPORTS, 0, nil, 0)
        guard need > 0 else { return [] }
        var ports = [proc_fileportinfo](repeating: proc_fileportinfo(), count: Int(need) / MemoryLayout<proc_fileportinfo>.size + 16)
        let got = proc_pidinfo(pid, PROC_PIDLISTFILEPORTS, 0, &ports, Int32(ports.count * MemoryLayout<proc_fileportinfo>.size))
        var out: [Item] = []
        for p in ports.prefix(max(0, Int(got)) / MemoryLayout<proc_fileportinfo>.size) {
            var item: Item
            switch Int32(p.proc_fdtype) {
            case PROX_FDTYPE_VNODE:
                var v = vnode_fdinfowithpath()
                guard proc_pidfileportinfo(pid, p.proc_fileport, PROC_PIDFILEPORTVNODEPATHINFO, &v, Int32(MemoryLayout<vnode_fdinfowithpath>.size)) > 0,
                      let i = vnodeItem(v.pvip, offset: v.pfi.fi_offset) else { continue }
                item = i; item.mode = mode(v.pfi.fi_openflags)
            case PROX_FDTYPE_SOCKET:
                var s = socket_fdinfo()
                guard proc_pidfileportinfo(pid, p.proc_fileport, PROC_PIDFILEPORTSOCKETINFO, &s, Int32(MemoryLayout<socket_fdinfo>.size)) > 0 else { continue }
                item = socketItem(s.psi); item.mode = mode(s.pfi.fi_openflags)
            case PROX_FDTYPE_PIPE:
                var pi = pipe_fdinfo()
                guard proc_pidfileportinfo(pid, p.proc_fileport, PROC_PIDFILEPORTPIPEINFO, &pi, Int32(MemoryLayout<pipe_fdinfo>.size)) > 0 else { continue }
                item = pipeItem(pi.pipeinfo)
            default:
                // lsof prints the fileport's own number here.
                item = Item(fd: "", name: "unknown file type: \(p.proc_fileport)")
            }
            item.fd = "fp."
            item.name += " (fileport=0x\(String(p.proc_fileport, radix: 16)))"
            out.append(item)
        }
        return out
    }

    /// PROC_PIDREGIONPATHINFO2 (xnu's proc_info_private.h): like PROC_PIDREGIONPATHINFO, but steps straight to
    /// the next file-backed region instead of through every region.
    private static let regionPathInfo2: Int32 = 22

    /// Each file mapped into the process, once, in address order (lsof's "txt").
    private static func mappedFiles(_ pid: pid_t) -> [Item] {
        var out: [Item] = []
        var seen: Set<[UInt64]> = []
        var addr: UInt64 = 0
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        var flavor = regionPathInfo2
        while true {
            var r = proc_regionwithpathinfo()
            var got = proc_pidinfo(pid, flavor, addr, &r, size)
            if got != size && flavor == regionPathInfo2 && addr == 0 && errno == EINVAL {
                flavor = PROC_PIDREGIONPATHINFO   // older kernel without the private flavor
                got = proc_pidinfo(pid, flavor, addr, &r, size)
            }
            guard got == size else { break }
            let next = r.prp_prinfo.pri_address + r.prp_prinfo.pri_size
            guard next > addr else { break }
            addr = next
            let st = r.prp_vip.vip_vi.vi_stat
            guard path(r.prp_vip).count > 0, seen.insert([UInt64(st.vst_dev), st.vst_ino]).inserted,
                  var i = vnodeItem(r.prp_vip, offset: nil) else { continue }
            i.fd = "txt"
            out.append(i)
        }
        return out
    }

    // MARK: By type

    private static func vnodeItem(_ v: vnode_info_path, offset: Int64?) -> Item? {
        let p = path(v)
        let st = v.vip_vi.vi_stat
        var i = Item(fd: "", name: p)
        let fmt = st.vst_mode & S_IFMT
        switch fmt {
        case S_IFREG: i.type = "REG"
        case S_IFDIR: i.type = "DIR"
        case S_IFCHR: i.type = "CHR"
        case S_IFBLK: i.type = "BLK"
        case S_IFIFO: i.type = "FIFO"
        case S_IFLNK: i.type = "LINK"
        case S_IFSOCK: i.type = "sock"
        default: i.type = "VREG"
        }
        let dev = (fmt == S_IFCHR || fmt == S_IFBLK) ? UInt32(truncatingIfNeeded: st.vst_rdev) : UInt32(truncatingIfNeeded: st.vst_dev)
        i.device = "\(dev >> 24),\(dev & 0xFFFFFF)"
        // lsof shows a regular file's or directory's size, a device's offset.
        i.sizeOff = (fmt == S_IFCHR || fmt == S_IFBLK || fmt == S_IFIFO) ? "0t\(offset ?? 0)" : String(st.vst_size)
        i.node = String(st.vst_ino)
        return i
    }

    private static func socketItem(_ s: socket_info) -> Item {
        var i = Item(fd: "", address: hex(s.soi_pcb), sizeOff: "0t0")
        i.device = i.address
        switch s.soi_family {
        case AF_INET, AF_INET6:
            let tcp = Int(s.soi_kind) == SOCKINFO_TCP
            let ini = tcp ? s.soi_proto.pri_tcp.tcpsi_ini : s.soi_proto.pri_in
            i.type = ini.insi_vflag & UInt8(INI_IPV6) != 0 ? "IPv6" : "IPv4"
            i.proto = tcp ? "TCP" : protoName(s.soi_protocol)
            i.node = i.proto
            let v6 = i.type == "IPv6"
            let local = endpoint(v4: ini.insi_laddr.ina_46.i46a_addr4, v6: ini.insi_laddr.ina_6, port: ini.insi_lport, isV6: v6)
            let remote = endpoint(v4: ini.insi_faddr.ina_46.i46a_addr4, v6: ini.insi_faddr.ina_6, port: ini.insi_fport, isV6: v6)
            i.name = remote.hasPrefix("*") ? local : "\(local)->\(remote)"
            if tcp {
                i.tcpState = tcpState(s.soi_proto.pri_tcp.tcpsi_state)
                // lsof identifies a TCP socket by its TCP control block, other sockets by their protocol control block.
                i.address = hex(s.soi_proto.pri_tcp.tcpsi_tp)
                i.device = i.address
            }
        case AF_UNIX:
            i.type = "unix"
            let un = s.soi_proto.pri_un
            let p = withUnsafeBytes(of: un.unsi_addr.ua_sun.sun_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            i.name = !p.isEmpty ? p : (un.unsi_conn_pcb != 0 ? "->" + hex(un.unsi_conn_pcb) : "->(none)")
        case AF_SYSTEM:
            i.type = "systm"
            if Int(s.soi_kind) == SOCKINFO_KERN_CTL {
                let c = s.soi_proto.pri_kern_ctl
                i.name = "[ctl \(cString(c.kcsi_name)) id \(c.kcsi_id) unit \(c.kcsi_unit)]"
            } else if Int(s.soi_kind) == SOCKINFO_KERN_EVENT {
                let e = s.soi_proto.pri_kern_event
                i.name = "[event \(String(e.kesi_vendor_code_filter, radix: 16)):\(String(e.kesi_class_filter, radix: 16)):\(String(e.kesi_subclass_filter, radix: 16))]"
            }
        case AF_NDRV:
            i.type = "ndrv"
            let n = s.soi_proto.pri_ndrv
            i.name = "-> \(cString(n.ndrvsi_if_name))\(n.ndrvsi_if_unit)"
        case AF_ROUTE: i.type = "rte"; i.device = ""; i.address = ""
        case AF_VSOCK:
            i.type = "vsockp"
            i.device = ""; i.address = ""
            let v = s.soi_proto.pri_vsock
            func ep(_ cid: UInt32, _ port: UInt32) -> String { cid == UInt32.max && port == UInt32.max ? "*" : "\(cid == UInt32.max ? "*" : String(cid)):\(port)" }
            let local = "\(v.local_cid == UInt32.max ? "*" : String(v.local_cid)):\(v.local_port)"
            i.name = v.remote_cid == UInt32.max ? local : "\(local)->\(ep(v.remote_cid, v.remote_port))"
            i.tcpState = s.soi_state & 0x0002 != 0 /* SS_ISCONNECTED */ ? "ESTABLISHED" : s.soi_options & Int16(SO_ACCEPTCONN) != 0 ? "LISTEN" : ""
        default:
            i.type = "sock"
        }
        return i
    }

    /// Skywalk channel: lsof puts the channel type where a device goes and "instance[port] flags" as the name.
    /// "upipe" and "flowsw" (with "user-packet-pool") measured; the other names follow the SDK's constants.
    private static func channelItem(_ c: proc_channel_info) -> Item {
        let type = ["upipe", "kpipe", "netif", "flowsw"][safe: Int(c.chi_type)] ?? String(c.chi_type)
        let uuid = withUnsafeBytes(of: c.chi_instance) { UUID(uuid: $0.load(as: uuid_t.self)).uuidString }
        let flags: [(UInt32, String)] = [(0x1, "monitor-tx"), (0x2, "monitor-rx"), (0x4, "monitor-no-copy"), (0x10, "exclusive"),
                                         (0x20, "user-packet-pool"), (0x80, "low-latency")]
        let names = flags.filter { c.chi_flags & $0.0 != 0 }.map(\.1)
        return Item(fd: "", type: "CHAN", device: type, name: "\(uuid)[\(c.chi_port)]" + (names.isEmpty ? "" : " " + names.joined(separator: " ")))
    }

    private static func pipeItem(_ p: pipe_info) -> Item {
        let a = hex(p.pipe_handle)
        return Item(fd: "", type: "PIPE", device: a, address: a, sizeOff: String(p.pipe_stat.vst_blksize),
                    name: p.pipe_peerhandle != 0 ? "->" + hex(p.pipe_peerhandle) : "")
    }

    // MARK: Formatting

    /// "*:22", "127.0.0.1:631", "[::1]:5900"; "*" for an unbound address or port.
    private static func endpoint(v4: in_addr, v6 a6: in6_addr, port: Int32, isV6 v6: Bool) -> String {
        let p = UInt16(bigEndian: UInt16(truncatingIfNeeded: port))
        var host: String
        if v6 {
            var addr = a6
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &addr, &buf, socklen_t(buf.count))
            host = String(cString: buf)
            host = host == "::" ? "*" : "[\(host)]"
        } else {
            var addr = v4
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count))
            host = String(cString: buf)
            if host == "0.0.0.0" { host = "*" }
        }
        return "\(host):\(p == 0 ? "*" : String(p))"
    }

    /// lsof's names for the IP protocols it shows; others as numbers.
    private static func protoName(_ p: Int32) -> String {
        [IPPROTO_UDP: "UDP", IPPROTO_ICMP: "ICMP", IPPROTO_ICMPV6: "ICMPV6", IPPROTO_RAW: "RAW", IPPROTO_TCP: "TCP"][p] ?? String(p)
    }

    private static func tcpState(_ s: Int32) -> String {
        ["CLOSED", "LISTEN", "SYN_SENT", "SYN_RECEIVED", "ESTABLISHED", "CLOSE_WAIT", "FIN_WAIT_1", "CLOSING",
         "LAST_ACK", "FIN_WAIT_2", "TIME_WAIT"][safe: Int(s)] ?? "UNKNOWN_\(s)"
    }

    private static func mode(_ flags: UInt32) -> String {
        let r = flags & UInt32(FREAD) != 0, w = flags & UInt32(FWRITE) != 0
        return r && w ? "u" : r ? "r" : w ? "w" : ""
    }

    /// lsof's "%#llx": no zero padding, and plain "0" for zero.
    private static func hex(_ v: UInt64) -> String { v == 0 ? "0" : "0x" + String(v, radix: 16) }

    private static func path(_ v: vnode_info_path) -> String {
        withUnsafeBytes(of: v.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    private static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    /// lsof's COMMAND column: spaces and other unprintable bytes escaped as \xNN, cut to 9 characters, and an escape
    /// the cut splits dropped ("Siri AI" → "Siri\x20A", "Keychain Circle Notification" → "Keychain").
    private static func command(_ pid: pid_t) -> String {
        var n = [CChar](repeating: 0, count: 256)
        proc_name(pid, &n, UInt32(n.count))
        var out = "", len = 0
        for b in String(cString: n).utf8 {
            let piece = b > 0x20 && b < 0x7F ? String(UnicodeScalar(b)) : String(format: "\\x%02x", b)
            guard len + piece.count <= 9 else { break }
            out += piece; len += piece.count
        }
        return out
    }

    private static func userName(_ pid: pid_t) -> String {
        guard let p = Native.process(pid) else { return "?" }
        return getpwuid(p.uid).map { String(cString: $0.pointee.pw_name) } ?? String(p.uid)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
