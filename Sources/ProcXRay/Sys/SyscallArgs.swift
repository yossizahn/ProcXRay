import Darwin
import Foundation

/// Names for flag and operation arguments of syscalls and Mach traps, strace-style.
///
/// Values come from the SDK through Swift's imports wherever Swift imports them, so the compiler checks the
/// names. The rest are literals:
///   - ioctl requests (function-like macros Swift doesn't import): printed from the SDK headers by a C program.
///   - Private ones (mach_msg2 options, ulock, workqueue, csops, proc_info calls): from Apple's published xnu
///     source (osfmk/mach/message.h, bsd/sys/ulock.h, bsd/pthread/workqueue_syscalls.h, bsd/sys/codesign.h,
///     bsd/sys/proc_info_private.h).
enum SyscallFlags {
    typealias Table = [(UInt64, String)]

    private static func u<T: BinaryInteger>(_ v: T) -> UInt64 { UInt64(truncatingIfNeeded: v) }

    /// Bits by name, then whatever is left in hex. `zero` names the empty set.
    static func bits(_ v: UInt64, _ table: Table, zero: String = "0") -> String {
        guard v != 0 else { return zero }
        var rest = v, parts: [String] = []
        for (bit, name) in table where bit != 0 && rest & bit == bit { parts.append(name); rest &= ~bit }
        if rest != 0 { parts.append("0x" + String(rest, radix: 16)) }
        return parts.joined(separator: "|")
    }

    /// One value by name, else the number.
    static func one(_ v: UInt64, _ table: Table) -> String {
        table.first { $0.0 == v }?.1 ?? "\(Int64(bitPattern: v))"
    }

    // MARK: memory

    static let prot: Table = [(u(PROT_READ), "PROT_READ"), (u(PROT_WRITE), "PROT_WRITE"), (u(PROT_EXEC), "PROT_EXEC")]
    static let mapFlags: Table = [
        (u(MAP_SHARED), "MAP_SHARED"), (u(MAP_PRIVATE), "MAP_PRIVATE"), (u(MAP_FIXED), "MAP_FIXED"), (u(MAP_ANON), "MAP_ANON"),
        (u(MAP_NORESERVE), "MAP_NORESERVE"), (u(MAP_JIT), "MAP_JIT"), (u(MAP_NOCACHE), "MAP_NOCACHE"),
        (u(MAP_RESILIENT_CODESIGN), "MAP_RESILIENT_CODESIGN"), (u(MAP_RESILIENT_MEDIA), "MAP_RESILIENT_MEDIA"),
        (u(MAP_32BIT), "MAP_32BIT"), (u(MAP_TRANSLATED_ALLOW_EXECUTE), "MAP_TRANSLATED_ALLOW_EXECUTE"), (u(MAP_UNIX03), "MAP_UNIX03"),
        (u(MAP_TPRO), "MAP_TPRO"), (u(MAP_HASSEMAPHORE), "MAP_HASSEMAPHORE"), (u(MAP_NOEXTEND), "MAP_NOEXTEND"), (u(MAP_RENAME), "MAP_RENAME"),
    ]
    static let madvise: Table = [
        (u(MADV_NORMAL), "MADV_NORMAL"), (u(MADV_RANDOM), "MADV_RANDOM"), (u(MADV_SEQUENTIAL), "MADV_SEQUENTIAL"),
        (u(MADV_WILLNEED), "MADV_WILLNEED"), (u(MADV_DONTNEED), "MADV_DONTNEED"), (u(MADV_FREE), "MADV_FREE"),
        (u(MADV_ZERO_WIRED_PAGES), "MADV_ZERO_WIRED_PAGES"), (u(MADV_FREE_REUSABLE), "MADV_FREE_REUSABLE"),
        (u(MADV_FREE_REUSE), "MADV_FREE_REUSE"), (u(MADV_CAN_REUSE), "MADV_CAN_REUSE"), (u(MADV_PAGEOUT), "MADV_PAGEOUT"),
        (u(MADV_ZERO), "MADV_ZERO"),
    ]
    static let msync: Table = [(u(MS_ASYNC), "MS_ASYNC"), (u(MS_SYNC), "MS_SYNC"), (u(MS_INVALIDATE), "MS_INVALIDATE"),
                               (u(MS_KILLPAGES), "MS_KILLPAGES"), (u(MS_DEACTIVATE), "MS_DEACTIVATE")]
    static let vmFlags: Table = [
        (u(VM_FLAGS_FIXED), "VM_FLAGS_FIXED"), (u(VM_FLAGS_ANYWHERE), "VM_FLAGS_ANYWHERE"), (u(VM_FLAGS_PURGABLE), "VM_FLAGS_PURGABLE"),
        (u(VM_FLAGS_4GB_CHUNK), "VM_FLAGS_4GB_CHUNK"), (u(VM_FLAGS_RANDOM_ADDR), "VM_FLAGS_RANDOM_ADDR"),
        (u(VM_FLAGS_NO_CACHE), "VM_FLAGS_NO_CACHE"), (u(VM_FLAGS_RESILIENT_CODESIGN), "VM_FLAGS_RESILIENT_CODESIGN"),
        (u(VM_FLAGS_RESILIENT_MEDIA), "VM_FLAGS_RESILIENT_MEDIA"), (u(VM_FLAGS_PERMANENT), "VM_FLAGS_PERMANENT"),
        (u(VM_FLAGS_TPRO), "VM_FLAGS_TPRO"), (u(VM_FLAGS_OVERWRITE), "VM_FLAGS_OVERWRITE"),
    ]
    /// VM_FLAGS_ANYWHERE is 1 and FIXED is 0, so FIXED shows only as the absence of ANYWHERE. The top byte is
    /// the region's tag (VM_MEMORY_*), shown as a number.
    static func vmFlagsText(_ v: UInt64) -> String {
        let tag = (v & u(VM_FLAGS_ALIAS_MASK)) >> 24
        var s = bits(v & ~u(VM_FLAGS_ALIAS_MASK), vmFlags, zero: "VM_FLAGS_FIXED")
        if tag != 0 { s += "|VM_MAKE_TAG(\(tag))" }
        return s
    }

    // MARK: files

