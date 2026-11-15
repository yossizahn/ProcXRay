import Foundation
import CSandbox

/// The profile an App Sandbox process was built with, from the copy secinitd keeps next to its container.
///
/// When an App Sandbox app launches, secinitd compiles its profile from the system's `.sb` sources, the app's
/// entitlements and a set of parameters (container path, home, temp dirs), and caches the result with those
/// inputs in the container's `.com.apple.containermanagerd.metadata.plist` (`SandboxProfileData` plus
/// `SandboxProfileDataValidationInfo`). That cache is what this reads.
///
/// Measured on macOS 27.2: the kernel won't hand a process's profile to anyone outside Apple
/// (`sandbox_inspect_pid` → EPERM as root, from a platform binary, with SIP and AMFI off), so this cache is the
/// only readable source. It covers apps with a container; daemons using a named system profile have none
/// (`sandbox_container_path_for_pid` → EPERM), and unsandboxed processes give ENOTSUP.
/// Folders the user grants later (Open panel, drag and drop) are extensions on top, not in the cache.
///
/// The metadata file is privacy-protected: measured in a stock VM (SIP on), an app without Full Disk Access gets
/// EPERM for every container's metadata, with no prompt; with Full Disk Access it reads.
struct SandboxProfileInfo {
    struct SourceFile: Identifiable {
        let path: String
        /// The file's modification date when the profile was compiled, and now (nil if it's gone).
        let compiledDate: Date?
        let currentDate: Date?
        var id: String { path }
        /// The file changed after the cached profile was built from it.
        var changed: Bool {
            guard let c = compiledDate else { return false }
            guard let n = currentDate else { return true }
            return abs(n.timeIntervalSince(c)) > 1
        }
    }

    let containerPath: String       // …/Containers/<id>/Data
    let metadataPath: String
    let compiledSize: Int?
    let profileData: Data?          // the compiled profile bytes, for decoding its rules
    let sources: [SourceFile]
    let parameters: [(String, String)]
    let entitlementCount: Int
    let systemImages: [String]      // frameworks whose sandbox snippets were included
    let redirectedPaths: [String]
    let buildID: String?            // libsandbox build the profile was compiled with
    let currentBuildID: String?

    var compiledByOtherBuild: Bool { buildID != nil && currentBuildID != nil && buildID != currentBuildID }

    enum Failure: Error {
        case notSandboxed           // ENOTSUP
        case noContainer            // sandboxed, but not with a container (named profile, inherited, sandbox-exec)
        case needsFullDiskAccess(String)  // EPERM: privacy-protected, Proc X-Ray lacks Full Disk Access
        case unreadable(String)     // the metadata couldn't be read
        case noCache(String)        // read, but it has no cached profile
    }

    static func read(pid: pid_t) -> Result<SandboxProfileInfo, Failure> {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        errno = 0
        if sandbox_container_path_for_pid(pid, &buf, buf.count) != 0 {
            return .failure(errno == ENOTSUP ? .notSandboxed : .noContainer)
        }
        let container = String(cString: buf)
        let meta = ((container as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
        let fd = open(meta, O_RDONLY)
        guard fd >= 0 else { return .failure(errno == EPERM || errno == EACCES ? .needsFullDiskAccess(meta) : .unreadable(meta)) }
        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: true).readDataToEndOfFile()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let info = plist["MCMMetadataInfo"] as? [String: Any] else {
            return .failure(.unreadable(meta))
        }
        guard let v = info["SandboxProfileDataValidationInfo"] as? [String: Any] else {
            return .failure(.noCache(meta))
        }
        let sources: [SourceFile] = (v["SystemProfiles"] as? [[String: Any]] ?? []).compactMap { s in
            guard let p = s["AppSandboxProfileSnippetPathKey"] as? String else { return nil }
            let now = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date
            return SourceFile(path: p, compiledDate: s["AppSandboxProfileSnippetModificationDateKey"] as? Date, currentDate: now)
        }
        let params = (v["Parameters"] as? [String: Any] ?? [:])
            .map { ($0.key, "\($0.value)") }
            .sorted { $0.0 < $1.0 }
        let profileData = info["SandboxProfileData"] as? Data
        return .success(SandboxProfileInfo(
            containerPath: container,
            metadataPath: meta,
            compiledSize: profileData?.count,
            profileData: profileData,
            sources: sources,
            parameters: params,
            entitlementCount: (v["Entitlements"] as? [String: Any])?.count ?? 0,
            systemImages: (v["SystemImages"] as? [String] ?? []).sorted(),
            redirectedPaths: v["RedirectedPaths"] as? [String] ?? [],
            buildID: v["Sandbox_Build_UUID"] as? String,
            currentBuildID: currentBuild))
    }

    /// libsandbox's exported SANDBOX_BUILD_ID (a `const char *`), the same UUID the cache records.
    private static let currentBuild: String? = {
        guard let h = dlopen("/usr/lib/libsandbox.1.dylib", RTLD_LAZY | RTLD_NOLOAD) ?? dlopen("/usr/lib/libsandbox.1.dylib", RTLD_LAZY),
              let sym = dlsym(h, "SANDBOX_BUILD_ID") else { return nil }
        return sym.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee.map { String(cString: $0) }
    }()

    /// What the common parameters mean, for the tooltip.
    static func describe(param: String) -> String? {
        [
            "_HOME": "home folder",
            "_UID": "user ID",
            "_USER": "user name",
            "application_bundle": "the app bundle",
            "application_bundle_id": "bundle identifier",
            "application_container": "the app's container (its home inside the sandbox)",
            "application_container_id": "container identifier",
            "application_darwin_temp_dir": "per-app temporary folder",
            "application_darwin_cache_dir": "per-app cache folder",
            "application_darwin_user_dir": "per-app user folder",
            "application_addressbook_lock_dir": "Contacts lock folder",
        ][param]
    }
}
