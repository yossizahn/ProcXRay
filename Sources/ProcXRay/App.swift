import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
enum Entry {
    static func main() {
        // Same binary serves as the root helper when launchd starts it with --helper.
        if CommandLine.arguments.contains("--helper") { HelperDaemon.run() }
        ProcXRayApp.main()
    }
}

struct ProcXRayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var store = Store()

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
        if CommandLine.arguments.contains("--bench") {
            Bench.run()
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--rates") {
            Bench.rates(Array(CommandLine.arguments[(i + 1)...]))
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--qos") {
            Bench.qos(pid_t(CommandLine.arguments[i + 1]) ?? 0)
            exit(0)
        }
        if CommandLine.arguments.contains("--extras") {
            Bench.extras(root: CommandLine.arguments.contains("--root"))
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
        if let i = CommandLine.arguments.firstIndex(of: "--helper-call") {
            Bench.helperCall(Array(CommandLine.arguments[(i + 1)...]))
            exit(0)
        }
        if CommandLine.arguments.contains("--dump") {
            SelfTest.run()
            exit(0)
        }
    }

    var body: some Scene {
        // The explicit id keeps the saved window frame ("main-AppWindow-1") stable across builds.
        WindowGroup("Proc X-Ray", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 1100, minHeight: 650)
                .background(RestoreWindowScreen(sceneID: "main"))
        }
        .defaultSize(width: 1500, height: 900)
        .commands {
            InspectCommand()
            ColumnsCommands()
            CommandGroup(after: .toolbar) {
                Button("Refresh Now") { store.refresh() }.keyboardShortcut("r")
                Button(store.paused ? "Resume Updates" : "Pause Updates") { store.paused.toggle() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }

        WindowGroup("Process", id: ProcessWindow.id, for: ProcessRef.self) { $ref in
            if $ref.wrappedValue != nil { ProcessWindow(ref: $ref).environment(store) }
        }
        .defaultSize(width: 900, height: 640)
        .commandsRemoved()   // no "New Process Window": these only open from a process row
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
    case processes = "Processes"
    case ghosts = "Left Behind"
    case apps = "LaunchServices Apps"
    case background = "Background Items"
    case launchd = "launchd Jobs"
    var id: String { rawValue }
    var icon: String {
        switch self {
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
                    if s == .ghosts, store.ghostCount > 0 {
                        Text(verbatim: "\(store.ghostCount)").font(.caption).padding(.horizontal, 6)
                            .background(.orange.opacity(0.3), in: Capsule())
                    }
                }.tag(s)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    HelperBadge()
                    RefreshStats()
                }
                .font(.caption).foregroundStyle(.secondary).padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            switch savedSection {
            case .processes: ProcessesView()
            case .ghosts: GhostsView()
            case .apps: AppsView()
            case .background: BackgroundItemsView()
            case .launchd: LaunchdView()
            }
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
            Text(verbatim: "\(e) — showing the last good list").foregroundStyle(.red).lineLimit(3)
        }
    }
}

struct HelperBadge: View {
    @Environment(Store.self) var store

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle().fill(store.helperState.isRunning ? .green : .orange).frame(width: 7, height: 7)
                Text(verbatim: store.helperState.label).lineLimit(2)
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
            if let e = store.helperError { Text(verbatim: e).foregroundStyle(.red).lineLimit(3) }
        }
        .padding(.bottom, 4)
    }
}
