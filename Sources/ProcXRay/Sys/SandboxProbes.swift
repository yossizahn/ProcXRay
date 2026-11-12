import Foundation
import CSandbox

/// What a sandboxed process may do, asked of the kernel with sandbox_check(pid, operation, filter, argument).
/// The answer is the profile as it stands now, so it includes folders the user granted the app after launch
/// (Open panel, drag and drop). Works without root, for other users' processes too. ~4–6 µs per check.
///
/// Measured limits that shape the list:
/// - A path that doesn't exist reads as denied even for an unsandboxed process, so file checks use folders
///   that exist, and a missing one is reported unknown.
/// - Network can't be asked this way: with no filter, network-outbound reads denied even for apps holding
///   com.apple.security.network.client (their rule allows only some destinations), and no filter type tried
///   gave a usable answer. The UI takes network from the entitlements instead and says so.
enum SandboxProbes {
    enum Verdict { case allowed, denied, unknown }

    /// sandbox_check filter types used here (libsandbox's enum sandbox_filter_type).
    private enum Filter: Int32 { case none = 0, path = 1, globalName = 2, appleEventDestination = 4, preferenceDomain = 6 }

    struct Location: Identifiable {
        let id: String           // label
        let path: String?        // resolved, nil if it doesn't exist
        var read: Verdict = .unknown
        var write: Verdict = .unknown
    }

    struct Capability: Identifiable {
        let id: String           // label
        let detail: String       // operation and argument, for the tooltip
        var verdict: Verdict = .unknown
    }

    struct Report {
        var locations: [Location]
        var capabilities: [Capability]
    }

    private static let home = NSHomeDirectory()

    private static let locationSpecs: [(String, String)] = [
        ("Home folder", home),
        ("Documents", home + "/Documents"),
        ("Desktop", home + "/Desktop"),
        ("Downloads", home + "/Downloads"),
        ("Pictures", home + "/Pictures"),
        ("~/.ssh", home + "/.ssh"),
        ("~/Library/Mail", home + "/Library/Mail"),
        ("/Applications", "/Applications"),
        ("/Volumes", "/Volumes"),
        ("/tmp", "/tmp"),
    ]

    private static let capabilitySpecs: [(String, String, Filter, String?)] = [
        ("Start child processes", "process-fork", .none, nil),
        ("Run programs", "process-exec*", .path, "/bin/sh"),
        ("Camera", "device-camera", .none, nil),
        ("Microphone", "device-microphone", .none, nil),
        ("Clipboard", "mach-lookup", .globalName, "com.apple.pasteboard.1"),
        ("Send Apple events to Finder", "appleevent-send", .appleEventDestination, "com.apple.finder"),
        ("Read other apps' preferences", "user-preference-read", .preferenceDomain, "com.apple.finder"),
    ]

    /// nil when the process is gone (or its pid was reused) by the time the checks finish.
    static func run(pid: pid_t, start: Date) -> Report? {
        let locations: [Location] = locationSpecs.map { label, path in
            // Resolve symlinks (/tmp → /private/tmp): rules match the real path.
            let real = realpath(path, nil).map { p in defer { free(p) }; return String(cString: p) }
            var l = Location(id: label, path: real)
            if let real {
                l.read = check(pid, "file-read-data", .path, real)
                l.write = check(pid, "file-write-data", .path, real)
            }
            return l
        }
        let capabilities: [Capability] = capabilitySpecs.map { label, op, filter, arg in
            Capability(id: label, detail: arg.map { "\(op) \($0)" } ?? op, verdict: check(pid, op, filter, arg))
        }
        // sandbox_check answers for whatever process has the pid now.
        guard Native.isSame(pid, start: start) else { return nil }
        return Report(locations: locations, capabilities: capabilities)
    }

    private static func check(_ pid: pid_t, _ op: String, _ filter: Filter, _ arg: String?) -> Verdict {
        switch pxr_sandbox_check(pid, op, filter.rawValue, arg) {
        case 0: .allowed
        case 1: .denied
        default: .unknown
        }
    }
}
