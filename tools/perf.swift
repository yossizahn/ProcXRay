// Measures a running Proc X-Ray against its resource budgets: the app, its root helper and what they spawn.
//
//   swiftc -O tools/perf.swift -o build/perf && build/perf [--dev | --release | --pid N] [--seconds 60]
//                                                          [--budget open|menubar] [--label TEXT] [--after N]
//
// --dev (default) and --release pick the running bundle of that name; the helper is the root process running the
// same executable. Prints one line per measure with the budget it is held to, and exits 1 when one is over.
// Run it with the app in the state the budget is for: `open` with the main window in front, `menubar` with every
// window closed. What the helper's own children cost isn't readable without root; they are counted, not timed.
// The helper's CPU comes from ps, to 10 ms: measure for a minute or so.
import Darwin
import Foundation

struct Budget { var cpu: Double; var wakeups: Double; var spawnsPerMin: Double; var footprintMB: Double }
let budgets: [String: Budget] = [
    "open": Budget(cpu: 2.0, wakeups: 10, spawnsPerMin: 0, footprintMB: 60),
    "menubar": Budget(cpu: 0.3, wakeups: 1, spawnsPerMin: 0, footprintMB: 60),
]

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let seconds = Double(option("--seconds") ?? "60") ?? 60
let budgetName = option("--budget") ?? "open"
guard let budget = budgets[budgetName] else { print("unknown budget \(budgetName): open or menubar"); exit(2) }
let label = option("--label") ?? ""
// --after N: wait N seconds first, to leave the launch (signatures, launchd domains of every process) out.
if let wait = option("--after").flatMap({ Double($0) }), wait > 0 { Thread.sleep(forTimeInterval: wait) }
let bundle = args.contains("--release") ? "/Proc X-Ray.app/Contents/MacOS/ProcXRay" : "/Proc X-Ray Dev.app/Contents/MacOS/ProcXRay"

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
func nanos(_ t: UInt64) -> Double { Double(t) * Double(timebase.numer) / Double(timebase.denom) }

struct Proc { var pid: pid_t; var ppid: pid_t; var uid: uid_t }
func processes() -> [Proc] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
    size += size / 8
    var buf = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
    guard sysctl(&mib, 4, &buf, &size, nil, 0) == 0 else { return [] }
    return buf.prefix(size / MemoryLayout<kinfo_proc>.stride).map {
        Proc(pid: $0.kp_proc.p_pid, ppid: $0.kp_eproc.e_ppid, uid: $0.kp_eproc.e_ucred.cr_uid)
    }
}
func path(_ pid: pid_t) -> String? {
    var b = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    return proc_pidpath(pid, &b, UInt32(b.count)) > 0 ? String(cString: b) : nil
}

// The app (this user) and its helper (root): both run the bundle's executable.
var appPid: pid_t?, helperPid: pid_t?
if let p = option("--pid").flatMap({ pid_t($0) }) { appPid = p }
for p in processes() where path(p.pid)?.hasSuffix(bundle) == true || p.pid == appPid {
    let exe = path(p.pid)
    if p.uid == 0 { if exe?.hasSuffix(bundle) == true { helperPid = p.pid } } else if appPid == nil { appPid = p.pid }
}
guard let app = appPid else { print("no running \(bundle)"); exit(2) }

struct Usage { var cpu = 0.0, kids = 0.0, energy = 0.0, billed = 0.0, wakeups = 0.0, footprint = 0.0 }
func usage(_ pid: pid_t) -> Usage? {
    var r = rusage_info_v6()
    let ok = withUnsafeMutablePointer(to: &r) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
    }
    guard ok == 0 else { return nil }
    return Usage(cpu: nanos(r.ri_user_time + r.ri_system_time), kids: nanos(r.ri_child_user_time + r.ri_child_system_time),
                 energy: Double(r.ri_energy_nj), billed: Double(r.ri_billed_energy),
                 wakeups: Double(r.ri_interrupt_wkups + r.ri_pkg_idle_wkups), footprint: Double(r.ri_phys_footprint))
}
/// CPU time of the root helper, from ps (setuid root): the kernel gives another user's usage to root only.
func taskCPU(_ pid: pid_t) -> Double? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-o", "time=", "-p", String(pid)]
    let out = Pipe()
    p.standardOutput = out
    guard (try? p.run()) != nil else { return nil }
    p.waitUntilExit()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    // [[dd-]hh:]mm:ss.cc
    var secs = 0.0, unit = 1.0
    for part in text.split(separator: ":").reversed() { guard let v = Double(part) else { return nil }; secs += v * unit; unit *= 60 }
    return text.isEmpty ? nil : secs * 1e9
}

