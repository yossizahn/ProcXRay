import AppKit
import SwiftUI

/// File ▸ Launch and Trace…: starts an app or program suspended, starts a syscall trace on it, then lets it run,
/// so the trace has its launch from the first instruction (Launcher, SyscallTracer.start(resume:)).
struct LaunchTraceView: View {
    static let id = "launch-trace"

    @Environment(Store.self) var store
    @AppStorage("launchTrace.path") private var path = ""
    @AppStorage("launchTrace.arguments") private var arguments = ""
    @AppStorage("syscallTrace.stacks") private var stacks = false
    @State private var tracer = SyscallTracer()
    @State private var target: TraceTarget?
    @State private var launches = 0
    @State private var error: String?

    private var disabledReason: String? {
        if !store.helperState.isRunning { return "Tracing needs root: install the helper (Settings ▸ Helper)." }
        if path.isEmpty { return "Choose an app or a program first." }
        if tracer.isActive { return "Stop the current trace first." }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            form
            Divider()
            if let target {
                SyscallTraceView(target: target, exited: !Native.isSame(target.pid, start: target.start), tracer: tracer)
                    .id(launches)
            } else {
                ContentUnavailableView {
                    Label("Nothing launched yet", systemImage: "play.circle")
                } description: {
                    Text("Choose an app or a program and launch it. It starts suspended, the trace starts, then it runs: its first library loads, initializers and file opens are all in the trace.")
                }
            }
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("App or program", text: $path, prompt: Text("/Applications/Example.app or /usr/bin/example"))
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") { choose() }
                TextField("Arguments", text: $arguments, prompt: Text("arguments"))
                    .textFieldStyle(.roundedBorder).frame(width: 220)
                    .help("Split as a shell splits words: spaces separate, quotes group, a backslash escapes. No expansion.")
                Toggle("Stacks", isOn: $stacks).toggleStyle(.checkbox).font(.caption)
                    .help("Record the user stack of every call (kperf), to see which code made it. The traced process runs up to a third slower.")
                Button { launch() } label: { Label("Launch and Trace", systemImage: "play.fill") }
                    .keyboardShortcut(.defaultAction)
                    .disabled(disabledReason != nil)
                    .help(disabledReason ?? "Start it suspended, start the trace, then let it run")
            }
            Group {
                if let error {
                    Text(error).foregroundStyle(.red)
                } else {
                    Text("Runs as \(NSUserName()), as a child of Proc X-Ray. An app is started directly, not through Launch Services, so it gets no open-document or reopen events at launch.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption).lineLimit(2)
        }
        .padding(8)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: path.isEmpty ? "/Applications" : (path as NSString).deletingLastPathComponent)
        panel.message = "Choose an app or a program to launch and trace"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = url.path
        error = nil
    }

    private func launch() {
        error = nil
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let exe = Launcher.executable(for: url) else {
            error = "\(url.path) isn't an app or an executable file."
            return
        }
        let name = Launcher.displayName(for: url)
        switch Launcher.spawnSuspended(exe, arguments: Launcher.splitArguments(arguments), name: name) {
        case .failure(let e):
            error = e.message
        case .success(let child):
            tracer.stop()
            let t = SyscallTracer()
            tracer = t
            target = TraceTarget(pid: child.pid, start: child.start, name: child.name)
            launches += 1
            t.start(pid: child.pid, start: child.start, stacks: stacks, resume: true)
        }
    }
}

/// File ▸ Launch and Trace…, next to Open Binary….
struct LaunchTraceCommand: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Launch and Trace…") { openWindow(id: LaunchTraceView.id) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}
