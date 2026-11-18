import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppActivation.install()
        AmbientMonitor.shared.update()
        if !AmbientPrefs.launchesHidden { NSApp.activate(ignoringOtherApps: true) }
    }
    /// A Dock click (or opening the app again) with no window open. SwiftUI opens one itself, except when the
    /// main scene's launch is suppressed ("Start in the menu bar"): then it does nothing, so open it here.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag, AmbientPrefs.launchesHidden, let open = AppRouter.openWindow else { return true }
        AppRouter.openMain(open)
        return false
    }
    /// Files opened with the app (Open With, a Dock drop, `open -a`). SwiftUI takes the first itself (the
    /// Binary scene handles file: URLs) and passes only the others here (measured: 4 files opened, 3 arrive).
    func application(_ application: NSApplication, open urls: [URL]) {
        // After SwiftUI's own window for the first file, which doesn't go through MachOOpen's spacing.
        MachOOpen.holdOpens(0.3)
        for u in urls where u.isFileURL { MachOOpen.openAny(u.path) }
    }
    /// With the menu bar item, closing the last window leaves the app running there.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !AmbientPrefs.menuBarShown }
}

@main
enum Entry {
    static func main() {
        // Same binary serves as the root helper when launchd starts it with --helper.
        if CommandLine.arguments.contains("--helper") { HelperDaemon.run() }
        // Tooltips (full text of truncated fields, mostly) appear at once instead of after AppKit's ~1 s.
        // In milliseconds; 0 counts as unset, so 1. Registered, not set: a user default still wins.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 1])
        AmbientPrefs.register()
        // Inspector windows keep no state: restorationBehavior(.disabled) neither reopens them nor applies a saved
        // frame (each opens at the default size), but AppKit still writes one; cleared here.
        for k in UserDefaults.standard.dictionaryRepresentation().keys
            where k.hasPrefix("NSWindow Frame \(ProcessWindow.id)-AppWindow-") || k.hasPrefix("NSWindow Frame \(MachOWindow.id)-AppWindow-") {
            UserDefaults.standard.removeObject(forKey: k)
        }
        ProcXRayApp.main()
    }
}

