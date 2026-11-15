import Foundation
import MachO

/// Names and formats for Mach-O fields, from the macOS 27.2 SDK's <mach-o/loader.h> and <mach/machine.h>.
/// A value missing here is shown as its number, never dropped.
enum MachONames {
    typealias Bits = [(UInt32, String, String)]

    static func loadCommand(_ c: UInt32) -> String {
        let names: [UInt32: String] = [
            0x1: "LC_SEGMENT", 0x2: "LC_SYMTAB", 0x3: "LC_SYMSEG", 0x4: "LC_THREAD", 0x5: "LC_UNIXTHREAD", 0x6: "LC_LOADFVMLIB",
            0x7: "LC_IDFVMLIB", 0x8: "LC_IDENT", 0x9: "LC_FVMFILE", 0xa: "LC_PREPAGE", 0xb: "LC_DYSYMTAB", 0xc: "LC_LOAD_DYLIB",
            0xd: "LC_ID_DYLIB", 0xe: "LC_LOAD_DYLINKER", 0xf: "LC_ID_DYLINKER", 0x10: "LC_PREBOUND_DYLIB", 0x11: "LC_ROUTINES",
            0x12: "LC_SUB_FRAMEWORK", 0x13: "LC_SUB_UMBRELLA", 0x14: "LC_SUB_CLIENT", 0x15: "LC_SUB_LIBRARY", 0x16: "LC_TWOLEVEL_HINTS",
            0x17: "LC_PREBIND_CKSUM", 0x80000018: "LC_LOAD_WEAK_DYLIB", 0x19: "LC_SEGMENT_64", 0x1a: "LC_ROUTINES_64", 0x1b: "LC_UUID",
            0x8000001c: "LC_RPATH", 0x1d: "LC_CODE_SIGNATURE", 0x1e: "LC_SEGMENT_SPLIT_INFO", 0x8000001f: "LC_REEXPORT_DYLIB",
            0x20: "LC_LAZY_LOAD_DYLIB", 0x21: "LC_ENCRYPTION_INFO", 0x22: "LC_DYLD_INFO", 0x80000022: "LC_DYLD_INFO_ONLY",
            0x80000023: "LC_LOAD_UPWARD_DYLIB", 0x24: "LC_VERSION_MIN_MACOSX", 0x25: "LC_VERSION_MIN_IPHONEOS", 0x26: "LC_FUNCTION_STARTS",
            0x27: "LC_DYLD_ENVIRONMENT", 0x80000028: "LC_MAIN", 0x29: "LC_DATA_IN_CODE", 0x2a: "LC_SOURCE_VERSION",
            0x2b: "LC_DYLIB_CODE_SIGN_DRS", 0x2c: "LC_ENCRYPTION_INFO_64", 0x2d: "LC_LINKER_OPTION", 0x2e: "LC_LINKER_OPTIMIZATION_HINT",
            0x2f: "LC_VERSION_MIN_TVOS", 0x30: "LC_VERSION_MIN_WATCHOS", 0x31: "LC_NOTE", 0x32: "LC_BUILD_VERSION",
            0x80000033: "LC_DYLD_EXPORTS_TRIE", 0x80000034: "LC_DYLD_CHAINED_FIXUPS", 0x80000035: "LC_FILESET_ENTRY", 0x36: "LC_ATOM_INFO",
            0x37: "LC_FUNCTION_VARIANTS", 0x38: "LC_FUNCTION_VARIANT_FIXUPS", 0x39: "LC_TARGET_TRIPLE", 0x3a: "LC_LAZY_LOAD_DYLIB_INFO",
        ]
        return names[c] ?? "unknown 0x" + String(c, radix: 16)
    }

    /// What a linkedit_data_command's data is.
    static func blobName(_ c: UInt32) -> String {
        switch c {
        case 0x1d: "Code signature"
        case 0x1e: "Segment split info"
        case 0x26: "Function starts"
        case 0x29: "Data in code"
        case 0x2b: "Linked libraries' designated requirements"
        case 0x2e: "Linker optimization hints"
        case 0x80000033: "Exports trie"
        case 0x80000034: "Chained fixups"
        case 0x36: "Atom info"
        case 0x37: "Function variants"
        case 0x38: "Function variant fixups"
        case 0x3a: "Lazy-load library info"
        default: loadCommand(c)
        }
    }

