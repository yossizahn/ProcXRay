import Darwin

/// Dirty tracking (proc_get_dirty, <sys/proc_info.h>): whether launchd, or an app through sudden termination,
/// lets the kernel stop the process when it's idle, and whether it's busy ("dirty") right now. Readable for
/// every process without privileges (807 of 807 here). Not tracked: the call answers 0.
struct IdleExitState: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt32
    static let tracked = IdleExitState(rawValue: UInt32(PROC_DIRTY_TRACKED))
    static let allowsIdleExit = IdleExitState(rawValue: UInt32(PROC_DIRTY_ALLOWS_IDLE_EXIT))
    static let dirty = IdleExitState(rawValue: UInt32(PROC_DIRTY_IS_DIRTY))
    static let launchInProgress = IdleExitState(rawValue: UInt32(PROC_DIRTY_LAUNCH_IS_IN_PROGRESS))

    static func read(_ pid: pid_t) -> IdleExitState? {
        var f: UInt32 = 0
        return proc_get_dirty(pid, &f) == 0 ? IdleExitState(rawValue: f) : nil
    }

    /// For the column: empty when not tracked.
    var short: String {
        guard contains(.tracked) else { return "" }
        if contains(.launchInProgress) { return "launching" }
        return (contains(.allowsIdleExit) ? "can exit" : "tracked") + (contains(.dirty) ? " · busy" : " · clean")
    }

    var long: String {
        guard contains(.tracked) else { return "Not tracked: nothing stops it for being idle." }
        var s = contains(.allowsIdleExit)
            ? "Tracked, and may be stopped when idle (launchd's EnablePressuredExit, or an app's sudden termination)"
            : "Tracked, but not stopped for being idle"
        s += contains(.dirty) ? ". Busy now (dirty), so it's kept." : ". Clean now" + (contains(.allowsIdleExit) ? ", so it can be stopped." : ".")
        if contains(.launchInProgress) { s += " Still launching." }
        return s
    }
}
