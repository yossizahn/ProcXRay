import Foundation
import Security

struct SignInfo: Sendable {
    var identifier: String?
    var teamID: String?
    var authority: [String] = []
    var isPlatform = false
    var isAppleSigned = false
    var isAdhoc = false
    var unsigned = false
    var valid: Bool?
    var staticFlags: UInt32 = 0
    var runtimeStatus: UInt32?
    var entitlementsXML: String?
    var entitlementKeys: [String] = []
    var designatedRequirement: String?
    var cdHash: String?
    var error: String?

    var shortSigner: String {
        if unsigned { return "unsigned" }
        // A signature that doesn't validate proves nothing about who made it: say so before any name.
        if valid == false { return "invalid" }
        if isPlatform { return "Apple (platform)" }
        if isAppleSigned { return "Apple" }
        if isAdhoc { return "ad-hoc" }
        if let t = teamID { return t }
        return authority.first ?? "?"
    }

    /// Decoded runtime CS flags (from <kern/cs_blobs.h>).
    var runtimeFlagNames: [String] {
        guard let s = runtimeStatus else { return [] }
        return Self.flagNames(s)
    }
    /// The CodeDirectory's own flags (SecCodeSignatureFlags), named as `codesign -d` prints them. They
    /// share few bits with the runtime CS_* status: static 0x1 is "host", runtime 0x1 is VALID.
    var staticFlagNames: [String] { Self.staticFlags.filter { staticFlags & $0.0 != 0 }.map(\.1) }
    static let staticFlags: [(UInt32, String)] = [
        (0x0000_0001, "host"), (0x0000_0002, "adhoc"), (0x0000_0100, "hard"), (0x0000_0200, "kill"),
        (0x0000_0400, "expires"), (0x0000_0800, "restrict"), (0x0000_1000, "enforcement"),
        (0x0000_2000, "library-validation"), (0x0001_0000, "runtime"), (0x0002_0000, "linker-signed"),
    ]

    static let csFlags: [(UInt32, String)] = [
        (0x0000_0001, "VALID"), (0x0000_0002, "ADHOC"), (0x0000_0004, "GET_TASK_ALLOW"),
        (0x0000_0008, "INSTALLER"), (0x0000_0010, "FORCED_LV"), (0x0000_0020, "INVALID_ALLOWED"),
        (0x0000_0100, "HARD"), (0x0000_0200, "KILL"), (0x0000_0400, "CHECK_EXPIRATION"),
        (0x0000_0800, "RESTRICT"), (0x0000_1000, "ENFORCEMENT"), (0x0000_2000, "REQUIRE_LV"),
        (0x0000_4000, "ENTITLEMENTS_VALIDATED"), (0x0000_8000, "NVRAM_UNRESTRICTED"),
        (0x0001_0000, "RUNTIME"), (0x0002_0000, "LINKER_SIGNED"), (0x0010_0000, "EXEC_SET_HARD"),
        (0x0020_0000, "EXEC_SET_KILL"), (0x0040_0000, "EXEC_SET_ENFORCEMENT"),
        (0x0080_0000, "EXEC_INHERIT_SIP"), (0x0100_0000, "KILLED"), (0x0200_0000, "NO_UNTRUSTED_HELPERS"),
        (0x0400_0000, "PLATFORM_BINARY"), (0x0800_0000, "PLATFORM_PATH"), (0x1000_0000, "DEBUGGED"),
        (0x2000_0000, "SIGNED"), (0x4000_0000, "DEV_CODE"), (0x8000_0000, "DATAVAULT_CONTROLLER"),
    ]
    static func flagNames(_ v: UInt32) -> [String] { csFlags.filter { v & $0.0 != 0 }.map(\.1) }
}

enum CodeSign {
    /// Apple's own software ("Software Signing" from Apple's CA), checked by Security rather than by
    /// certificate display names: anyone can make a chain whose certificates are *called* "Apple Root CA"
    /// and "Software Signing".
    private static let anchorApple = requirement("anchor apple")
    /// Signed by the Mac App Store. Every App Store app has this, so it says "Apple" only together with a
    /// com.apple. identifier, which that same signature covers (Keynote, Numbers, the App Store Xcode).
    private static let appStore = requirement("anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists")

    private static func requirement(_ text: String) -> SecRequirement? {
        var r: SecRequirement?
        return SecRequirementCreateWithString(text as CFString, [], &r) == errSecSuccess ? r : nil
    }

    static func inspect(pid: pid_t, path: String?) -> SignInfo {
        var out = SignInfo()
        var code: SecCode?
        let attrs = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        var staticCode: SecStaticCode?
        var dynamic = false
        if SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code {
            dynamic = true
            staticCode = unsafeBitCast(code, to: SecStaticCode.self)
            out.valid = SecCodeCheckValidity(code, [], nil) == errSecSuccess
        } else if let path {
            SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode)
        }
        guard let sc = staticCode else { out.error = "no code object"; return out }

        var flags = kSecCSSigningInformation | kSecCSRequirementInformation
        if dynamic { flags |= kSecCSDynamicInformation }
        var infoCF: CFDictionary?
        let rc = SecCodeCopySigningInformation(sc, SecCSFlags(rawValue: flags), &infoCF)
        guard rc == errSecSuccess, let info = infoCF as? [String: Any] else {
            out.error = "SecCodeCopySigningInformation: \(rc)"
            return out
        }
        out.identifier = info[kSecCodeInfoIdentifier as String] as? String
        out.teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
        out.staticFlags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        out.runtimeStatus = (info[kSecCodeInfoStatus as String] as? NSNumber)?.uint32Value
        if let p = info[kSecCodeInfoPlatformIdentifier as String] as? NSNumber, p.intValue != 0 { out.isPlatform = true }
        if let s = out.runtimeStatus, s & 0x0400_0000 != 0 { out.isPlatform = true }
        if let cd = info[kSecCodeInfoUnique as String] as? Data {
            out.cdHash = cd.map { String(format: "%02x", $0) }.joined()
        }
        if out.identifier == nil && info[kSecCodeInfoCertificates as String] == nil && out.cdHash == nil {
            out.unsigned = true
        }
        out.isAdhoc = out.staticFlags & 0x2 != 0
        if let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate] {
            out.authority = certs.compactMap { SecCertificateCopySubjectSummary($0) as String? }
            func satisfies(_ req: SecRequirement?) -> Bool {
                guard let req else { return false }
                if dynamic, let code { return SecCodeCheckValidity(code, [], req) == errSecSuccess }
                // Signature and chain only: hashing every file of a bundle is far too slow per process.
                return SecStaticCodeCheckValidity(sc, SecCSFlags(rawValue: kSecCSDoNotValidateResources
                                                                 | kSecCSDoNotValidateExecutable), req) == errSecSuccess
            }
            out.isAppleSigned = satisfies(anchorApple)
                || (out.identifier?.hasPrefix("com.apple.") == true && satisfies(appStore))
        }
        if let ent = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
            out.entitlementKeys = ent.keys.sorted()
            if let data = try? PropertyListSerialization.data(fromPropertyList: ent, format: .xml, options: 0) {
                out.entitlementsXML = String(decoding: data, as: UTF8.self)
            }
        }
        if let req = info[kSecCodeInfoDesignatedRequirement as String] {
            var text: CFString?
            if SecRequirementCopyString(req as! SecRequirement, [], &text) == errSecSuccess { out.designatedRequirement = text as String? }
        }
        return out
    }
}
