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

    init() {
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
            // --attribution <pid> [launchd label]: the Origin tab's Attribution lines for one process.
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
            // As root: --trace <pid> <seconds> [--ktrace] [out.tsv]. One syscall trace in-process, through the kdebug
            // reader (or ktrace) and the app's decoder; records written as tab-separated text for diffing the two.
            let a = Array(CommandLine.arguments[(i + 1)...]).filter { $0 != "--ktrace" }
            guard a.count >= 2, let pid = Int32(a[0]), let secs = Double(a[1]) else { print("usage: --trace <pid> <seconds> [--ktrace] [out.tsv]"); exit(2) }
            Bench.trace(pid: pid, seconds: secs, ktrace: CommandLine.arguments.contains("--ktrace"), out: a.count > 2 ? a[2] : nil)
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
            print(NativeVMMap.summary(pid, zones: !CommandLine.arguments.contains("--no-zones")) ?? "no task port for \(pid)")
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
            InspectCommand()
            ColumnsCommands()
            OpenBinaryCommand()
            CommandGroup(after: .toolbar) {
                Button("Refresh Now") { store.refresh() }.keyboardShortcut("r")
                Button(store.paused ? "Resume Updates" : "Pause Updates") { store.paused.toggle() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Pick Process by Window…") { WindowPicker.start { AppRouter.shared.show($0) } }
                    .keyboardShortcut("p", modifiers: [.command, .option])
            }
        }

        MenuBarExtra(isInserted: Binding(get: { showIn != .dock }, set: { if !$0 { showIn = .dock } })) {
            MenuBarPopover().environment(store)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }

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

/// View ▸ Inspect Process (⌘I), as in Activity Monitor; acts on the selected row of the focused window.
struct InspectCommand: Commands {
    @FocusedValue(\.inspectProcess) private var inspect
    @AppStorage(InspectorPaneKey.name) private var showPane = false
    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button("Inspect Process") { inspect?() }
                .keyboardShortcut("i")
                .disabled(inspect == nil)
            Button(showPane ? "Hide Inspector Pane" : "Show Inspector Pane") { showPane.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
        }
    }
}

/// Whether the Processes view shows the selected process in a pane below the list (off: inspector windows only).
enum InspectorPaneKey { static let name = "showInspectorPane" }

struct InspectProcessKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    var inspectProcess: (() -> Void)? {
        get { self[InspectProcessKey.self] }
        set { self[InspectProcessKey.self] = newValue }
    }
}

enum Section: String, CaseIterable, Identifiable {
    case triage = "Triage"
    case processes = "Processes"
    case ghosts = "Left Behind"
    case apps = "LaunchServices Apps"
    case background = "Background Items"
    case launchd = "launchd Jobs"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .triage: "stethoscope"
        case .processes: "cpu"
        case .ghosts: "figure.walk.departure"
        case .apps: "app.badge"
        case .background: "gearshape.2"
        case .launchd: "bolt.horizontal"
        }
    }
}

struct ContentView: View {
    @Environment(Store.self) var store
    @AppStorage("section") private var savedSection: Section = .processes
    @AppStorage("sidebarHidden") private var sidebarHidden = false

    private var section: Binding<Section?> {
        Binding(get: { savedSection }, set: { if let s = $0 { savedSection = s } })
    }
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(get: { sidebarHidden ? .detailOnly : .all }, set: { sidebarHidden = $0 == .detailOnly })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            List(Section.allCases, selection: section) { s in
                HStack {
                    Label(s.rawValue, systemImage: s.icon)
                    Spacer()
                    if s == .triage { TriageBadge() }
                    if s == .ghosts, store.ghostCount > 0 {
                        Text(verbatim: "\(store.ghostCount)").font(.caption).padding(.horizontal, 6)
                            .background(.orange.opacity(0.3), in: Capsule())
                    }
                }.tag(s)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    SecurityBadge()
                    HelperBadge()
                    RefreshStats()
                }
                .font(.caption).foregroundStyle(.secondary).padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: AppRouter.shared.reveal) { _, r in if r != nil { savedSection = .processes } }
        } detail: {
            switch savedSection {
            case .triage: TriageSection()
            case .processes: ProcessesView()
            case .ghosts: GhostsView()
            case .apps: AppsView()
            case .background: BackgroundItemsView()
            case .launchd: LaunchdView()
            }
        }
        .modifier(InspectAtLaunch())
        .modifier(KeepOpenWindow())
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

/// Per-refresh numbers, in their own view so that only this text re-renders on every tick.
struct RefreshStats: View {
    @Environment(Store.self) var store
    var body: some View {
        Text(verbatim: "\(store.procs.count) processes")
        Text(verbatim: "snapshot \(store.refreshMillis) ms")
        if let e = store.refreshError {
            Text(verbatim: "\(e) — showing the last good list").foregroundStyle(.red).lineLimit(3).help("\(e) — showing the last good list")
        }
    }
}

/// Shown only when SIP or AMFI is relaxed, since that is when the extra features apply.
struct SecurityBadge: View {
    private let sec = SystemSecurity.current
    var body: some View {
        if sec.sipRelaxed || sec.amfiDisabled {
            let text = [sec.sipRelaxed ? "SIP disabled" : nil, sec.amfiDisabled ? "AMFI off" : nil].compactMap { $0 }.joined(separator: " · ")
            HStack(spacing: 4) {
                Image(systemName: "shield.slash").foregroundStyle(.orange)
                Text(verbatim: text)
            }
            .help(sec.summary)
            .padding(.bottom, 4)
        }
    }
}

struct HelperBadge: View {
    @Environment(Store.self) var store

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle().fill(store.helperState.isRunning ? .green : .orange).frame(width: 7, height: 7)
                Text(verbatim: store.helperState.label).lineLimit(2).help(store.helperState.label)
            }
            switch store.helperState {
            case .notInstalled:
                Button("Install Privileged Helper…") { store.installHelper() }
                    .help("Registers a root daemon (SMAppService) for reading other users' processes. macOS asks you to approve it once in Login Items.")
            case .unreachable:
                // Registered but not answering. Registering again is a no-op, so offer to remove it instead;
                // e.g. launchd may still point at another copy of the app that took over the registration.
                Button("Uninstall Helper") { store.uninstallHelper() }
                    .help("Removes the helper's registration so it can be installed again from this copy of the app.")
            case .needsApproval:
                Button("Open Login Items to Approve") { HelperClient.shared.openLoginItems(); store.probeHelper() }
            case .running:
                Button("Uninstall Helper") { store.uninstallHelper() }
            case .notFound:
                EmptyView()
            }
            if let e = store.helperError { Text(verbatim: e).foregroundStyle(.red).lineLimit(3).help(e) }
        }
        .padding(.bottom, 4)
    }
}