    /// dyld's own name for the arch ("arm64e", "x86_64h"), else one built from the numbers.
    static func arch(_ type: Int32, _ subtype: Int32) -> String {
        if let n = DyldMachO.archName(type, subtype) { return n }
        let base = subtype & ~Int32(bitPattern: 0xff00_0000)
        if type == CPU_TYPE_ARM64 {
            switch base {
            case 0: return "arm64"
            case 1: return "arm64v8"
            case 2: return "arm64e"
            case 3: return "arm64_x1"
            case 12: return "arm64e_x1"
            default: break
            }
        }
        let types: [Int32: String] = [CPU_TYPE_X86: "i386", CPU_TYPE_X86_64: "x86_64", CPU_TYPE_ARM: "arm", CPU_TYPE_ARM64: "arm64",
                                      CPU_TYPE_ARM64_32: "arm64_32", CPU_TYPE_POWERPC: "ppc", CPU_TYPE_POWERPC64: "ppc64",
                                      CPU_TYPE_MC680x0: "m68k", CPU_TYPE_SPARC: "sparc", CPU_TYPE_I860: "i860", CPU_TYPE_HPPA: "hppa",
                                      CPU_TYPE_MC88000: "m88k", CPU_TYPE_VAX: "vax"]
        return "\(types[type] ?? "cpu \(type)") (subtype \(base))"
    }

    static func cpuType(_ t: Int32) -> String {
        let types: [Int32: String] = [CPU_TYPE_X86: "CPU_TYPE_X86", CPU_TYPE_X86_64: "CPU_TYPE_X86_64", CPU_TYPE_ARM: "CPU_TYPE_ARM",
                                      CPU_TYPE_ARM64: "CPU_TYPE_ARM64", CPU_TYPE_ARM64_32: "CPU_TYPE_ARM64_32", CPU_TYPE_POWERPC: "CPU_TYPE_POWERPC",
                                      CPU_TYPE_POWERPC64: "CPU_TYPE_POWERPC64"]
        return "\(types[t] ?? "unknown") (0x\(String(UInt32(bitPattern: t), radix: 16)))"
    }

    /// The subtype's number and its feature bits: for arm64e, the pointer-authentication ABI.
    static func cpuSubtype(_ t: Int32, _ s: Int32) -> String {
        let u = UInt32(bitPattern: s), base = u & 0x00ff_ffff
        var parts = ["\(base)"]
        if t == CPU_TYPE_ARM64, base == 2 || base == 12 {
            if u & 0x8000_0000 != 0 { parts.append("ptrauth ABI version \((u & 0x0f00_0000) >> 24)") }
            else { parts.append("no versioned ptrauth ABI") }
        } else if u & 0x8000_0000 != 0 {
            parts.append("CPU_SUBTYPE_LIB64")
        }
        return parts.joined(separator: ", ") + " (0x\(String(u, radix: 16)))"
    }

    static func fileType(_ t: UInt32) -> (String, String) {
        switch t {
        case 0x1: ("MH_OBJECT", "Relocatable object file")
        case 0x2: ("MH_EXECUTE", "Executable")
        case 0x3: ("MH_FVMLIB", "Fixed VM shared library")
        case 0x4: ("MH_CORE", "Core file")
        case 0x5: ("MH_PRELOAD", "Preloaded executable")
        case 0x6: ("MH_DYLIB", "Dynamic library")
        case 0x7: ("MH_DYLINKER", "Dynamic linker")
        case 0x8: ("MH_BUNDLE", "Bundle (loadable plug-in)")
        case 0x9: ("MH_DYLIB_STUB", "Library stub, for static linking only")
        case 0xa: ("MH_DSYM", "Debug symbols companion")
        case 0xb: ("MH_KEXT_BUNDLE", "Kernel extension")
        case 0xc: ("MH_FILESET", "File set (several Mach-Os sharing one linkedit)")
        case 0xd: ("MH_GPU_EXECUTE", "GPU program")
        case 0xe: ("MH_GPU_DYLIB", "GPU support functions")
        default: ("0x" + String(t, radix: 16), "Unknown file type")
        }
    }