    static let access: Table = [(u(R_OK), "R_OK"), (u(W_OK), "W_OK"), (u(X_OK), "X_OK")]
    static let atFlags: Table = [
        (u(AT_EACCESS), "AT_EACCESS"), (u(AT_SYMLINK_NOFOLLOW), "AT_SYMLINK_NOFOLLOW"), (u(AT_SYMLINK_FOLLOW), "AT_SYMLINK_FOLLOW"),
        (u(AT_REMOVEDIR), "AT_REMOVEDIR"), (u(AT_REALDEV), "AT_REALDEV"), (u(AT_FDONLY), "AT_FDONLY"),
        (u(AT_SYMLINK_NOFOLLOW_ANY), "AT_SYMLINK_NOFOLLOW_ANY"), (u(AT_RESOLVE_BENEATH), "AT_RESOLVE_BENEATH"),
    ]
    static let whence: Table = [(u(SEEK_SET), "SEEK_SET"), (u(SEEK_CUR), "SEEK_CUR"), (u(SEEK_END), "SEEK_END"),
                                (u(SEEK_HOLE), "SEEK_HOLE"), (u(SEEK_DATA), "SEEK_DATA")]
    static let flock: Table = [(u(LOCK_SH), "LOCK_SH"), (u(LOCK_EX), "LOCK_EX"), (u(LOCK_NB), "LOCK_NB"), (u(LOCK_UN), "LOCK_UN")]
    static let fcntlCmds: Table = [
        (u(F_DUPFD), "F_DUPFD"), (u(F_GETFD), "F_GETFD"), (u(F_SETFD), "F_SETFD"), (u(F_GETFL), "F_GETFL"), (u(F_SETFL), "F_SETFL"),
        (u(F_GETOWN), "F_GETOWN"), (u(F_SETOWN), "F_SETOWN"), (u(F_GETLK), "F_GETLK"), (u(F_SETLK), "F_SETLK"), (u(F_SETLKW), "F_SETLKW"),
        (u(F_FLUSH_DATA), "F_FLUSH_DATA"), (u(F_CHKCLEAN), "F_CHKCLEAN"), (u(F_PREALLOCATE), "F_PREALLOCATE"), (u(F_SETSIZE), "F_SETSIZE"),
        (u(F_RDADVISE), "F_RDADVISE"), (u(F_RDAHEAD), "F_RDAHEAD"), (u(F_NOCACHE), "F_NOCACHE"), (u(F_LOG2PHYS), "F_LOG2PHYS"),
        (u(F_GETPATH), "F_GETPATH"), (u(F_FULLFSYNC), "F_FULLFSYNC"), (u(F_PATHPKG_CHECK), "F_PATHPKG_CHECK"),
        (u(F_FREEZE_FS), "F_FREEZE_FS"), (u(F_THAW_FS), "F_THAW_FS"), (u(F_GLOBAL_NOCACHE), "F_GLOBAL_NOCACHE"),
        (u(F_ADDSIGS), "F_ADDSIGS"), (u(F_ADDFILESIGS), "F_ADDFILESIGS"), (u(F_NODIRECT), "F_NODIRECT"),
        (u(F_GETPROTECTIONCLASS), "F_GETPROTECTIONCLASS"), (u(F_SETPROTECTIONCLASS), "F_SETPROTECTIONCLASS"),
        (u(F_LOG2PHYS_EXT), "F_LOG2PHYS_EXT"), (u(F_GETLKPID), "F_GETLKPID"), (u(F_DUPFD_CLOEXEC), "F_DUPFD_CLOEXEC"),
        (u(F_SETBACKINGSTORE), "F_SETBACKINGSTORE"), (u(F_GETPATH_MTMINFO), "F_GETPATH_MTMINFO"), (u(F_GETCODEDIR), "F_GETCODEDIR"),
        (u(F_SETNOSIGPIPE), "F_SETNOSIGPIPE"), (u(F_GETNOSIGPIPE), "F_GETNOSIGPIPE"), (u(F_TRANSCODEKEY), "F_TRANSCODEKEY"),
        (u(F_SINGLE_WRITER), "F_SINGLE_WRITER"), (u(F_GETPROTECTIONLEVEL), "F_GETPROTECTIONLEVEL"), (u(F_FINDSIGS), "F_FINDSIGS"),
        (u(F_ADDFILESIGS_FOR_DYLD_SIM), "F_ADDFILESIGS_FOR_DYLD_SIM"), (u(F_BARRIERFSYNC), "F_BARRIERFSYNC"),
        (u(F_OFD_SETLK), "F_OFD_SETLK"), (u(F_OFD_SETLKW), "F_OFD_SETLKW"), (u(F_OFD_GETLK), "F_OFD_GETLK"),
        (u(F_ADDFILESIGS_RETURN), "F_ADDFILESIGS_RETURN"), (u(F_CHECK_LV), "F_CHECK_LV"), (u(F_PUNCHHOLE), "F_PUNCHHOLE"),
        (u(F_TRIM_ACTIVE_FILE), "F_TRIM_ACTIVE_FILE"), (u(F_SPECULATIVE_READ), "F_SPECULATIVE_READ"),
        (u(F_GETPATH_NOFIRMLINK), "F_GETPATH_NOFIRMLINK"), (u(F_ADDFILESIGS_INFO), "F_ADDFILESIGS_INFO"),
        (u(F_ADDFILESUPPL), "F_ADDFILESUPPL"), (u(F_GETSIGSINFO), "F_GETSIGSINFO"), (u(F_SETLEASE), "F_SETLEASE"),
        (u(F_GETLEASE), "F_GETLEASE"), (u(F_TRANSFEREXTENTS), "F_TRANSFEREXTENTS"), (u(F_ATTRIBUTION_TAG), "F_ATTRIBUTION_TAG"),
    ]

    /// fcntl's third argument means something different per command.
    static func fcntlArg(cmd: UInt64, _ v: UInt64) -> String? {
        switch Int32(truncatingIfNeeded: cmd) {
        case F_GETFD, F_GETFL, F_GETOWN, F_FULLFSYNC, F_BARRIERFSYNC, F_GETNOSIGPIPE, F_GETPROTECTIONCLASS, F_FREEZE_FS, F_THAW_FS:
            return nil   // ignored
        case F_SETFD: return bits(v, [(u(FD_CLOEXEC), "FD_CLOEXEC")])
        case F_SETFL: return SyscallFormat.openFlags(Int32(truncatingIfNeeded: v))
        case F_DUPFD, F_DUPFD_CLOEXEC, F_SETOWN, F_NOCACHE, F_RDAHEAD, F_SETNOSIGPIPE, F_SETPROTECTIONCLASS, F_GLOBAL_NOCACHE, F_NODIRECT, F_SINGLE_WRITER:
            return "\(Int64(bitPattern: v))"
        default: return v == 0 ? "NULL" : "0x" + String(v, radix: 16)   // a pointer to a struct
        }
    }