struct ProcXRayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var store = Store()
    @AppStorage(AmbientPrefs.showIn) private var showIn: AmbientPrefs.ShowIn = .both
    @AppStorage(AmbientPrefs.launchToMenuBar) private var launchToMenuBar = false
    @AppStorage(SortKeepsGroups.key) private var sortKeepsGroups = false

    init() {
        Section.migrate()
        ColumnPrefs.migrate()
        if CommandLine.arguments.contains("--spawn-leftover") {
            // Test helper: reproduce "app quit but its helper kept running".
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sleep")
            p.arguments = ["120"]
            try? p.run()
            print("spawned leftover sleep pid \(p.processIdentifier) from pid \(getpid())")
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--ambient") {
            // --ambient <seconds> [interval]: the menu bar monitor's sampling, timed, without the UI. Runs off the
            // main thread, which keeps a run loop going so NSWorkspace's app list stays current.
            let a = CommandLine.arguments.dropFirst(i + 1).compactMap(Double.init)
            Thread.detachNewThread {
                AmbientMonitor.bench(seconds: a.first ?? 30, interval: a.count > 1 ? a[1] : 3)
                exit(0)
            }
            RunLoop.main.run()
        }
        if let i = CommandLine.arguments.firstIndex(of: "--counters") {
            // --counters [seconds] [filter] [--json]: every system counter (id, value, change per second), and each
            // source's cost; --json: one reading of everything as JSON (the browser's Export Snapshot).
            let rest = CommandLine.arguments.dropFirst(i + 1).filter { $0 != "--json" }
            let secs = rest.first.flatMap(Double.init)
            CounterEngine.dump(seconds: secs ?? 1, filter: rest.dropFirst(secs == nil ? 0 : 1).first,
                               json: CommandLine.arguments.contains("--json"))
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--groups") {
            // --groups [seconds]: the dropdown's accounting groups, printed.
            let secs = CommandLine.arguments.dropFirst(i + 1).compactMap(Double.init).first ?? 2
            Thread.detachNewThread {
                AmbientMonitor.printGroups(seconds: secs)
                exit(0)
            }
            RunLoop.main.run()
        }
        if let i = CommandLine.arguments.firstIndex(of: "--group-footprint") {
            // --group-footprint [--local] pid…: what the group bubble shows (GroupFootprint), through the helper (or in
            // this process with --local), next to the plain sum of the processes' footprints.
            let a = CommandLine.arguments.dropFirst(i + 1)
            let pids = a.compactMap { Int32($0) }
            let plain = pids.reduce(0.0) { $0 + Double(Native.rusage($1)?.ri_phys_footprint ?? 0) }
            guard let r = GroupFootprint.measure(pids, helper: !a.contains("--local")) else { print("footprint did not run"); exit(1) }
            print("analyzed \(r.analyzed) of \(r.asked) in \(String(format: "%.2f", r.seconds)) s: plain sum \(UInt64(plain)) total \(UInt64(r.total)) shared \(UInt64(r.shared))")
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--filter"), i + 1 < CommandLine.arguments.count {
            exit(Bench.filter(CommandLine.arguments[i + 1]) ? 0 : 1)
        }
        if CommandLine.arguments.contains("--bench-tick") {
            Bench.tickLoop(seconds: 15)
            exit(0)
        }
        if CommandLine.arguments.contains("--bench") {
            Bench.run()
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--rates") {
            Bench.rates(Array(CommandLine.arguments[(i + 1)...]))
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--threads"), i + 1 < CommandLine.arguments.count {
            Bench.threads(pid_t(CommandLine.arguments[i + 1]) ?? 0)
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--qos") {
            Bench.qos(pid_t(CommandLine.arguments[i + 1]) ?? 0)
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--trust-layout"), i + 1 < CommandLine.arguments.count {
            Bench.trustLayout(pid_t(CommandLine.arguments[i + 1]) ?? 0)
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--sandbox") {
            Bench.sandbox(Array(CommandLine.arguments[(i + 1)...]).compactMap { pid_t($0) })
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--net") {
            Bench.net(seconds: CommandLine.arguments.count > i + 1 ? Double(CommandLine.arguments[i + 1]) ?? 20 : 20)
            exit(0)
        }
        if CommandLine.arguments.contains("--extras") {
            Bench.extras(root: CommandLine.arguments.contains("--root"))
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--btm-rule"), i + 1 < CommandLine.arguments.count {
            Bench.btmRule(CommandLine.arguments[i + 1])
            exit(0)
        }
        if CommandLine.arguments.contains("--btm-dump") {
            // Raw `sfltool dumpbtm` as root via the helper, for checking what the records hold.
            print(HelperClient.shared.run(.btmDump) ?? "helper did not answer")
            exit(0)
        }
        if CommandLine.arguments.contains("--tree-stats") {
            Bench.treeStats()
            exit(0)
        }
        if CommandLine.arguments.contains("--shell-test") {
            exit(Bench.shellTest() ? 0 : 1)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--domains") {
            Bench.domains(Array(CommandLine.arguments[(i + 1)...]))
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--peers") {
            Bench.peers(Array(CommandLine.arguments[(i + 1)...]))
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--mach-file") {
            Bench.machFile(Array(CommandLine.arguments[(i + 1)...]))
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--attribution") {
            // --attribution <pid> [launchd label]: the Launch tab's Attribution lines for one process.
            let a = Array(CommandLine.arguments[(i + 1)...])
            guard let pid = a.first.flatMap({ pid_t($0) }) else { print("usage: --attribution <pid> [label]"); exit(2) }
            LaunchMechanism.bench(pid: pid, label: a.count > 1 ? a[1] : nil)
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--launch-watch") {
            // --launch-watch <seconds>: app launch attribution (LaunchWatcher) without the UI.
            LaunchWatcher.bench(seconds: CommandLine.arguments.count > i + 1 ? Double(CommandLine.arguments[i + 1]) ?? 20 : 20)
            exit(0)
        }
        if CommandLine.arguments.contains("--helper-unregister") || CommandLine.arguments.contains("--helper-register") {
            // Run from inside the bundle: SMAppService registers the daemon of the app the binary sits in.
            let register = CommandLine.arguments.contains("--helper-register")
            do {
                if register { try HelperClient.shared.register() } else { try HelperClient.shared.unregister() }
                print(register ? "registered" : "unregistered")
            } catch { print("failed: \(error.localizedDescription)"); exit(1) }
            print(HelperClient.shared.probe().label)
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--helper-call") {
            Bench.helperCall(Array(CommandLine.arguments[(i + 1)...]))
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--bank") {
            // As root: --bank <seconds>. Voucher (BANK) settlements per pair, checked against rusage.
            Bench.bank(seconds: CommandLine.arguments.count > i + 1 ? Double(CommandLine.arguments[i + 1]) ?? 10 : 10)
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--trace") {
            // As root: --trace <pid> <seconds> [--ktrace] [--activity] [out.tsv]. One syscall trace in-process, through
            // the kdebug reader (or ktrace) and the app's decoder; records written as tab-separated text for diffing the
            // two. --activity prints the Activity view's grouping, with Mach message destinations.
            let a = Array(CommandLine.arguments[(i + 1)...]).filter { $0 != "--ktrace" && $0 != "--activity" }
            guard a.count >= 2, let pid = Int32(a[0]), let secs = Double(a[1]) else { print("usage: --trace <pid> <seconds> [--ktrace] [--activity] [out.tsv]"); exit(2) }
            Bench.trace(pid: pid, seconds: secs, ktrace: CommandLine.arguments.contains("--ktrace"),
                        activity: CommandLine.arguments.contains("--activity"), out: a.count > 2 ? a[2] : nil)
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--log-live") {
            // --log-live <pid> <seconds> <out.txt>: the Logs pane's Live session without the UI; writes the
            // lines it kept (history, then streamed), for checking the join against a later `log show`.
            let a = Array(CommandLine.arguments[(i + 1)...])
            guard a.count >= 3, let pid = Int32(a[0]), let secs = Double(a[1]) else { print("usage: --log-live <pid> <seconds> <out.txt>"); exit(2) }
            Bench.logLive(pid: pid, seconds: secs, out: a[2])
            exit(0)
        }
        if CommandLine.arguments.contains("--security") {
            print(SystemSecurity.current.summary)
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--sandbox-rules") {
            // --sandbox-rules <pid|file>: decode a compiled sandbox profile back to SBPL rules. A number is
            // read as a pid (its cached profile); anything else is a path to a compiled profile.
            guard i + 1 < CommandLine.arguments.count else { print("usage: --sandbox-rules <pid|file>"); exit(2) }
            let arg = CommandLine.arguments[i + 1]
            var data: Data?
            if let pid = pid_t(arg) {
                switch SandboxProfileInfo.read(pid: pid) {
                case .success(let info): data = info.profileData
                case .failure(let f): FileHandle.standardError.write(Data("\(SandboxProfileSection.text(f))\n".utf8)); exit(1)
                }
                if data == nil { FileHandle.standardError.write(Data("no cached profile for pid \(pid)\n".utf8)); exit(1) }
            } else {
                data = try? Data(contentsOf: URL(fileURLWithPath: arg))
                if data == nil { FileHandle.standardError.write(Data("couldn't read \(arg)\n".utf8)); exit(1) }
            }
            do {
                guard let rs = try SandboxRules.build(data: data!) else {
                    FileHandle.standardError.write(Data("libsandbox name tables unavailable\n".utf8)); exit(1)
                }
                print("(version 1)")
                print(rs.defaultRule)
                for op in rs.operations { for r in op.rules { print(r) } }
            } catch {
                FileHandle.standardError.write(Data("couldn't decode profile: \(error)\n".utf8)); exit(1)
            }
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--native-vm-regions") {
            guard i + 2 < CommandLine.arguments.count, let pid = pid_t(CommandLine.arguments[i + 1]) else { print("usage: --native-vm-regions <pid> <out.json>"); exit(2) }
            // As root: the raw region walk and image segments, for joining against `vmmap -v`.
            guard let task = NativeVMMap.controlPort(pid) else { print("no task port for \(pid)"); exit(1) }
            let t0 = Date()
            let leaves = NativeVMMap.leaves(task, pid: pid), segs = NativeVMMap.segments(task)
            print(String(format: "%d regions, %d segments in %.0f ms", leaves.count, segs.count, -t0.timeIntervalSinceNow * 1000))
            struct Dump: Codable { var leaves: [NativeVMMap.Leaf]; var segments: [NativeVMMap.Segment] }
            FileManager.default.createFile(atPath: CommandLine.arguments[i + 2], contents: try? JSONEncoder().encode(Dump(leaves: leaves, segments: segs)))
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--native-stacks") {
            guard i + 1 < CommandLine.arguments.count, let pid = pid_t(CommandLine.arguments[i + 1]) else { print("usage: --native-stacks <pid>"); exit(2) }
            print(NativeSample.text(pid) ?? "no task port for \(pid)")
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--native-lsof") {
            // --native-lsof <pid> for the table, --native-lsof all for -F fields of every process.
            guard i + 1 < CommandLine.arguments.count else { print("usage: --native-lsof <pid> | all"); exit(2) }
            let a = CommandLine.arguments[i + 1]
            print((a == "all" ? NativeLsof.fields() : pid_t(a).flatMap { NativeLsof.table($0) }) ?? "needs root")
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--native-taskinfo") {
            guard i + 1 < CommandLine.arguments.count else { print("usage: --native-taskinfo <pid>..."); exit(2) }
            for a in CommandLine.arguments[(i + 1)...] {
                guard let pid = pid_t(a) else { continue }
                print(NativeTaskinfo.text(pid) ?? "no task port for \(pid)")
            }
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--native-vmmap") {
            guard i + 1 < CommandLine.arguments.count, let pid = pid_t(CommandLine.arguments[i + 1]) else { print("usage: --native-vmmap <pid>"); exit(2) }
            print(NativeVMMap.summary(pid, zones: !CommandLine.arguments.contains("--no-zones"),
                                      list: !CommandLine.arguments.contains("--no-list")) ?? "no task port for \(pid)")
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--parse-vmmap") {
            // vmmap output (a file, or - for stdin) through VmmapParser: what the Memory tab gets from it.
            guard i + 1 < CommandLine.arguments.count else { print("usage: --parse-vmmap <file|->"); exit(2) }
            let a = CommandLine.arguments[i + 1]
            let data = a == "-" ? FileHandle.standardInput.readDataToEndOfFile() : (FileManager.default.contents(atPath: a) ?? Data())
            let t0 = Date()
            let s = VmmapParser.parse(String(decoding: data, as: UTF8.self))
            let ms = -t0.timeIntervalSinceNow * 1000
            let sum = { (k: KeyPath<VMMapEntry, UInt64>) in s.entries.reduce(0) { $0 + $1[keyPath: k] } }
            print(String(format: "parsed in %.0f ms: %d regions, %d region types, %d zones, %d files", ms, s.entries.count,
                         s.regions.count, s.zones.count, s.files.count))
            print("list sums: virtual \(sum(\.virtual)) resident \(sum(\.resident)) dirty \(sum(\.dirty)) swapped \(sum(\.swapped))")
            if let t = s.regionTotal { print("TOTAL row: virtual \(t.virtual) resident \(t.resident) dirty \(t.dirty) swapped \(t.swapped) count \(t.count)") }
            for e in s.entries.prefix(3) + s.entries.suffix(3) { print(e) }
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--native-mach") {
            // As root: the native port walk, timed, written in lsmp's JSON shape for diffing against `lsmp -a -j`.
            let t0 = Date()
            guard let procs = NativeMach.processes() else { print("no task ports (needs root and SIP's task_for_pid relaxed)"); exit(1) }
            print(String(format: "native: %d processes in %.0f ms", procs.count, -t0.timeIntervalSinceNow * 1000))
            if i + 1 < CommandLine.arguments.count,
               let d = try? JSONSerialization.data(withJSONObject: ["processes": procs]) {
                FileManager.default.createFile(atPath: CommandLine.arguments[i + 1], contents: d)
            }
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--macho") {
            MachODump.run(Array(CommandLine.arguments.dropFirst(i + 1)))
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--macho-fuzz"), i + 2 < CommandLine.arguments.count {
            MachODump.fuzz(CommandLine.arguments[i + 1], Int(CommandLine.arguments[i + 2]) ?? 1000)
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--macho-corpus"), i + 1 < CommandLine.arguments.count {
            let a = CommandLine.arguments
            MachODump.corpus(a[i + 1], out: i + 2 < a.count ? a[i + 2] : nil)
            exit(0)
        }
        if CommandLine.arguments.contains("--dump") {
            SelfTest.run()
            exit(0)
        }
    }

    private var launchHidden: Bool { showIn != .dock && launchToMenuBar }

    var body: some Scene {
        // The explicit id keeps the saved window frame ("main-AppWindow-1") stable across builds.
        WindowGroup("Proc X-Ray", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 1100, minHeight: 650)
                .background(RestoreWindowScreen(sceneID: "main"))
        }
        .defaultSize(width: 1500, height: 900)
        // Files opened with the app (Open With, a Dock drop, `open -a`) go to the binary inspector's scene.
        .handlesExternalEvents(matching: [])
        // "Start in the menu bar": no window at launch.
        .defaultLaunchBehavior(launchHidden ? .suppressed : .automatic)
        .commands {
            ProcessCommands()
            InspectorTabCommands()
            ColumnsCommands()
            OpenBinaryCommand()
            CommandGroup(after: .toolbar) {
                Button("Refresh Now") { store.refresh() }.keyboardShortcut("r")
                Button(store.paused ? "Resume Updates" : "Pause Updates") { store.paused.toggle() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Toggle("Keep Groups When Sorting", isOn: $sortKeepsGroups)
            }
        }

        // SwiftUI calls the setter with false on every scene update while the item is out; writing the same value
        // back to the defaults re-runs this body, which calls it again: a main-thread loop (hang) in Dock mode.
        MenuBarExtra(isInserted: Binding(get: { showIn != .dock }, set: { if !$0, showIn != .dock { showIn = .dock } })) {
            MenuBarPopover().environment(store)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(store)
        }

        Window("Columns", id: ColumnManager.id) {
            ColumnManager()
        }
        .defaultSize(width: 680, height: 500)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .commandsRemoved()   // opened from View ▸ Columns or the table header's menu

        WindowGroup("Process", id: ProcessWindow.id, for: ProcessRef.self) { $ref in
            if $ref.wrappedValue != nil { ProcessWindow(ref: $ref).environment(store) }
        }
        .defaultSize(width: 900, height: 640)
        .handlesExternalEvents(matching: [])
        .restorationBehavior(.disabled)   // not reopened at launch, no saved frame
        .commandsRemoved()   // no "New Process Window": these only open from a process row

        WindowGroup("Binary", id: MachOWindow.id, for: MachORef.self) { $ref in
            MachOWindow(ref: $ref)   // with no value yet when SwiftUI opens it for a file: onOpenURL fills it in
        }
        .defaultSize(width: 980, height: 720)
        .handlesExternalEvents(matching: ["file:"])
        .restorationBehavior(.disabled)
        .commandsRemoved()   // opened from a path's Inspect button, File ▸ Open Binary…, or a drop
    }
}

