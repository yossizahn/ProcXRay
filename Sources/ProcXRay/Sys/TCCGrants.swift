import Foundation
import SQLite3

/// Privacy & Security (TCC) decisions recorded for an app, read from TCC's databases.
///
/// TCC files a decision under the app *responsible* for a process (its bundle ID, or its path for a bare
/// executable), so the lookup is by that app, not by the process.
///
/// Two databases, measured on macOS 27.2:
/// - /Library/Application Support/com.apple.TCC/TCC.db (system-wide: Full Disk Access, Accessibility, Screen
///   Recording, Input Monitoring, …) is readable by any user, no Full Disk Access needed.
/// - ~/Library/Application Support/com.apple.TCC/TCC.db (per user: camera, microphone, contacts, photos, files
///   and folders, automation) opens only with Full Disk Access, even as root.
/// Entitlements Apple builds into its own binaries (com.apple.private.tcc.allow) grant services without a row.
enum TCCGrants {
    struct Grant: Identifiable {
        let service: String         // kTCCService…
        let client: String
        let clientIsPath: Bool
        let authValue: Int          // 0 denied, 1 unknown, 2 allowed, 3 limited
        let authReason: Int
        let target: String?         // indirect object: the app Apple events are sent to
        let modified: Date?
        let database: Database
        var id: String { "\(database)|\(service)|\(client)|\(target ?? "")" }
    }

    enum Database: String { case system = "system", user = "user" }

    enum Availability { case read, needsFullDiskAccess, missing, failed(String) }

    struct Report {
        var grants: [Grant]
        var system: Availability
        var user: Availability
    }

    static let systemPath = "/Library/Application Support/com.apple.TCC/TCC.db"
    static var userPath: String { NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db" }

    /// Decisions for any of `clients` (bundle IDs and executable paths).
    static func read(clients: Set<String>) -> Report {
        var grants: [Grant] = []
        let sys = query(systemPath, .system, clients, into: &grants)
        let usr = query(userPath, .user, clients, into: &grants)
        grants.sort { ($0.database.rawValue, displayName($0.service)) < ($1.database.rawValue, displayName($1.service)) }
        return Report(grants: grants, system: sys, user: usr)
    }

    private static func query(_ path: String, _ db: Database, _ clients: Set<String>, into out: inout [Grant]) -> Availability {
        guard FileManager.default.fileExists(atPath: path) else {
            // The user database's folder is TCC-protected too: without Full Disk Access it can look absent.
            return db == .user ? .needsFullDiskAccess : .missing
        }
        var h: OpaquePointer?
        let uri = "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) + "?mode=ro"
        guard sqlite3_open_v2(uri, &h, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let h else {
            sqlite3_close(h)
            return .needsFullDiskAccess
        }
        defer { sqlite3_close(h) }
        let sql = "SELECT service, client, client_type, auth_value, auth_reason, indirect_object_identifier, last_modified FROM access"
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &st, nil) == SQLITE_OK, let st else {
            let msg = String(cString: sqlite3_errmsg(h))
            // Opening succeeds lazily; the first read is where a missing Full Disk Access shows up.
            return msg.contains("authoriz") || msg.contains("unable to open") ? .needsFullDiskAccess : .failed(msg)
        }
        defer { sqlite3_finalize(st) }
        func text(_ i: Int32) -> String? { sqlite3_column_text(st, i).map { String(cString: $0) } }
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { return .failed(String(cString: sqlite3_errmsg(h))) }
            guard let client = text(1), clients.contains(client), let service = text(0) else { continue }
            let target = text(5).flatMap { $0 == "UNUSED" ? nil : $0 }
            let mod = sqlite3_column_int64(st, 6)
            out.append(Grant(service: service, client: client, clientIsPath: sqlite3_column_int(st, 2) == 1,
                             authValue: Int(sqlite3_column_int(st, 3)), authReason: Int(sqlite3_column_int(st, 4)),
                             target: target, modified: mod > 0 ? Date(timeIntervalSince1970: TimeInterval(mod)) : nil,
                             database: db))
        }
        return .read
    }

    /// The services an Apple binary is entitled to without asking (com.apple.private.tcc.allow and .overridable).
    static func builtIn(_ entitlements: [String: Any]) -> [(service: String, overridable: Bool)] {
        let fixed = (entitlements["com.apple.private.tcc.allow"] as? [String] ?? []).map { ($0, false) }
        let over = (entitlements["com.apple.private.tcc.allow.overridable"] as? [String] ?? []).map { ($0, true) }
        return (fixed + over).sorted { displayName($0.0) < displayName($1.0) }.map { (service: $0.0, overridable: $0.1) }
    }

    static func decision(_ v: Int) -> String {
        switch v {
        case 0: "denied"
        case 2: "allowed"
        case 3: "limited"
        default: "undecided"
        }
    }

    /// auth_reason, by TCC's own names for the codes (a toggle flipped in System Settings records System Set).
    static func reason(_ r: Int) -> String {
        let names = [1: "Error", 2: "User Consent", 3: "User Set", 4: "System Set", 5: "Service Policy", 6: "MDM Policy",
                     7: "Override Policy", 8: "Missing usage string", 9: "Prompt Timeout", 10: "Preflight Unknown",
                     11: "Entitled", 12: "App Type Policy"]
        return "\(names[r] ?? "reason") (\(r))"
    }

    /// The name Privacy & Security shows for a service.
    static func displayName(_ s: String) -> String {
        let names: [String: String] = [
            "kTCCServiceAccessibility": "Accessibility",
            "kTCCServicePostEvent": "Accessibility (sending input events)",
            "kTCCServiceListenEvent": "Input Monitoring",
            "kTCCServiceScreenCapture": "Screen & System Audio Recording",
            "kTCCServiceSystemPolicyAllFiles": "Full Disk Access",
            "kTCCServiceSystemPolicySysAdminFiles": "Administrator files",
            "kTCCServiceDeveloperTool": "Developer Tools",
            "kTCCServiceEndpointSecurityClient": "Endpoint Security",
            "kTCCServiceCamera": "Camera",
            "kTCCServiceMicrophone": "Microphone",
            "kTCCServiceAddressBook": "Contacts",
            "kTCCServiceCalendar": "Calendars",
            "kTCCServiceReminders": "Reminders",
            "kTCCServicePhotos": "Photos",
            "kTCCServicePhotosAdd": "Photos (add only)",
            "kTCCServiceMediaLibrary": "Media & Apple Music",
            "kTCCServiceSpeechRecognition": "Speech Recognition",
            "kTCCServiceAppleEvents": "Automation",
            "kTCCServiceSystemPolicyDesktopFolder": "Desktop Folder",
            "kTCCServiceSystemPolicyDocumentsFolder": "Documents Folder",
            "kTCCServiceSystemPolicyDownloadsFolder": "Downloads Folder",
            "kTCCServiceSystemPolicyNetworkVolumes": "Network Volumes",
            "kTCCServiceSystemPolicyRemovableVolumes": "Removable Volumes",
            "kTCCServiceSystemPolicyAppBundles": "App Management",
            "kTCCServiceSystemPolicyAppData": "Other apps' data",
            "kTCCServiceFileProviderDomain": "File Provider",
            "kTCCServiceFileProviderPresence": "File Provider presence",
            "kTCCServiceBluetoothAlways": "Bluetooth",
            "kTCCServiceUserTracking": "Tracking",
            "kTCCServiceWillow": "Home",
            "kTCCServiceFocusStatus": "Focus",
        ]
        if let n = names[s] { return n }
        return s.hasPrefix("kTCCService") ? String(s.dropFirst("kTCCService".count)) : s
    }
}