    /// Requests from the SDK headers (printed by a C program: these are function-like macros).
    static let ioctls: [UInt64: String] = [
        0x4004667f: "FIONREAD", 0x8004667e: "FIONBIO", 0x20006601: "FIOCLEX", 0x20006602: "FIONCLEX", 0x8004667d: "FIOASYNC",
        0x4004667a: "FIODTYPE", 0x40087468: "TIOCGWINSZ", 0x80087467: "TIOCSWINSZ", 0x40487413: "TIOCGETA", 0x80487414: "TIOCSETA",
        0x80487415: "TIOCSETAW", 0x80487416: "TIOCSETAF", 0x40047477: "TIOCGPGRP", 0x80047476: "TIOCSPGRP", 0x20007461: "TIOCSCTTY",
        0x40807453: "TIOCPTYGNAME", 0x20007454: "TIOCPTYGRANT", 0x20007452: "TIOCPTYUNLK", 0x80017472: "TIOCSTI", 0x2000740d: "TIOCEXCL",
        0x2000740e: "TIOCNXCL", 0x40047473: "TIOCOUTQ", 0x80047410: "TIOCFLUSH", 0x4004746a: "TIOCMGET", 0x8004746d: "TIOCMSET",
        0x2000745e: "TIOCDRAIN", 0x4004741a: "TIOCGETD", 0x8004741b: "TIOCSETD", 0x20007471: "TIOCNOTTY",
        0xc00c6924: "SIOCGIFCONF", 0xc0206911: "SIOCGIFFLAGS", 0xc0206933: "SIOCGIFMTU", 0xc0206921: "SIOCGIFADDR",
        0xc0206917: "SIOCGIFMETRIC", 0xc0206925: "SIOCGIFNETMASK", 0xc0206922: "SIOCGIFDSTADDR", 0xc0206923: "SIOCGIFBRDADDR",
        0x40046418: "DKIOCGETBLOCKSIZE", 0x40086419: "DKIOCGETBLOCKCOUNT", 0x80186416: "DKIOCSYNCHRONIZE", 0x8010641f: "DKIOCUNMAP",
        0x4004644c: "DKIOCGETFEATURES", 0x20006415: "DKIOCEJECT", 0x40086440: "DKIOCGETMAXBLOCKCOUNTREAD",
        0x40086441: "DKIOCGETMAXBLOCKCOUNTWRITE", 0x4004644d: "DKIOCGETPHYSICALBLOCKSIZE",
    ]
    /// A known name, else the request taken apart as the _IO macros build it: direction, group letter, number, size.
    static func ioctl(_ v: UInt64) -> String {
        let r = v & 0xffff_ffff
        if let n = ioctls[r] { return n }
        let dir: String
        switch r & 0xe000_0000 {
        case 0x2000_0000: dir = "_IO"
        case 0x4000_0000: dir = "_IOR"
        case 0x8000_0000: dir = "_IOW"
        case 0xc000_0000: dir = "_IOWR"
        default: return "0x" + String(r, radix: 16)
        }
        let group = UInt8((r >> 8) & 0xff), num = r & 0xff, len = (r >> 16) & 0x1fff
        let g = (0x20..<0x7f).contains(group) ? "'\(Character(UnicodeScalar(group)))'" : "\(group)"
        return dir == "_IO" ? "_IO(\(g), \(num))" : "\(dir)(\(g), \(num), \(len))"
    }

    // MARK: sockets

    static let domains: Table = [(u(AF_UNSPEC), "AF_UNSPEC"), (u(AF_UNIX), "AF_UNIX"), (u(AF_INET), "AF_INET"), (u(AF_INET6), "AF_INET6"),
                                 (u(AF_ROUTE), "AF_ROUTE"), (u(AF_SYSTEM), "AF_SYSTEM"), (u(AF_NDRV), "AF_NDRV"), (u(AF_LINK), "AF_LINK"),
                                 (u(AF_PPP), "AF_PPP")]
    static let sockTypes: Table = [(u(SOCK_STREAM), "SOCK_STREAM"), (u(SOCK_DGRAM), "SOCK_DGRAM"), (u(SOCK_RAW), "SOCK_RAW"),
                                   (u(SOCK_SEQPACKET), "SOCK_SEQPACKET"), (u(SOCK_RDM), "SOCK_RDM")]
    static let protocols: Table = [(u(IPPROTO_IP), "IPPROTO_IP"), (u(IPPROTO_TCP), "IPPROTO_TCP"), (u(IPPROTO_UDP), "IPPROTO_UDP"),
                                   (u(IPPROTO_IPV6), "IPPROTO_IPV6"), (u(IPPROTO_ICMP), "IPPROTO_ICMP"), (u(IPPROTO_ICMPV6), "IPPROTO_ICMPV6")]
    static let msgFlags: Table = [
        (u(MSG_OOB), "MSG_OOB"), (u(MSG_PEEK), "MSG_PEEK"), (u(MSG_DONTROUTE), "MSG_DONTROUTE"), (u(MSG_EOR), "MSG_EOR"),
        (u(MSG_TRUNC), "MSG_TRUNC"), (u(MSG_CTRUNC), "MSG_CTRUNC"), (u(MSG_WAITALL), "MSG_WAITALL"), (u(MSG_DONTWAIT), "MSG_DONTWAIT"),
        (u(MSG_EOF), "MSG_EOF"), (u(MSG_FLUSH), "MSG_FLUSH"), (u(MSG_HOLD), "MSG_HOLD"), (u(MSG_SEND), "MSG_SEND"),
        (u(MSG_HAVEMORE), "MSG_HAVEMORE"), (u(MSG_RCVMORE), "MSG_RCVMORE"), (u(MSG_NEEDSA), "MSG_NEEDSA"), (u(MSG_NOSIGNAL), "MSG_NOSIGNAL"),
    ]
    static let shutdownHow: Table = [(u(SHUT_RD), "SHUT_RD"), (u(SHUT_WR), "SHUT_WR"), (u(SHUT_RDWR), "SHUT_RDWR")]
    static let socketOptions: Table = [
        (u(SO_DEBUG), "SO_DEBUG"), (u(SO_ACCEPTCONN), "SO_ACCEPTCONN"), (u(SO_REUSEADDR), "SO_REUSEADDR"), (u(SO_KEEPALIVE), "SO_KEEPALIVE"),
        (u(SO_DONTROUTE), "SO_DONTROUTE"), (u(SO_BROADCAST), "SO_BROADCAST"), (u(SO_USELOOPBACK), "SO_USELOOPBACK"), (u(SO_LINGER), "SO_LINGER"),
        (u(SO_OOBINLINE), "SO_OOBINLINE"), (u(SO_REUSEPORT), "SO_REUSEPORT"), (u(SO_TIMESTAMP), "SO_TIMESTAMP"),
        (u(SO_TIMESTAMP_MONOTONIC), "SO_TIMESTAMP_MONOTONIC"), (u(SO_SNDBUF), "SO_SNDBUF"), (u(SO_RCVBUF), "SO_RCVBUF"),
        (u(SO_SNDLOWAT), "SO_SNDLOWAT"), (u(SO_RCVLOWAT), "SO_RCVLOWAT"), (u(SO_SNDTIMEO), "SO_SNDTIMEO"), (u(SO_RCVTIMEO), "SO_RCVTIMEO"),
        (u(SO_ERROR), "SO_ERROR"), (u(SO_TYPE), "SO_TYPE"), (u(SO_NREAD), "SO_NREAD"), (u(SO_NKE), "SO_NKE"), (u(SO_NOSIGPIPE), "SO_NOSIGPIPE"),
        (u(SO_NOADDRERR), "SO_NOADDRERR"), (u(SO_NWRITE), "SO_NWRITE"), (u(SO_REUSESHAREUID), "SO_REUSESHAREUID"),
        (u(SO_LINGER_SEC), "SO_LINGER_SEC"), (u(SO_NETSVC_MARKING_LEVEL), "SO_NETSVC_MARKING_LEVEL"), (u(SO_NUMRCVPKT), "SO_NUMRCVPKT"),
    ]
    static let tcpOptions: Table = [
        (u(TCP_NODELAY), "TCP_NODELAY"), (u(TCP_MAXSEG), "TCP_MAXSEG"), (u(TCP_NOOPT), "TCP_NOOPT"), (u(TCP_NOPUSH), "TCP_NOPUSH"),
        (u(TCP_KEEPALIVE), "TCP_KEEPALIVE"), (u(TCP_CONNECTIONTIMEOUT), "TCP_CONNECTIONTIMEOUT"), (u(TCP_KEEPINTVL), "TCP_KEEPINTVL"),
        (u(TCP_KEEPCNT), "TCP_KEEPCNT"), (u(TCP_SENDMOREACKS), "TCP_SENDMOREACKS"), (u(TCP_ENABLE_ECN), "TCP_ENABLE_ECN"),
        (u(TCP_FASTOPEN), "TCP_FASTOPEN"), (u(TCP_CONNECTION_INFO), "TCP_CONNECTION_INFO"), (u(TCP_NOTSENT_LOWAT), "TCP_NOTSENT_LOWAT"),
    ]
    /// (level, option name): option names are per level.
    static func sockopt(level: UInt64, _ name: UInt64) -> (String, String) {
        switch Int32(truncatingIfNeeded: level) {
        case SOL_SOCKET: return ("SOL_SOCKET", one(name, socketOptions))
        case IPPROTO_TCP: return ("IPPROTO_TCP", one(name, tcpOptions))
        default: return (one(level, protocols), "\(Int64(bitPattern: name))")
        }
    }