/// The Process menu: commands for the selected process of the focused window (the list's selection, or
/// the process an inspector window shows).
struct ProcessCommands: Commands {
    @FocusedValue(\.processTarget) private var target
    @FocusedValue(\.inspectorTab) private var tab
    @AppStorage(InspectorPaneKey.name) private var showPane = false

    var body: some Commands {
        CommandMenu("Process") {
            let p = target?.current()
            Button("Inspect") { target?.inspect?() }
                .keyboardShortcut("i")
                .disabled(target?.inspect == nil || p == nil)
            Button(showPane ? "Hide Inspector Pane" : "Show Inspector Pane") { showPane.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Pick Process by Window…") { WindowPicker.start { AppRouter.shared.show($0) } }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Divider()
            Button("Reveal in Finder") {
                if let path = target?.current()?.path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(p?.path == nil)
            Button("Inspect Binary") {
                if let path = target?.current()?.path, let t = MachOProbe.target(path) { MachOOpen.open(t) }
            }
            .disabled(p?.path == nil)
            Button("Copy PID") { if let p = target?.current() { Self.copy("\(p.pid)") } }
                .disabled(p == nil)
            Button("Copy Path") { if let path = target?.current()?.path { Self.copy(path) } }
                .disabled(p?.path == nil)
            Button("Select Parent") { if let p = target?.current() { target?.select(p.ppid) } }
                .disabled(p.map { $0.ppid == $0.pid || $0.ppid < 0 } ?? true)
            Button("Select Responsible") { if let r = target?.current()?.responsible { target?.select(r) } }
                .disabled(p.flatMap { $0.responsible.map { $0 != p?.pid } } != true)
            Divider()
            Button("Sample") { show(.sample) }.disabled(p == nil)
            Button("Trace Syscalls") { show(.syscalls) }.disabled(p == nil)
            Divider()
            // kernel_task (pid 0): kill(0, …) would signal ProcXRay's own process group.
            let canSignal = (p?.pid ?? 0) > 0
            Button("Terminate…") { signal(SIGTERM, "SIGTERM") }.disabled(!canSignal)
            Button("Kill…") { signal(SIGKILL, "SIGKILL") }.disabled(!canSignal)
            Button("Suspend") { signal(SIGSTOP, "SIGSTOP") }.disabled(!canSignal)
            Button("Resume") { signal(SIGCONT, "SIGCONT") }.disabled(!canSignal)
        }
    }

    private func signal(_ sig: Int32, _ label: String) {
        if let t = target, let p = t.current(), p.pid > 0 { t.signal(p, sig, label) }
    }

    /// Switches the focused inspector to `t`, or opens an inspector on it.
    private func show(_ t: InspectorTab) {
        if let tab { tab.wrappedValue = t; return }
        UserDefaults.standard.set(t.rawValue, forKey: "inspectorTab")
        target?.inspect?()
    }

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// What the Process menu acts on, published by the focused window.
struct ProcessTarget {
    /// The process now, looked up when a command runs.
    let current: () -> ProcInfo?
    /// Opens it in an inspector; nil where it already is one.
    var inspect: (() -> Void)?
    /// Selects (or, in an inspector window, shows) another process.
    let select: (pid_t) -> Void
    /// Sends a signal, confirming the destructive ones first.
    let signal: (ProcInfo, Int32, String) -> Void
}

/// Whether the Processes view shows the selected process in a pane below the list (off: inspector windows only).
enum InspectorPaneKey { static let name = "showInspectorPane" }

struct ProcessTargetKey: FocusedValueKey { typealias Value = ProcessTarget }
struct InspectorTabKey: FocusedValueKey { typealias Value = Binding<InspectorTab> }
extension FocusedValues {
    var inspectorTab: Binding<InspectorTab>? {
        get { self[InspectorTabKey.self] }
        set { self[InspectorTabKey.self] = newValue }
    }
}

/// View ▸ the inspector's tabs, ⌘1 … ⌘0, for the inspector in the focused window.
struct InspectorTabCommands: Commands {
    @FocusedValue(\.inspectorTab) private var tab
    var body: some Commands {
        CommandGroup(after: .sidebar) {
            ForEach(InspectorTab.allCases) { t in
                Button(t.rawValue) { tab?.wrappedValue = t }
                    .keyboardShortcut(t.shortcut)
                    .disabled(tab == nil)
            }
            Divider()
        }
    }
}
extension FocusedValues {
    var processTarget: ProcessTarget? {
        get { self[ProcessTargetKey.self] }
        set { self[ProcessTargetKey.self] = newValue }
    }
}

enum Section: String, CaseIterable, Identifiable {
    case triage = "Triage"
    case processes = "Processes"
    case background = "Background Items"
    case launchd = "launchd Jobs"
    case overview = "Overview"
    case counters = "All Counters"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .triage: "stethoscope"
        case .processes: "cpu"
        case .background: "gearshape.2"
        case .launchd: "bolt.horizontal"
        case .overview: "chart.xyaxis.line"
        case .counters: "gauge.with.dots.needle.33percent"
        }
    }

    /// The sections an earlier version had that are filters of the process list now: open the list with
    /// that filter instead. Runs before any view reads the `section` default.
    static func migrate() {
        let d = UserDefaults.standard
        let old: [String: SavedPredicate] = ["Left Behind": .leftBehind, "LaunchServices Apps": .launchServicesApps]
        guard let raw = d.string(forKey: "section"), let f = old[raw] else { return }
        SavedPredicate.apply(f)
        d.set(Section.processes.rawValue, forKey: "section")
    }
}

/// A sidebar row: a filter of the process list, or one of the other sections.
enum SidebarItem: Hashable {
    case filter(String)
    case section(Section)
}

struct ContentView: View {
    @Environment(Store.self) var store
    @AppStorage("section") private var savedSection: Section = .processes
    @AppStorage("sidebarHidden") private var sidebarHidden = false
    @AppStorage("processes.predicate") private var predicate = ""
    @AppStorage(SavedPredicate.key) private var savedRaw = ""