    static let headerFlags: Bits = [
        (0x1, "MH_NOUNDEFS", "No undefined references"),
        (0x2, "MH_INCRLINK", "Output of an incremental link"),
        (0x4, "MH_DYLDLINK", "Input for the dynamic linker"),
        (0x8, "MH_BINDATLOAD", "Undefined references bound at load"),
        (0x10, "MH_PREBOUND", "Prebound"),
        (0x20, "MH_SPLIT_SEGS", "Read-only and read-write segments split"),
        (0x40, "MH_LAZY_INIT", "Lazy init (obsolete)"),
        (0x80, "MH_TWOLEVEL", "Two-level namespace: each import names its library"),
        (0x100, "MH_FORCE_FLAT", "Forces a flat namespace on all images"),
        (0x200, "MH_NOMULTIDEFS", "No multiple definitions in sub-images"),
        (0x400, "MH_NOFIXPREBINDING", "dyld won't redo prebinding"),
        (0x800, "MH_PREBINDABLE", "Can be prebound"),
        (0x1000, "MH_ALLMODSBOUND", "Binds to all two-level modules"),
        (0x2000, "MH_SUBSECTIONS_VIA_SYMBOLS", "Sections can be split by symbol (dead stripping)"),
        (0x4000, "MH_CANONICAL", "Canonicalized by unprebinding"),
        (0x8000, "MH_WEAK_DEFINES", "Exports weak definitions"),
        (0x10000, "MH_BINDS_TO_WEAK", "Uses weak definitions"),
        (0x20000, "MH_ALLOW_STACK_EXECUTION", "Stacks are executable"),
        (0x40000, "MH_ROOT_SAFE", "Safe for root (no DYLD_ variables honoured)"),
        (0x80000, "MH_SETUID_SAFE", "Safe for setuid"),
        (0x100000, "MH_NO_REEXPORTED_DYLIBS", "Re-exports no libraries"),
        (0x200000, "MH_PIE", "Position independent: loaded at a random address (ASLR)"),
        (0x400000, "MH_DEAD_STRIPPABLE_DYLIB", "Not linked if nothing in it is used"),
        (0x800000, "MH_HAS_TLV_DESCRIPTORS", "Has thread-local variables"),
        (0x1000000, "MH_NO_HEAP_EXECUTION", "Heap is not executable"),
        (0x2000000, "MH_APP_EXTENSION_SAFE", "Linked for use in app extensions"),
        (0x4000000, "MH_NLIST_OUTOFSYNC_WITH_DYLDINFO", "Symbol table doesn't list every export"),
        (0x8000000, "MH_SIM_SUPPORT", "Allows simulator-platform load commands"),
        (0x10000000, "MH_IMPLICIT_PAGEZERO", "No __PAGEZERO segment; the kernel reserves it"),
        (0x80000000, "MH_DYLIB_IN_CACHE", "Part of the dyld shared cache"),
    ]

    static let segmentFlags: Bits = [
        (0x1, "SG_HIGHVM", "File contents are the high part of the VM space"),
        (0x2, "SG_FVMLIB", "Allocated by a fixed VM library"),
        (0x4, "SG_NORELOC", "Nothing relocated in or to it"),
        (0x8, "SG_PROTECTED_VERSION_1", "Encrypted (protected) segment"),
        (0x10, "SG_READ_ONLY", "Made read-only after fixups"),
    ]

    static let dylibUseFlags: Bits = [
        (0x1, "DYLIB_USE_WEAK_LINK", "Weak: the program runs without it"),
        (0x2, "DYLIB_USE_REEXPORT", "Re-exported"),
        (0x4, "DYLIB_USE_UPWARD", "Upward link"),
        (0x8, "DYLIB_USE_DELAYED_INIT", "Initialized when first used"),
    ]

    static let sectionTypes: [UInt32: String] = [
        0x0: "S_REGULAR", 0x1: "S_ZEROFILL", 0x2: "S_CSTRING_LITERALS", 0x3: "S_4BYTE_LITERALS", 0x4: "S_8BYTE_LITERALS",
        0x5: "S_LITERAL_POINTERS", 0x6: "S_NON_LAZY_SYMBOL_POINTERS", 0x7: "S_LAZY_SYMBOL_POINTERS", 0x8: "S_SYMBOL_STUBS",
        0x9: "S_MOD_INIT_FUNC_POINTERS", 0xa: "S_MOD_TERM_FUNC_POINTERS", 0xb: "S_COALESCED", 0xc: "S_GB_ZEROFILL",
        0xd: "S_INTERPOSING", 0xe: "S_16BYTE_LITERALS", 0xf: "S_DTRACE_DOF", 0x10: "S_LAZY_DYLIB_SYMBOL_POINTERS",
        0x11: "S_THREAD_LOCAL_REGULAR", 0x12: "S_THREAD_LOCAL_ZEROFILL", 0x13: "S_THREAD_LOCAL_VARIABLES",
        0x14: "S_THREAD_LOCAL_VARIABLE_POINTERS", 0x15: "S_THREAD_LOCAL_INIT_FUNCTION_POINTERS", 0x16: "S_INIT_FUNC_OFFSETS",
    ]

    static let sectionAttributes: Bits = [
        (0x80000000, "S_ATTR_PURE_INSTRUCTIONS", "Only machine instructions"),
        (0x40000000, "S_ATTR_NO_TOC", "Coalesced symbols not in a table of contents"),
        (0x20000000, "S_ATTR_STRIP_STATIC_SYMS", "Static symbols may be stripped"),
        (0x10000000, "S_ATTR_NO_DEAD_STRIP", "Never dead-stripped"),
        (0x08000000, "S_ATTR_LIVE_SUPPORT", "Live if what it references is"),
        (0x04000000, "S_ATTR_SELF_MODIFYING_CODE", "Self-modifying code (i386 stubs)"),
        (0x02000000, "S_ATTR_DEBUG", "Debug information"),
        (0x00000400, "S_ATTR_SOME_INSTRUCTIONS", "Some machine instructions"),
        (0x00000200, "S_ATTR_EXT_RELOC", "Has external relocations"),
        (0x00000100, "S_ATTR_LOC_RELOC", "Has local relocations"),
    ]