    static let chflags: Table = [(u(UF_NODUMP), "UF_NODUMP"), (u(UF_IMMUTABLE), "UF_IMMUTABLE"), (u(UF_APPEND), "UF_APPEND"),
                                 (u(UF_OPAQUE), "UF_OPAQUE"), (u(UF_COMPRESSED), "UF_COMPRESSED"), (u(UF_TRACKED), "UF_TRACKED"),
                                 (u(UF_DATAVAULT), "UF_DATAVAULT"), (u(UF_HIDDEN), "UF_HIDDEN"), (u(SF_ARCHIVED), "SF_ARCHIVED"),
                                 (u(SF_IMMUTABLE), "SF_IMMUTABLE"), (u(SF_APPEND), "SF_APPEND"), (u(SF_RESTRICTED), "SF_RESTRICTED"),
                                 (u(SF_NOUNLINK), "SF_NOUNLINK")]
    /// bsd/sys/snapshot.h (values as in pykdebugparser)
    static let snapshotOps: Table = [(1, "SNAPSHOT_OP_CREATE"), (2, "SNAPSHOT_OP_DELETE"), (3, "SNAPSHOT_OP_RENAME"),
                                     (4, "SNAPSHOT_OP_MOUNT"), (5, "SNAPSHOT_OP_REVERT"), (6, "SNAPSHOT_OP_ROOT")]

    static let purgableControls: Table = [(u(VM_PURGABLE_SET_STATE), "VM_PURGABLE_SET_STATE"), (u(VM_PURGABLE_GET_STATE), "VM_PURGABLE_GET_STATE"),
                                          (u(VM_PURGABLE_PURGE_ALL), "VM_PURGABLE_PURGE_ALL"),
                                          (u(VM_PURGABLE_SET_STATE_FROM_KERNEL), "VM_PURGABLE_SET_STATE_FROM_KERNEL")]
    /// bsd/sys/resource_private.h
    static let iopolCmds: Table = [(1, "IOPOL_CMD_GET"), (2, "IOPOL_CMD_SET")]

    // MARK: processes and threads

    /// bsd/pthread/workqueue_syscalls.h
    static let workloopCmds: Table = [(1, "KQ_WORKLOOP_CREATE"), (2, "KQ_WORKLOOP_DESTROY")]
    /// bsd/sys/coalition_private.h
    static let coalitionOps: Table = [(1, "COALITION_OP_CREATE"), (2, "COALITION_OP_TERMINATE"), (3, "COALITION_OP_REAP")]
    static let coalitionInfos: Table = [(1, "COALITION_INFO_RESOURCE_USAGE"), (2, "COALITION_INFO_SET_NAME"),
                                        (3, "COALITION_INFO_SET_EFFICIENCY"), (4, "COALITION_INFO_GET_DEBUG_INFO")]
    /// bsd/sys/kern_memorystatus.h
    static let memorystatusCmds: Table = [
        (1, "MEMORYSTATUS_CMD_GET_PRIORITY_LIST"), (2, "MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES"), (3, "MEMORYSTATUS_CMD_GET_JETSAM_SNAPSHOT"),
        (4, "MEMORYSTATUS_CMD_GET_PRESSURE_STATUS"), (5, "MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK"),
        (6, "MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT"), (7, "MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES"),
        (8, "MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES"), (9, "MEMORYSTATUS_CMD_PRIVILEGED_LISTENER_ENABLE"),
        (10, "MEMORYSTATUS_CMD_PRIVILEGED_LISTENER_DISABLE"), (11, "MEMORYSTATUS_CMD_AGGRESSIVE_JETSAM_LENIENT_MODE_ENABLE"),
        (12, "MEMORYSTATUS_CMD_AGGRESSIVE_JETSAM_LENIENT_MODE_DISABLE"), (13, "MEMORYSTATUS_CMD_GET_MEMLIMIT_EXCESS"),
        (14, "MEMORYSTATUS_CMD_ELEVATED_INACTIVEJETSAMPRIORITY_ENABLE"), (15, "MEMORYSTATUS_CMD_ELEVATED_INACTIVEJETSAMPRIORITY_DISABLE"),
        (16, "MEMORYSTATUS_CMD_SET_PROCESS_IS_MANAGED"), (17, "MEMORYSTATUS_CMD_GET_PROCESS_IS_MANAGED"),
        (18, "MEMORYSTATUS_CMD_SET_PROCESS_IS_FREEZABLE"), (19, "MEMORYSTATUS_CMD_GET_PROCESS_IS_FREEZABLE"),
        (20, "MEMORYSTATUS_CMD_FREEZER_CONTROL"), (21, "MEMORYSTATUS_CMD_GET_AGGRESSIVE_JETSAM_LENIENT_MODE"),
        (22, "MEMORYSTATUS_CMD_INCREASE_JETSAM_TASK_LIMIT"), (23, "MEMORYSTATUS_CMD_SET_TESTING_PID"),
        (24, "MEMORYSTATUS_CMD_GET_PROCESS_IS_FROZEN"), (25, "MEMORYSTATUS_CMD_MARK_PROCESS_COALITION_SWAPPABLE"),
        (26, "MEMORYSTATUS_CMD_GET_PROCESS_COALITION_IS_SWAPPABLE"), (28, "MEMORYSTATUS_CMD_CONVERT_MEMLIMIT_MB"),
        (30, "MEMORYSTATUS_CMD_SET_DIAG_LIMIT"), (31, "MEMORYSTATUS_CMD_GET_DIAG_LIMIT"), (32, "MEMORYSTATUS_CMD_GET_JETSAM_ZPRINT_NAMES"),
        (33, "MEMORYSTATUS_CMD_GET_JETSAM_ZPRINT_INFO"), (34, "MEMORYSTATUS_CMD_GET_JETSAM_ZPRINT_MEMINFO"),
        (35, "MEMORYSTATUS_CMD_GET_PRIORITY_LIST_V2"), (36, "MEMORYSTATUS_CMD_REARM_MEMLIMIT"), (37, "MEMORYSTATUS_CMD_GET_KILL_COUNTS"),
        (38, "MEMORYSTATUS_CMD_GET_CONCLAVE_LIMIT"), (100, "MEMORYSTATUS_CMD_GRP_SET_PROPERTIES"),
    ]