    private var userFilters: [SavedPredicate] { SavedPredicate.parse(savedRaw) }

    /// The process list shows a filter's row as selected while its predicate is the one in force.
    private var selection: Binding<SidebarItem?> {
        Binding(get: {
            guard savedSection == .processes else { return .section(savedSection) }
            return (SavedPredicate.builtIns + userFilters).first { $0.source == predicate }.map { .filter($0.name) }
        }, set: { item in
            switch item {
            case .section(let s)?: savedSection = s
            case .filter(let name)?:
                savedSection = .processes
                if let f = (SavedPredicate.builtIns + userFilters).first(where: { $0.name == name }) { SavedPredicate.apply(f) }
            case nil: break
            }
        })
    }
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(get: { sidebarHidden ? .detailOnly : .all }, set: { sidebarHidden = $0 == .detailOnly })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            List(selection: selection) {
                SwiftUI.Section("Processes") {
                    ForEach(SavedPredicate.builtIns) { f in filterRow(f, builtIn: true) }
                    ForEach(userFilters) { f in filterRow(f, builtIn: false) }
                    HStack {
                        Label(Section.triage.rawValue, systemImage: Section.triage.icon)
                        Spacer()
                        TriageBadge()
                    }
                    .tag(SidebarItem.section(.triage))
                }
                SwiftUI.Section("System") {
                    Label(Section.overview.rawValue, systemImage: Section.overview.icon).tag(SidebarItem.section(.overview))
                        .help("CPU, memory, power, thermal, storage, network and GPU dashboards built from the system's counters")
                    Label(Section.counters.rawValue, systemImage: Section.counters.icon).tag(SidebarItem.section(.counters))
                        .help("Every system-wide counter macOS exposes: Mach host statistics, sysctl, IOReport and IORegistry statistics")
                }
                SwiftUI.Section("Launch registries") {
                    ForEach([Section.launchd, .background]) { s in
                        Label(s.rawValue, systemImage: s.icon).tag(SidebarItem.section(s))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
            .safeAreaInset(edge: .bottom) {
                StatusLine()
                    .font(.caption).foregroundStyle(.secondary).padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: AppRouter.shared.reveal) { _, r in if r != nil { savedSection = .processes } }
        } detail: {
            switch savedSection {
            case .triage: TriageSection()
            case .processes: ProcessesView()
            case .background: BackgroundItemsView()
            case .launchd: LaunchdView()
            case .overview: SystemOverviewView()
            case .counters: SystemCountersView()
            }
        }
        .modifier(InspectAtLaunch())
        .modifier(KeepOpenWindow())
    }

    @ViewBuilder private func filterRow(_ f: SavedPredicate, builtIn: Bool) -> some View {
        HStack {
            Label(f.name, systemImage: f == .allProcesses ? Section.processes.icon
                  : f == .leftBehind ? "figure.walk.departure" : f == .launchServicesApps ? "app.badge" : "line.3.horizontal.decrease.circle")
            Spacer()
            if f == .leftBehind, store.ghostCount > 0 {
                Text(verbatim: "\(store.ghostCount)").font(.caption).padding(.horizontal, 6)
                    .background(.orange.opacity(0.3), in: Capsule())
            }
        }
        .help(SavedPredicate.tooltips[f.name] ?? (f.source.isEmpty ? "Every process" : f.source))
        .tag(SidebarItem.filter(f.name))
        .contextMenu {
            if !builtIn {
                Button("Delete Filter") { savedRaw = SavedPredicate.encode(userFilters.filter { $0.id != f.id }) }
            }
        }
    }
}

/// `PROCXRAY_INSPECT=<pid or name>` in the environment opens that process's inspector once it's in a snapshot
/// (a name waits for a process of that name to start):
/// for checking an inspector tab without clicking through the UI (the tab is the last one used, the
/// `inspectorTab` default).
private struct InspectAtLaunch: ViewModifier {
    @Environment(Store.self) var store
    @Environment(\.openWindow) private var openWindow
    @State private var done = false

