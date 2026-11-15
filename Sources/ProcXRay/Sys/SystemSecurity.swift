import Darwin
import Foundation

/// System Integrity Protection and AMFI state, read once: both are fixed at boot (changing them takes
/// recoveryOS or nvram plus a restart). Features that only work with protections relaxed gate on this.
struct SystemSecurity {
    /// Active SIP configuration (csr_config_t). 0 = fully enabled; each set bit relaxes one protection.
    /// nil when the kernel won't say (csr_get_active_config missing or failing).
    let csrConfig: UInt32?
    /// Kernel boot arguments (kern.bootargs), as nvram boot-args stood at boot.
    let bootArgs: String

    static let current = SystemSecurity()

    init() {
        csrConfig = Self.readCSR()
        var size = 0
        if sysctlbyname("kern.bootargs", nil, &size, nil, 0) == 0, size > 0 {
            var buf = [CChar](repeating: 0, count: size)
            bootArgs = sysctlbyname("kern.bootargs", &buf, &size, nil, 0) == 0 ? String(cString: buf) : ""
        } else {
            bootArgs = ""
        }
    }

    /// The bits of csr_config_t (xnu bsd/sys/csr.h) and what each one allows.
    enum Relaxation: UInt32, CaseIterable {
        case untrustedKexts = 0x1
        case unrestrictedFS = 0x2
        case taskForPid = 0x4
        case kernelDebugger = 0x8
        case appleInternal = 0x10
        case unrestrictedDTrace = 0x20
        case unrestrictedNVRAM = 0x40
        case deviceConfiguration = 0x80
        case anyRecoveryOS = 0x100
        case unapprovedKexts = 0x200
        case executablePolicyOverride = 0x400
        case unauthenticatedRoot = 0x800

        var label: String {
            switch self {
            case .untrustedKexts: "Untrusted kexts"
            case .unrestrictedFS: "Protected files writable"
            case .taskForPid: "Task ports of protected processes"
            case .kernelDebugger: "Kernel debugger"
            case .appleInternal: "Apple internal"
            case .unrestrictedDTrace: "Unrestricted DTrace"
            case .unrestrictedNVRAM: "Unrestricted NVRAM"
            case .deviceConfiguration: "Device configuration"
            case .anyRecoveryOS: "Any recoveryOS"
            case .unapprovedKexts: "Unapproved kexts"
            case .executablePolicyOverride: "Executable policy override"
            case .unauthenticatedRoot: "Unauthenticated root volume"
            }
        }
    }

    var relaxations: [Relaxation] {
        guard let c = csrConfig else { return [] }
        return Relaxation.allCases.filter { c & $0.rawValue != 0 }
    }

    func allows(_ r: Relaxation) -> Bool { (csrConfig ?? 0) & r.rawValue != 0 }

    /// Any SIP protection relaxed (what `csrutil status` reports as disabled or as a custom configuration).
    var sipRelaxed: Bool { (csrConfig ?? 0) != 0 }

    /// AMFI told to stop enforcing code signatures, so locally signed builds may carry restricted entitlements.
    var amfiDisabled: Bool {
        bootArgs.split(separator: " ").contains { $0 == "amfi_get_out_of_my_way=1" || $0 == "amfi_get_out_of_my_way=0x1" }
    }

    var summary: String {
        let sip: String
        switch csrConfig {
        case nil: sip = "unknown"
        case 0: sip = "enabled"
        case let c?: sip = String(format: "relaxed (0x%x): ", c) + relaxations.map(\.label).joined(separator: ", ")
        }
        return "SIP: \(sip)\nAMFI: \(amfiDisabled ? "disabled" : "enforcing")\nboot-args: \(bootArgs.isEmpty ? "(none)" : bootArgs)"
    }

    private static func readCSR() -> UInt32? {
        typealias Fn = @convention(c) (UnsafeMutablePointer<UInt32>) -> Int32
        guard let s = dlsym(dlopen(nil, RTLD_NOW), "csr_get_active_config") else { return nil }
        var config: UInt32 = 0
        return unsafeBitCast(s, to: Fn.self)(&config) == 0 ? config : nil
    }
}