    /// bsd/sys/persona.h
    static let personaOps: Table = [(1, "PERSONA_OP_ALLOC"), (2, "PERSONA_OP_PALLOC"), (3, "PERSONA_OP_DEALLOC"), (4, "PERSONA_OP_GET"),
                                    (5, "PERSONA_OP_INFO"), (6, "PERSONA_OP_PIDINFO"), (7, "PERSONA_OP_FIND"), (8, "PERSONA_OP_GETPATH"),
                                    (9, "PERSONA_OP_FIND_BY_TYPE")]

    static let prioWhich: Table = [(u(PRIO_PROCESS), "PRIO_PROCESS"), (u(PRIO_PGRP), "PRIO_PGRP"), (u(PRIO_USER), "PRIO_USER"),
                                   (u(PRIO_DARWIN_THREAD), "PRIO_DARWIN_THREAD"), (u(PRIO_DARWIN_PROCESS), "PRIO_DARWIN_PROCESS")]
    static let rusageWho: Table = [(u(RUSAGE_SELF), "RUSAGE_SELF"), (UInt64(bitPattern: Int64(RUSAGE_CHILDREN)), "RUSAGE_CHILDREN")]
    static let rlimits: Table = [(u(RLIMIT_CPU), "RLIMIT_CPU"), (u(RLIMIT_FSIZE), "RLIMIT_FSIZE"), (u(RLIMIT_DATA), "RLIMIT_DATA"),
                                 (u(RLIMIT_STACK), "RLIMIT_STACK"), (u(RLIMIT_CORE), "RLIMIT_CORE"), (u(RLIMIT_AS), "RLIMIT_AS"),
                                 (u(RLIMIT_MEMLOCK), "RLIMIT_MEMLOCK"), (u(RLIMIT_NPROC), "RLIMIT_NPROC"), (u(RLIMIT_NOFILE), "RLIMIT_NOFILE")]
    static let waitOptions: Table = [(u(WNOHANG), "WNOHANG"), (u(WUNTRACED), "WUNTRACED"), (u(WEXITED), "WEXITED"),
                                     (u(WSTOPPED), "WSTOPPED"), (u(WCONTINUED), "WCONTINUED"), (u(WNOWAIT), "WNOWAIT")]

    static let sigHow: Table = [(u(SIG_BLOCK), "SIG_BLOCK"), (u(SIG_UNBLOCK), "SIG_UNBLOCK"), (u(SIG_SETMASK), "SIG_SETMASK")]
    /// bsd/sys/ulock.h: the low byte is the operation, the rest flags.
    static let ulockOps: Table = [(1, "UL_COMPARE_AND_WAIT"), (2, "UL_UNFAIR_LOCK"), (3, "UL_COMPARE_AND_WAIT_SHARED"),
                                  (4, "UL_UNFAIR_LOCK64_SHARED"), (5, "UL_COMPARE_AND_WAIT64"), (6, "UL_COMPARE_AND_WAIT64_SHARED")]
    static let ulockFlags: Table = [(0x100, "ULF_WAKE_ALL"), (0x200, "ULF_WAKE_THREAD"), (0x400, "ULF_WAKE_ALLOW_NON_OWNER"),
                                    (0x10000, "ULF_WAIT_WORKQ_DATA_CONTENTION"), (0x20000, "ULF_WAIT_CANCEL_POINT"),
                                    (0x40000, "ULF_WAIT_ADAPTIVE_SPIN"), (0x100_0000, "ULF_NO_ERRNO"), (0x200_0000, "ULF_DEADLINE")]
    static func ulock(_ v: UInt64) -> String {
        let op = one(v & 0xff, ulockOps), flags = v & 0xffff_ff00
        return flags == 0 ? op : op + "|" + bits(flags, ulockFlags)
    }
    /// bsd/pthread/workqueue_syscalls.h
    static let workqOps: Table = [(0x004, "WQOPS_THREAD_RETURN"), (0x010, "WQOPS_QUEUE_NEWSPISUPP"), (0x020, "WQOPS_QUEUE_REQTHREADS"),
                                  (0x030, "WQOPS_QUEUE_REQTHREADS2"),
                                  (0x040, "WQOPS_THREAD_KEVENT_RETURN"), (0x080, "WQOPS_SET_EVENT_MANAGER_PRIORITY"),
                                  (0x100, "WQOPS_THREAD_WORKLOOP_RETURN"), (0x200, "WQOPS_SHOULD_NARROW"), (0x400, "WQOPS_SETUP_DISPATCH")]
    /// bsd/net/necp.h (NECP_CLIENT_ACTION_*), without the prefix: what Network.framework asks of the kernel's
    /// registry of network clients and their flows.
    static let necpClientActions: Table = [
        (1, "ADD"), (2, "REMOVE"), (3, "COPY_PARAMETERS"), (4, "COPY_RESULT"), (5, "COPY_LIST"), (6, "REQUEST_NEXUS_INSTANCE"),
        (7, "AGENT"), (8, "COPY_AGENT"), (9, "COPY_INTERFACE"), (10, "SET_STATISTICS"), (11, "COPY_ROUTE_STATISTICS"),
        (12, "AGENT_USE"), (13, "MAP_SYSCTLS"), (14, "UPDATE_CACHE"), (15, "COPY_CLIENT_UPDATE"), (16, "COPY_UPDATED_RESULT"),
        (17, "ADD_FLOW"), (18, "REMOVE_FLOW"), (19, "CLAIM"), (20, "SIGN"), (21, "GET_INTERFACE_ADDRESS"),
        (22, "ACQUIRE_AGENT_TOKEN"), (23, "VALIDATE"), (24, "GET_SIGNED_CLIENT_ID"), (25, "SET_SIGNED_CLIENT_ID"),
        (26, "COPY_UPDATED_RESULT_FINAL"), (27, "GET_FLOW_STATISTICS"),
    ]
    /// bsd/skywalk/channel/os_channel.h: __channel_sync's sync_mode_t and sync_flags_t (Skywalk, the user-space
    /// packet channels Network.framework sends and receives through).
    static let channelSyncModes: Table = [(0, "CHANNEL_SYNC_TX"), (1, "CHANNEL_SYNC_RX"), (2, "CHANNEL_SYNC_UPP")]
    static let channelSyncFlags: Table = [(0x1, "CHANNEL_SYNCF_ALLOC"), (0x2, "CHANNEL_SYNCF_FREE"), (0x4, "CHANNEL_SYNCF_PURGE"),
                                          (0x8, "CHANNEL_SYNCF_ALLOC_BUF"), (0x10, "CHANNEL_SYNCF_LARGE_ALLOC")]
    /// libpthread's kern/kern_internal.h: psynch_cvwait fails with these bits over the errno in the low byte
    /// (pthread_cond.c reads `err & 0xff`, then hands the bits back to the condition variable's sequence words).
    static let psynchErrorBits: Table = [(0x100, "ECVCLEARED"), (0x200, "ECVPREPOST")]