    func body(content: Content) -> some View {
        content.onChange(of: store.procs.count) { _, n in
            guard !done, n > 0, let s = ProcessInfo.processInfo.environment["PROCXRAY_INSPECT"],
                  let p = pid_t(s).flatMap({ store.procs[$0] }) ?? store.procs.values.first(where: { $0.name == s }) else { return }
            done = true
            AppRouter.inspect(ProcessRef(pid: p.pid, start: p.start.timeIntervalSince1970), openWindow)
        }
    }
}

/// The sidebar's one status line: "939 processes · 75 ms · helper root · SIP off". Each part's tooltip has the
/// detail; the helper part opens Settings ▸ Helper. In its own view so that only this line re-renders on
/// every tick.
struct StatusLine: View {
    @Environment(Store.self) var store
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsTab.key) private var settingsTab = SettingsTab.general.rawValue
    private let sec = SystemSecurity.current

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Wraps between parts, never inside one, when the sidebar is narrow.
            FlowLayout(spacing: 0) {
                Text(verbatim: "\(store.procs.count) processes").help("Processes in the last snapshot")
                Text(verbatim: " · \(store.refreshMillis) ms").help("Time the last snapshot took")
                Text(verbatim: " · ")
                Button {
                    settingsTab = SettingsTab.helper.rawValue
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Text(verbatim: helperText).foregroundStyle(store.helperState.isRunning ? Color.secondary : .orange)
                }
                .buttonStyle(.plain)
                .help(store.helperState.label + ". Click for Settings ▸ Helper.")
                if sec.sipRelaxed || sec.amfiDisabled {
                    Text(verbatim: " · " + [sec.sipRelaxed ? "SIP off" : nil, sec.amfiDisabled ? "AMFI off" : nil].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.orange).help(sec.summary)
                }
            }
            if let e = store.refreshError {
                Text(verbatim: "\(e) — showing the last good list").foregroundStyle(.red).lineLimit(3).help("\(e) — showing the last good list")
            }
        }
    }

    private var helperText: String {
        switch store.helperState {
        case .running: "helper root"
        case .notInstalled: "helper: not installed"
        case .needsApproval: "helper: needs approval"
        case .unreachable: "helper: unreachable"
        case .notFound: "helper: missing"
        }
    }
}