guard let a0 = usage(app) else { print("can't read pid \(app)'s usage (another user's?)"); exit(2) }
let h0 = helperPid.flatMap(taskCPU)
var children: Set<pid_t> = []
var helperRestarted = false
let start = Date()
while -start.timeIntervalSinceNow < seconds {
    for p in processes() where p.ppid == app || (helperPid != nil && p.ppid == helperPid) { children.insert(p.pid) }
    usleep(50_000)
}
let elapsed = -start.timeIntervalSinceNow
guard let a1 = usage(app) else { print("pid \(app) exited"); exit(2) }
let h1 = helperPid.flatMap(taskCPU)
if helperPid != nil, h1 == nil { helperRestarted = true }

func pct(_ ns: Double) -> Double { ns / 1e9 / elapsed * 100 }
let appCPU = pct(a1.cpu - a0.cpu), kidCPU = pct(a1.kids - a0.kids)
let helperCPU = (h0 != nil && h1 != nil) ? pct(h1! - h0!) : 0
let total = appCPU + kidCPU + helperCPU
let wakeups = (a1.wakeups - a0.wakeups) / elapsed
let spawnsPerMin = Double(children.count) / elapsed * 60
let footprintMB = a1.footprint / 1_048_576

var over = false
func line(_ name: String, _ value: String, _ limit: String?, _ ok: Bool?) {
    let verdict = ok.map { $0 ? "ok" : "OVER" } ?? ""
    if ok == false { over = true }
    print(name.padding(toLength: 22, withPad: " ", startingAt: 0) + value.padding(toLength: 14, withPad: " ", startingAt: 0)
          + (limit.map { "budget \($0)" } ?? "").padding(toLength: 18, withPad: " ", startingAt: 0) + verdict)
}
print("Proc X-Ray \(bundle.contains("Dev") ? "Dev" : "release") pid \(app), helper \(helperPid.map(String.init) ?? "none"), \(String(format: "%.0f", elapsed)) s, budget \(budgetName)\(label.isEmpty ? "" : " — \(label)")")
line("total CPU", String(format: "%.2f %%", total), String(format: "%.1f %%", budget.cpu), total <= budget.cpu)
line("  app", String(format: "%.2f %%", appCPU), nil, nil)
line("  spawned tools", String(format: "%.2f %%", kidCPU), nil, nil)
line("  helper", helperPid == nil ? "–" : String(format: "%.2f %%", helperCPU), nil, nil)
line("wake-ups", String(format: "%.1f /s", wakeups), String(format: "%.0f /s", budget.wakeups), wakeups <= budget.wakeups)
line("tools spawned", String(format: "%.1f /min", spawnsPerMin), String(format: "%.0f /min", budget.spawnsPerMin), spawnsPerMin <= budget.spawnsPerMin)
line("footprint", String(format: "%.0f MB", footprintMB), String(format: "%.0f MB", budget.footprintMB), footprintMB <= budget.footprintMB)
line("app power", String(format: "%.0f mW", (a1.energy - a0.energy) / 1e6 / elapsed), nil, nil)
line("  billed to it", String(format: "%.0f mW", (a1.billed - a0.billed) / 1e6 / elapsed), nil, nil)
if helperRestarted { print("note: the helper exited during the run; its CPU isn't counted") }
exit(over ? 1 : 0)