    /// thread_qos_t (osfmk/mach/thread_policy_private.h), without the THREAD_QOS_ prefix.
    static let threadQoS: [UInt32: String] = [0: "UNSPECIFIED", 1: "MAINTENANCE", 2: "BACKGROUND", 3: "UTILITY",
                                              4: "DEFAULT", 5: "USER_INITIATED", 6: "USER_INTERACTIVE"]
    static func qos(_ q: UInt32) -> String { threadQoS[q] ?? "qos \(q)" }

    /// pthread_priority_t (bsd/pthread/priority_private.h): the QoS as a one-hot bit at 8 + qos - 1, relpri - 1
    /// in the low byte, flags in the top byte. With OVERRIDE_QOS, bits 14-21 hold an override QoS the same way;
    /// with SCHED_PRI, the low 16 bits are a scheduler priority instead. Checked by hand: 0x10ff is
    /// USER_INITIATED with relpri 0; 0x800008ff is DEFAULT, overcommit.
    static let priorityFlags: Table = [(0x8000_0000, "OVERCOMMIT"), (0x4000_0000, "INHERIT"), (0x1000_0000, "ENFORCE"),
                                       (0x0800_0000, "COOPERATIVE"), (0x0400_0000, "FALLBACK"), (0x0200_0000, "EVENT_MANAGER"),
                                       (0x0100_0000, "NEEDS_UNBIND")]
    static func pthreadPriority(_ v: UInt64) -> String {
        let p = UInt32(truncatingIfNeeded: v)
        guard p != 0 else { return "UNSPECIFIED" }
        var s: String
        if p & 0x2000_0000 != 0 {
            s = "sched_pri \(p & 0xffff)"
        } else {
            let req = (p >> 8) & 0x3f
            s = req == 0 ? "UNSPECIFIED" : qos(UInt32(req.trailingZeroBitCount) + 1)
            let relpri = Int(Int8(bitPattern: UInt8(p & 0xff))) + 1
            if relpri != 0 { s += "(relpri \(relpri))" }
            if p & 0x0080_0000 != 0 {
                let o = (p >> 14) & 0xff
                if o != 0 { s += ", override " + qos(UInt32(o.trailingZeroBitCount) + 1) }
            }
        }
        let flags = UInt64(p & 0xdf00_0000)   // SCHED_PRI handled above
        return flags == 0 ? s : s + "|" + bits(flags, priorityFlags)
    }

    /// bsd/pthread/bsdthread_private.h; arguments per command as bsdthread_ctl() in bsd/pthread/pthread_workqueue.c
    /// reads them.
    static let bsdthreadCmds: Table = [
        (0x10, "BSDTHREAD_CTL_SET_QOS"), (0x20, "BSDTHREAD_CTL_GET_QOS"), (0x40, "BSDTHREAD_CTL_QOS_OVERRIDE_START"),
        (0x80, "BSDTHREAD_CTL_QOS_OVERRIDE_END"), (0x100, "BSDTHREAD_CTL_SET_SELF"), (0x200, "BSDTHREAD_CTL_QOS_OVERRIDE_RESET"),
        (0x400, "BSDTHREAD_CTL_QOS_OVERRIDE_DISPATCH"), (0x401, "BSDTHREAD_CTL_QOS_DISPATCH_ASYNCHRONOUS_OVERRIDE_ADD"),
        (0x402, "BSDTHREAD_CTL_QOS_DISPATCH_ASYNCHRONOUS_OVERRIDE_RESET"), (0x800, "BSDTHREAD_CTL_QOS_MAX_PARALLELISM"),
        (0x1000, "BSDTHREAD_CTL_WORKQ_ALLOW_KILL"), (0x2000, "BSDTHREAD_CTL_DISPATCH_APPLY_ATTR"),
        (0x4000, "BSDTHREAD_CTL_WORKQ_ALLOW_SIGMASK"),
    ]
    /// enum workq_set_self_flags (bsd/pthread/workqueue_internal.h)
    static let setSelfFlags: Table = [(0x01, "WORKQ_SET_SELF_QOS_FLAG"), (0x02, "WORKQ_SET_SELF_VOUCHER_FLAG"),
                                      (0x04, "WORKQ_SET_SELF_FIXEDPRIORITY_FLAG"), (0x08, "WORKQ_SET_SELF_TIMESHARE_FLAG"),
                                      (0x10, "WORKQ_SET_SELF_WQ_KEVENT_UNBIND"), (0x40, "WORKQ_SET_SELF_QOS_OVERRIDE_FLAG")]

    private static func hex(_ v: UInt64) -> String { v == 0 ? "NULL" : "0x" + String(v, radix: 16) }
    private static func port(_ v: UInt64) -> String { "0x" + String(v & 0xffff_ffff, radix: 16) }

    /// Argument names per command, for the arguments bsdthreadCtl shows.
    static func bsdthreadCtlNames(_ cmd: UInt64) -> [String]? {
        switch cmd {
        case 0x40, 0x400: return ["cmd", "thread", "priority", "resource"]
        case 0x80: return ["cmd", "thread", "resource"]
        case 0x200: return ["cmd"]
        case 0x100: return ["cmd", "priority", "voucher", "flags"]
        case 0x800: return ["cmd", "qos", "flags"]
        case 0x1000: return ["cmd", "allow"]
        case 0x4000: return ["cmd", "sigmask"]
        default: return nil
        }
    }

    static func bsdthreadCtl(_ a: [UInt64]) -> [String] {
        guard a.count >= 4 else { return a.map { SyscallFormat.value($0) } }
        let cmd = one(a[0], bsdthreadCmds)
        let rest: [String]
        switch a[0] {
        case 0x40, 0x400: rest = [port(a[1]), pthreadPriority(a[2]), hex(a[3])]    // thread, priority, resource / ulock
        case 0x80: rest = [port(a[1]), hex(a[2])]                                   // thread, resource
        case 0x200: rest = []
        case 0x100:                                                                 // priority, voucher, flags
            let f = a[3]
            rest = [f & 0x1 != 0 ? pthreadPriority(a[1]) : "-",
                    f & 0x2 != 0 ? "0x" + String(a[2] & 0xffff_ffff, radix: 16) : "-",
                    bits(f, setSelfFlags)]
        case 0x800: rest = [qos(UInt32(truncatingIfNeeded: a[1])), "0x" + String(a[2], radix: 16)]   // qos, flags
        case 0x1000: rest = [a[1] != 0 ? "true" : "false"]
        case 0x4000: rest = ["0x" + String(a[1], radix: 16)]                       // signal mask
        default: rest = a[1...].map { "0x" + String($0, radix: 16) }
        }
        return [cmd] + rest
    }