/// Settings ▸ Helper: the privileged helper's state and the controls for it.
struct HelperSettings: View {
    @Environment(Store.self) var store

    var body: some View {
        Form {
            SwiftUI.Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(store.helperState.isRunning ? .green : .orange).frame(width: 7, height: 7)
                        Text(verbatim: store.helperState.label).textSelection(.enabled)
                    }
                }
                HStack {
                    switch store.helperState {
                    case .notInstalled:
                        Button("Install Privileged Helper…") { store.installHelper() }
                    case .needsApproval:
                        Button("Open Login Items to Approve") { HelperClient.shared.openLoginItems(); store.probeHelper() }
                        // Starting over when an approval doesn't take. A BTM record left orphaned by a deleted copy of
                        // the app ("record not found" on unregister) only goes with `sfltool resetbtm` and a restart.
                        Button("Uninstall Helper") { store.uninstallHelper() }
                    case .running, .unreachable:
                        // Unreachable: registering again is a no-op, so offer to remove it (launchd may still point
                        // at another copy of the app that took over the registration).
                        Button("Uninstall Helper") { store.uninstallHelper() }
                    case .notFound:
                        EmptyView()
                    }
                    if store.helperState != .needsApproval {
                        Button("Open Login Items") { HelperClient.shared.openLoginItems(); store.probeHelper() }
                    }
                }
                if let e = store.helperError { Text(verbatim: e).foregroundStyle(.red).textSelection(.enabled) }
            }
            SwiftUI.Section {
                Text("""
                    An optional, read-only root daemon (SMAppService) that fills in data for other users' and root-owned \
                    processes, runs a fixed allowlist of tools (lsof, vmmap, sample, launchctl procinfo, sfltool dumpbtm) \
                    with arguments it builds itself, and accepts connections only from this build of the app. Admins can \
                    inspect any process; other users only their own. It exits about 10 s after going idle and launchd \
                    restarts it on demand. macOS asks you to approve it once in Login Items.
                    """)
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { store.probeHelper() }
    }
}
