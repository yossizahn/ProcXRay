import AppKit
import Darwin

/// Whether WindowServer considers an app hung: the "Not Responding" state Activity Monitor and the Force Quit
/// window show. SkyLight's `SLSEventIsAppUnresponsive` (private, loaded at run time) answers per process serial
/// number; `GetProcessForPID` (deprecated, also loaded at run time) maps a pid to one. Only processes registered
/// with LaunchServices have a serial number, so the callers pass apps only.
///
/// WindowServer decides on its own schedule: an app whose main thread stopped was reported unresponsive ~18 s
/// later with no events sent to it (measured with a test app that sleeps on its main thread). Each check is
/// ~0.1 ms, sometimes a few ms when WindowServer is busy, so it runs off the main thread.
enum Responsiveness {
    private typealias ConnFn = @convention(c) () -> Int32
    private typealias UnresponsiveFn = @convention(c) (Int32, UnsafePointer<ProcessSerialNumber>) -> Bool
    private typealias PSNFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    private struct API: @unchecked Sendable {
        let connection: Int32
        let unresponsive: UnresponsiveFn
        let psn: PSNFn
    }

    private static let api: API? = {
        guard let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let hi = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
              let conn = dlsym(sky, "SLSMainConnectionID"),
              let unresp = dlsym(sky, "SLSEventIsAppUnresponsive"),
              let psn = dlsym(hi, "GetProcessForPID") else { return nil }
        return API(connection: unsafeBitCast(conn, to: ConnFn.self)(),
                   unresponsive: unsafeBitCast(unresp, to: UnresponsiveFn.self),
                   psn: unsafeBitCast(psn, to: PSNFn.self))
    }()

    static var available: Bool { api != nil }

    /// Each app's last answer and when it was given, for `maxAge`.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var last: [pid_t: (at: UInt64, hung: Bool)] = [:]

    /// The pids among `pids` that WindowServer reports as not responding. Each pid is a round trip to
    /// WindowServer (a third of a refresh's wall time, measured), and an app counts as hung only after ~18 s, so
    /// an app's answer is given again for `maxAge` seconds: the process list and the menu bar monitor, which
    /// both ask on their own timers, share it.
    static func unresponsive(_ pids: some Sequence<pid_t>, maxAge: Double = 5) -> Set<pid_t> {
        guard let api else { return [] }
        let now = DispatchTime.now().uptimeNanoseconds
        let fresh = UInt64(maxAge * 1e9)
        lock.lock()
        let known = last
        lock.unlock()
        var out: Set<pid_t> = []
        var asked: [pid_t: (at: UInt64, hung: Bool)] = [:]
        for pid in pids where pid > 0 {
            if let k = known[pid], now &- k.at <= fresh {
                if k.hung { out.insert(pid) }
                continue
            }
            var psn = ProcessSerialNumber()
            guard api.psn(pid, &psn) == noErr else { continue }
            let hung = api.unresponsive(api.connection, &psn)
            if hung { out.insert(pid) }
            asked[pid] = (now, hung)
        }
        if !asked.isEmpty {
            lock.lock()
            // Forget apps not asked about for a while (they have quit).
            last = last.filter { now &- $0.value.at <= fresh * 12 }
            last.merge(asked) { _, b in b }
            lock.unlock()
        }
        return out
    }

    /// LaunchServices types that can own windows: regular apps and agents (no Dock icon).
    static func isCandidate(lsType: String?) -> Bool { lsType == "Foreground" || lsType == "UIElement" }
}