    static func workqKernreturnNames(_ op: UInt64) -> [String]? {
        switch op {
        case 0x020, 0x030: return ["op", "count", "priority"]
        case 0x080, 0x200: return ["op", "priority"]
        case 0x010: return ["op", "serialno_offset", "kevent"]
        case 0x400: return ["op", "config", "size"]
        case 0x004: return ["op"]
        default: return ["op", "item", "arg2", "arg3"]
        }
    }

    /// workq_kernreturn(op, item, arg2, arg3) as bsd/pthread/pthread_workqueue.c reads them.
    static func workqKernreturn(_ a: [UInt64]) -> [String] {
        guard a.count >= 4 else { return a.map { SyscallFormat.value($0) } }
        let op = one(a[0], workqOps)
        let arg2 = Int32(truncatingIfNeeded: a[2])
        let rest: [String]
        switch a[0] {
        case 0x020, 0x030: rest = ["\(arg2)", pthreadPriority(a[3])]
        case 0x080, 0x200: rest = [pthreadPriority(a[2])]
        case 0x010: rest = ["\(arg2)", "\(Int32(truncatingIfNeeded: a[3]))"]
        case 0x400: rest = [hex(a[1]), "\(arg2)"]                                  // config, its size
        case 0x004: rest = []
        default: rest = [hex(a[1]), "\(arg2)", "\(Int32(truncatingIfNeeded: a[3]))"]
        }
        return [op] + rest
    }

    /// bsd/sys/codesign.h
    static let csops: Table = [(0, "CS_OPS_STATUS"), (1, "CS_OPS_MARKINVALID"), (2, "CS_OPS_MARKHARD"), (3, "CS_OPS_MARKKILL"),
                               (5, "CS_OPS_CDHASH"), (6, "CS_OPS_PIDOFFSET"), (7, "CS_OPS_ENTITLEMENTS_BLOB"), (8, "CS_OPS_MARKRESTRICT"),
                               (9, "CS_OPS_SET_STATUS"), (10, "CS_OPS_BLOB"), (11, "CS_OPS_IDENTITY"), (12, "CS_OPS_CLEARINSTALLER"),
                               (13, "CS_OPS_CLEARPLATFORM"), (14, "CS_OPS_TEAMID"), (15, "CS_OPS_CLEAR_LV"),
                               (16, "CS_OPS_DER_ENTITLEMENTS_BLOB"), (17, "CS_OPS_VALIDATION_CATEGORY"), (18, "CS_OPS_CDHASH_WITH_INFO")]
    /// bsd/sys/proc_info_private.h
    static let procInfoCalls: Table = [
        (1, "PROC_INFO_CALL_LISTPIDS"), (2, "PROC_INFO_CALL_PIDINFO"), (3, "PROC_INFO_CALL_PIDFDINFO"), (4, "PROC_INFO_CALL_KERNMSGBUF"),
        (5, "PROC_INFO_CALL_SETCONTROL"), (6, "PROC_INFO_CALL_PIDFILEPORTINFO"), (7, "PROC_INFO_CALL_TERMINATE"),
        (8, "PROC_INFO_CALL_DIRTYCONTROL"), (9, "PROC_INFO_CALL_PIDRUSAGE"), (10, "PROC_INFO_CALL_PIDORIGINATORINFO"),
        (11, "PROC_INFO_CALL_LISTCOALITIONS"), (12, "PROC_INFO_CALL_CANUSEFGHW"), (13, "PROC_INFO_CALL_PIDDYNKQUEUEINFO"),
        (14, "PROC_INFO_CALL_UDATA_INFO"), (15, "PROC_INFO_CALL_SET_DYLD_IMAGES"), (16, "PROC_INFO_CALL_TERMINATE_RSR"),
        (17, "PROC_INFO_CALL_SIGNAL_AUDITTOKEN"),
    ]
    /// PROC_INFO_CALL_PIDINFO flavors: <sys/proc_info.h>, and proc_info_private.h from 17 up.
    static let pidInfoFlavors: Table = [
        (u(PROC_PIDLISTFDS), "PROC_PIDLISTFDS"), (u(PROC_PIDTASKALLINFO), "PROC_PIDTASKALLINFO"), (u(PROC_PIDTBSDINFO), "PROC_PIDTBSDINFO"),
        (u(PROC_PIDTASKINFO), "PROC_PIDTASKINFO"), (u(PROC_PIDTHREADINFO), "PROC_PIDTHREADINFO"), (u(PROC_PIDLISTTHREADS), "PROC_PIDLISTTHREADS"),
        (u(PROC_PIDREGIONINFO), "PROC_PIDREGIONINFO"), (u(PROC_PIDREGIONPATHINFO), "PROC_PIDREGIONPATHINFO"),
        (u(PROC_PIDVNODEPATHINFO), "PROC_PIDVNODEPATHINFO"), (u(PROC_PIDTHREADPATHINFO), "PROC_PIDTHREADPATHINFO"),
        (u(PROC_PIDPATHINFO), "PROC_PIDPATHINFO"), (u(PROC_PIDWORKQUEUEINFO), "PROC_PIDWORKQUEUEINFO"),
        (u(PROC_PIDT_SHORTBSDINFO), "PROC_PIDT_SHORTBSDINFO"), (u(PROC_PIDLISTFILEPORTS), "PROC_PIDLISTFILEPORTS"),
        (u(PROC_PIDTHREADID64INFO), "PROC_PIDTHREADID64INFO"), (u(PROC_PID_RUSAGE), "PROC_PID_RUSAGE"), (u(PROC_PIDARCHINFO), "PROC_PIDARCHINFO"),
        (17, "PROC_PIDUNIQIDENTIFIERINFO"), (18, "PROC_PIDT_BSDINFOWITHUNIQID"), (20, "PROC_PIDCOALITIONINFO"), (21, "PROC_PIDNOTEEXIT"),
        (22, "PROC_PIDREGIONPATHINFO2"), (23, "PROC_PIDREGIONPATHINFO3"), (24, "PROC_PIDEXITREASONINFO"),
        (25, "PROC_PIDEXITREASONBASICINFO"), (26, "PROC_PIDLISTUPTRS"), (27, "PROC_PIDLISTDYNKQUEUES"), (28, "PROC_PIDLISTTHREADIDS"),
        (29, "PROC_PIDVMRTFAULTINFO"), (30, "PROC_PIDPLATFORMINFO"), (31, "PROC_PIDREGIONPATH"), (32, "PROC_PIDIPCTABLEINFO"),
        (33, "PROC_PIDTHREADSCHEDINFO"), (34, "PROC_PIDTHREADCOUNTS"),
    ]