    static func sectionType(_ flags: UInt32) -> String { sectionTypes[flags & 0xff] ?? "type 0x" + String(flags & 0xff, radix: 16) }
    static func sectionAttrs(_ flags: UInt32) -> [String] { set(flags & 0xffff_ff00, sectionAttributes).map(\.0) }

    static func platform(_ p: UInt32) -> String {
        let names = ["unknown", "macOS", "iOS", "tvOS", "watchOS", "bridgeOS", "Mac Catalyst", "iOS Simulator", "tvOS Simulator",
                     "watchOS Simulator", "DriverKit", "visionOS", "visionOS Simulator", "firmware", "sepOS", "macOS ExclaveCore",
                     "macOS ExclaveKit", "iOS ExclaveCore", "iOS ExclaveKit", "tvOS ExclaveCore", "tvOS ExclaveKit",
                     "watchOS ExclaveCore", "watchOS ExclaveKit", "visionOS ExclaveCore", "visionOS ExclaveKit"]
        if p == 0xffff_ffff { return "any" }
        return Int(p) < names.count ? names[Int(p)] : "platform \(p)"
    }

    static func tool(_ t: UInt32) -> String {
        let names: [UInt32: String] = [1: "clang", 2: "swift", 3: "ld", 4: "lld", 1024: "metal", 1025: "airlld", 1026: "airnt",
                                       1027: "airnt-plugin", 1028: "airpack", 1031: "gpuarchiver", 1032: "metal-framework"]
        return names[t] ?? "tool \(t)"
    }

    static func threadFlavor(_ cpu: Int32, _ f: UInt32) -> String {
        switch (cpu, f) {
        case (CPU_TYPE_ARM64, 6): "ARM_THREAD_STATE64"
        case (CPU_TYPE_ARM, 1): "ARM_THREAD_STATE"
        case (CPU_TYPE_X86_64, 4): "x86_THREAD_STATE64"
        case (CPU_TYPE_X86, 1): "i386_THREAD_STATE"
        case (CPU_TYPE_POWERPC, 1): "PPC_THREAD_STATE"
        default: "flavor \(f)"
        }
    }

    // MARK: Formats

    /// X.Y.Z packed in nibbles (xxxx.yy.zz), as dylib, OS and SDK versions are.
    static func version(_ v: UInt32) -> String {
        let a = v >> 16, b = (v >> 8) & 0xff, c = v & 0xff
        return c == 0 ? "\(a).\(b)" : "\(a).\(b).\(c)"
    }

    /// A.B.C.D.E packed as a24.b10.c10.d10.e10, trailing zeros dropped.
    static func sourceVersion(_ v: UInt64) -> String {
        var parts = [v >> 40, (v >> 30) & 0x3ff, (v >> 20) & 0x3ff, (v >> 10) & 0x3ff, v & 0x3ff]
        while parts.count > 1, parts.last == 0 { parts.removeLast() }
        return parts.map(String.init).joined(separator: ".")
    }

    /// r/w/x of a vm_prot_t.
    static func prot(_ p: Int32) -> String {
        (p & 1 != 0 ? "r" : "-") + (p & 2 != 0 ? "w" : "-") + (p & 4 != 0 ? "x" : "-")
    }

    static func set(_ v: UInt32, _ table: Bits) -> [(String, String)] {
        var out: [(String, String)] = [], left = v
        for (bit, name, help) in table where v & bit != 0 { out.append((name, help)); left &= ~bit }
        if left != 0 { out.append(("0x" + String(left, radix: 16), "Bits this SDK doesn't name")) }
        return out
    }

    static func bits(_ v: UInt32, _ table: Bits) -> String {
        v == 0 ? "none" : set(v, table).map(\.0).joined(separator: ", ") + " (0x\(String(v, radix: 16)))"
    }

    /// Binary units (Mach-O sizes are page multiples: 4 GiB of __PAGEZERO reads "4 GB", not "4.29 GB").
    static func size(_ v: UInt64) -> String {
        v < 1024 ? "\(v) bytes" : ByteCountFormatter.string(fromByteCount: Int64(clamping: v), countStyle: .memory)
    }
    static func sizeExact(_ v: UInt64) -> String {
        let n = count(v)
        return v < 1024 ? "\(n) bytes" : "\(size(v)) (\(n) bytes)"
    }
    static func count<T: BinaryInteger>(_ v: T) -> String { NumberFormatter.localizedString(from: NSNumber(value: Int64(clamping: v)), number: .decimal) }
    static func date(_ t: TimeInterval) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: t))
    }
}