    // MARK: Mach

    static let portRights: Table = [(u(MACH_PORT_RIGHT_SEND), "MACH_PORT_RIGHT_SEND"), (u(MACH_PORT_RIGHT_RECEIVE), "MACH_PORT_RIGHT_RECEIVE"),
                                    (u(MACH_PORT_RIGHT_SEND_ONCE), "MACH_PORT_RIGHT_SEND_ONCE"), (u(MACH_PORT_RIGHT_PORT_SET), "MACH_PORT_RIGHT_PORT_SET"),
                                    (u(MACH_PORT_RIGHT_DEAD_NAME), "MACH_PORT_RIGHT_DEAD_NAME")]
    static let machNotifications: Table = [
        (u(MACH_NOTIFY_PORT_DELETED), "MACH_NOTIFY_PORT_DELETED"), (u(MACH_NOTIFY_SEND_POSSIBLE), "MACH_NOTIFY_SEND_POSSIBLE"),
        (u(MACH_NOTIFY_PORT_DESTROYED), "MACH_NOTIFY_PORT_DESTROYED"), (u(MACH_NOTIFY_NO_SENDERS), "MACH_NOTIFY_NO_SENDERS"),
        (u(MACH_NOTIFY_SEND_ONCE), "MACH_NOTIFY_SEND_ONCE"), (u(MACH_NOTIFY_DEAD_NAME), "MACH_NOTIFY_DEAD_NAME"),
    ]
    static let msgTypes: Table = [(u(MACH_MSG_TYPE_MOVE_RECEIVE), "MOVE_RECEIVE"), (u(MACH_MSG_TYPE_MOVE_SEND), "MOVE_SEND"),
                                  (u(MACH_MSG_TYPE_MOVE_SEND_ONCE), "MOVE_SEND_ONCE"), (u(MACH_MSG_TYPE_COPY_SEND), "COPY_SEND"),
                                  (u(MACH_MSG_TYPE_MAKE_SEND), "MAKE_SEND"), (u(MACH_MSG_TYPE_MAKE_SEND_ONCE), "MAKE_SEND_ONCE")]
    static let machOptions: Table = [
        (u(MACH_SEND_MSG), "MACH_SEND_MSG"), (u(MACH_RCV_MSG), "MACH_RCV_MSG"), (u(MACH_RCV_LARGE), "MACH_RCV_LARGE"),
        (u(MACH_RCV_LARGE_IDENTITY), "MACH_RCV_LARGE_IDENTITY"), (u(MACH_SEND_TIMEOUT), "MACH_SEND_TIMEOUT"),
        (u(MACH_SEND_OVERRIDE), "MACH_SEND_OVERRIDE"), (u(MACH_SEND_INTERRUPT), "MACH_SEND_INTERRUPT"), (u(MACH_SEND_NOTIFY), "MACH_SEND_NOTIFY"),
        (u(MACH_SEND_ALWAYS), "MACH_SEND_ALWAYS"), (u(MACH_SEND_FILTER_NONFATAL), "MACH_SEND_FILTER_NONFATAL"),
        (u(MACH_SEND_TRAILER), "MACH_SEND_TRAILER"), (u(MACH_SEND_NOIMPORTANCE), "MACH_SEND_NOIMPORTANCE"),
        (u(MACH_SEND_NODENAP), "MACH_SEND_NODENAP"), (u(MACH_SEND_SYNC_OVERRIDE), "MACH_SEND_SYNC_OVERRIDE"),
        (u(MACH_SEND_PROPAGATE_QOS), "MACH_SEND_PROPAGATE_QOS"), (u(MACH_SEND_SYNC_BOOTSTRAP_CHECKIN), "MACH_SEND_SYNC_BOOTSTRAP_CHECKIN"),
        (u(MACH_RCV_TIMEOUT), "MACH_RCV_TIMEOUT"), (u(MACH_RCV_INTERRUPT), "MACH_RCV_INTERRUPT"), (u(MACH_RCV_VOUCHER), "MACH_RCV_VOUCHER"),
        (u(MACH_RCV_GUARDED_DESC), "MACH_RCV_GUARDED_DESC"), (u(MACH_RCV_SYNC_WAIT), "MACH_RCV_SYNC_WAIT"),
        (u(MACH_RCV_SYNC_PEEK), "MACH_RCV_SYNC_PEEK"), (u(MACH_MSG_STRICT_REPLY), "MACH_MSG_STRICT_REPLY"),
    ]
    /// osfmk/mach/message.h, above the 32-bit options.
    static let mach64Options: Table = [
        (0x1_0000_0000, "MACH64_MSG_VECTOR"), (0x2_0000_0000, "MACH64_SEND_KOBJECT_CALL"), (0x4_0000_0000, "MACH64_SEND_MQ_CALL"),
        (0x8_0000_0000, "MACH64_SEND_ANY"), (0x10_0000_0000, "MACH64_SEND_DK_CALL"),
        (0x20_0000_0000, "MACH64_POLICY_KERNEL_EXTENSION"), (0x40_0000_0000, "MACH64_POLICY_FILTER_NON_FATAL"),
        (0x80_0000_0000, "MACH64_POLICY_FILTER_MSG"), (0x1000_0000_0000_0000, "MACH64_RCV_LINEAR_VECTOR"),
        (0x2000_0000_0000_0000, "MACH64_RCV_STACK"), (0x8000_0000_0000_0000, "MACH64_MACH_MSG2"),
    ]

    /// mach_msg2_trap(data, options64, msgh_bits | send_size << 32, remote | local << 32): checked against a
    /// message built by hand (size 40, COPY_SEND to 0x903, MAKE_SEND_ONCE reply 0xa03). The header words mean
    /// something only when sending; the message id is the fifth argument, which kdebug doesn't log.
    static func machMsg2(_ a: [UInt64]) -> [String] {
        guard a.count >= 4 else { return a.map { SyscallFormat.value($0) } }
        let opts = a[1]
        var parts = [a[0] == 0 ? "NULL" : "0x" + String(a[0], radix: 16), bits(opts, machOptions + mach64Options)]
        if opts & u(MACH_SEND_MSG) != 0 {
            let bitsWord = a[2] & 0xffff_ffff, size = a[2] >> 32
            let remote = a[3] & 0xffff_ffff, local = a[3] >> 32
            let rType = one(bitsWord & 0x1f, msgTypes), lType = one((bitsWord >> 8) & 0x1f, msgTypes)
            // With MACH64_MSG_VECTOR (XPC) the size word counts the message's vectors (header, then payload), not bytes.
            let what = opts & 0x1_0000_0000 != 0 ? "\(size) vector\(size == 1 ? "" : "s")" : "\(size) bytes"
            var h = what + " to 0x" + String(remote, radix: 16) + " (\(rType))"
            if local != 0 { h += ", reply 0x" + String(local, radix: 16) + " (\(lType))" }
            if bitsWord & u(MACH_MSGH_BITS_COMPLEX) != 0 { h += ", complex" }
            parts.append(h)
        }
        return parts
    }
}
