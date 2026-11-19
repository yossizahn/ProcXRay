import AppKit
import SwiftUI

/// File ▸ Launch…: starts an app or a program by any of macOS's ways of starting one (LaunchSpec.Method), with
/// every setting that way takes, then shows what it writes and, optionally, a syscall trace of it: from its first
/// instruction when the method can hold it before it runs (a direct spawn, the helper, a launchd job).
struct LaunchView: View {
    static let id = "launch"

    @Environment(Store.self) var store
    @Environment(\.openWindow) private var openWindow
    @AppStorage("launch.spec") private var saved = ""
    @State private var spec = LaunchSpec()
    @State private var loaded = false
    @State private var session = LaunchSession()
    @State private var pane: Pane = .output
    @State private var streams: Streams = .both

    enum Pane: String, CaseIterable { case output = "Output", trace = "Trace" }
    enum Streams: String, CaseIterable { case both = "stdout and stderr", stdout = "stdout", stderr = "stderr" }

    private var disabledReason: String? {
        if session.launching { return "Launching…" }
        if spec.path.isEmpty { return "Choose an app or a program first." }
        if spec.trace && !store.helperState.isRunning { return "Tracing needs root: install the helper (Settings ▸ Helper)." }
        if spec.method == .root && !store.helperState.isRunning { return "Launching as root needs the helper (Settings ▸ Helper)." }
        if spec.trace && session.tracer.isActive { return "Stop the current trace first." }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                ScrollView { settings.padding(12) }
                    .frame(minWidth: 340, idealWidth: 400, maxWidth: 560, maxHeight: .infinity, alignment: .top)
                results.frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1000, minHeight: 600)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let d = saved.data(using: .utf8), let s = try? JSONDecoder().decode(LaunchSpec.self, from: d) { spec = s }
            else if let old = UserDefaults.standard.string(forKey: "launchTrace.path") {
                // Launch and Trace's settings, from before this window.
                spec.path = old
                spec.arguments = UserDefaults.standard.string(forKey: "launchTrace.arguments") ?? ""
                spec.trace = true
            }
        }
        .onChange(of: spec) { _, s in
            if let d = try? JSONEncoder().encode(s), let text = String(data: d, encoding: .utf8) { saved = text }
        }
        .onDisappear { session.stopTrace() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("App or program", text: $spec.path, prompt: Text("/Applications/Example.app or /usr/bin/example"))
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") { choose() }
                TextField("Arguments", text: $spec.arguments, prompt: Text("arguments"))
                    .textFieldStyle(.roundedBorder).frame(width: 220)
                    .help("Split as a shell splits words: spaces separate, quotes group, a backslash escapes. No expansion.")
            }
            HStack(spacing: 8) {
                Picker("Launch with", selection: $spec.method) {
                    ForEach(LaunchSpec.Method.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
                Toggle("Trace", isOn: $spec.trace).toggleStyle(.checkbox)
                    .help(spec.method.startsSuspended ? "Start it stopped, start a syscall trace, then let it run: the trace has it from its first instruction."
                                                      : "Start a syscall trace once it's running (this method can't hold it before its first instruction).")
                if spec.trace {
                    Toggle("Stacks", isOn: $spec.stacks).toggleStyle(.checkbox)
                        .help("Record the user stack of every call (kperf), to see which code made it. The traced process runs up to a third slower.")
                }
                Spacer()
                Button { Task { await session.launch(spec) } } label: {
                    Label(spec.trace ? "Launch and Trace" : "Launch", systemImage: "play.fill")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(disabledReason != nil)
                .help(disabledReason ?? "Launch it")
            }
            Text(methodSummary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
        }
        .padding(8)
    }

    private var methodSummary: String {
        switch spec.method {
        case .spawn:
            "posix_spawn as \(NSUserName()), a child of Proc X-Ray in its coalition. An app is started without Launch Services (no open-document events), and Apple's own apps refuse to start this way while SIP is on."
        case .root:
            "posix_spawn in the root helper, as root or the user below, after an administrator's password or Touch ID. A child of the helper; Apple's own apps refuse this too."
        case .launchd:
            "A job in your GUI launchd domain (\(LaunchMethods.Launchd.label(for: currentName))): its own coalition, launchd's resource policy and limits, launchd as its parent. Launching again replaces the job."
        case .launchServices:
            "NSWorkspace, as the Finder and the Dock launch apps: the only way Apple's own apps start while SIP is on. Its stdout and stderr aren't available, and a trace misses its first moments."
        case .open:
            "/usr/bin/open: Launch Services from the command line, with stdio files and waiting for the app to quit. A trace misses its first moments."
        }
    }

    private var currentName: String {
        spec.path.isEmpty ? "program" : Launcher.displayName(for: URL(fileURLWithPath: (spec.path as NSString).expandingTildeInPath))
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: spec.path.isEmpty ? "/Applications" : (spec.path as NSString).deletingLastPathComponent)
        panel.message = "Choose an app or a program to launch"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        spec.path = url.path
    }

    // MARK: Settings

    @ViewBuilder private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            programSection
            ioSection
            switch spec.method {
            case .spawn:
                spawnSection
                schedulingSection
                processSection
            case .root:
                rootSection
                spawnSection
                schedulingSection
                processSection
            case .launchd: launchdSection
            case .launchServices: launchServicesSection
            case .open: openSection
            }
        }
        .controlSize(.small)
    }

    private var programSection: some View {
        SettingsSection("Program") {
            if spec.method.hasArgv0 {
                row("argv[0]", help: "The name the program sees for itself; empty: its path.") {
                    TextField("", text: $spec.argv0, prompt: Text("its path")).textFieldStyle(.roundedBorder)
                }
            }
            if spec.method.hasWorkingDirectory {
                row("Working directory", help: spec.method == .spawn ? "Empty: Proc X-Ray's (posix_spawn_file_actions_addchdir_np)." : "Empty: / (WorkingDirectory).") {
                    TextField("", text: $spec.workingDirectory, prompt: Text(spec.method == .spawn ? "Proc X-Ray's" : "/")).textFieldStyle(.roundedBorder)
                }
            }
            if spec.method.hasFullEnvironment {
                row("Environment", help: "What the edits below start from. Login: HOME, USER, LOGNAME, SHELL, PATH and TMPDIR, for the user it runs as.") {
                    Picker("", selection: $spec.environmentBase) {
                        Text("Proc X-Ray's").tag(LaunchSpec.EnvironmentBase.inherit)
                        Text("Login only").tag(LaunchSpec.EnvironmentBase.login)
                        Text("Empty").tag(LaunchSpec.EnvironmentBase.empty)
                    }.labelsHidden().fixedSize()
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.method.hasFullEnvironment ? "Variables: NAME=value sets, -NAME removes" : "Variables to add: NAME=value")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $spec.environment)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 64)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                if spec.method == .launchServices || spec.method == .open {
                    Text("Launch Services adds these to the environment it gives every app; an app already running keeps its own.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var ioSection: some View {
        SettingsSection("Standard input and output") {
            if !spec.method.hasOutput {
                Text("Launch Services connects an app's stdin, stdout and stderr to /dev/null and has no setting for them (the open command does).")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                if spec.method.hasStdin {
                    row("stdin", help: nil) {
                        Picker("", selection: $spec.stdin) {
                            Text("/dev/null").tag(LaunchSpec.Input.null)
                            Text("File").tag(LaunchSpec.Input.file)
                        }.labelsHidden().fixedSize()
                        if spec.stdin == .file { TextField("", text: $spec.stdinPath, prompt: Text("path")).textFieldStyle(.roundedBorder) }
                    }
                }
                row("stdout", help: nil) {
                    outputPicker($spec.stdout, allowsSame: false)
                    if spec.stdout == .file { TextField("", text: $spec.stdoutPath, prompt: Text("path")).textFieldStyle(.roundedBorder) }
                }
                row("stderr", help: nil) {
                    outputPicker($spec.stderr, allowsSame: true)
                    if spec.stderr == .file { TextField("", text: $spec.stderrPath, prompt: Text("path")).textFieldStyle(.roundedBorder) }
                }
                if spec.method == .spawn || spec.method == .root {
                    Toggle("Append to output files", isOn: $spec.appendOutput)
                }
                if spec.method == .open && !spec.open.wait && (spec.stdout == .show || spec.stderr == .show) {
                    Text("Without “Wait until it quits”, open lets go of the files at once; what the app writes later still reaches them.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func outputPicker(_ b: Binding<LaunchSpec.Output>, allowsSame: Bool) -> some View {
        Picker("", selection: b) {
            Text("Show here").tag(LaunchSpec.Output.show)
            Text("/dev/null").tag(LaunchSpec.Output.null)
            Text("File").tag(LaunchSpec.Output.file)
            if allowsSame { Text("Same as stdout").tag(LaunchSpec.Output.stdout) }
        }.labelsHidden().fixedSize()
    }

    private var rootSection: some View {
        SettingsSection("Run as") {
            row("User", help: "A name or uid; empty: root (posix_spawnattr_set_uid_np).") {
                TextField("", text: $spec.root.user, prompt: Text("root")).textFieldStyle(.roundedBorder)
            }
            row("Group", help: "A name or gid; empty: the user's primary group.") {
                TextField("", text: $spec.root.group, prompt: Text("user's primary")).textFieldStyle(.roundedBorder)
            }
            Toggle("The user's supplementary groups", isOn: $spec.root.supplementaryGroups)
                .help("As initgroups gives them; off: the primary group only.")
            Text("Each launch asks for an administrator's password or Touch ID: like sudo, the helper runs nothing as root without it.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var spawnSection: some View {
        SettingsSection("posix_spawn") {
            Toggle("New session (setsid, no controlling terminal)", isOn: $spec.spawn.newSession)
            Toggle("Own process group", isOn: $spec.spawn.newProcessGroup).disabled(spec.spawn.newSession)
            Toggle("Reset to the real user and group ids (RESETIDS)", isOn: $spec.spawn.resetIDs)
            Toggle("Inherit Proc X-Ray's other open descriptors", isOn: $spec.spawn.inheritDescriptors)
                .help("Without POSIX_SPAWN_CLOEXEC_DEFAULT: every descriptor not marked close-on-exec.")
            Toggle("Default signal handling, none blocked", isOn: $spec.spawn.defaultSignals)
                .help("POSIX_SPAWN_SETSIGDEF and SETSIGMASK; off: Proc X-Ray's ignored and blocked signals carry over.")
            Toggle("Disable ASLR", isOn: $spec.spawn.disableASLR).help("_POSIX_SPAWN_DISABLE_ASLR: the main image and dyld unslid.")
            row("Architecture", help: "posix_spawnattr_setarchpref_np: which slice of a universal binary runs. x86_64 needs Rosetta.") {
                archPicker($spec.spawn.architecture)
            }
            Toggle("Disclaim responsibility (its own responsible process)", isOn: $spec.spawn.disclaimResponsibility)
                .help("responsibility_spawnattrs_setdisclaim: TCC asks about it, not about Proc X-Ray.")
            Toggle(spec.trace ? "Leave it stopped after the trace starts" : "Leave it suspended", isOn: $spec.spawn.leaveSuspended)
                .help("Started with POSIX_SPAWN_START_SUSPENDED and not resumed: resume it from here when ready.")
        }
    }

    private var schedulingSection: some View {
        SettingsSection("Scheduling and memory") {
            row("QoS clamp", help: "posix_spawnattr_set_qos_clamp_np: no thread runs above this QoS.") {
                Picker("", selection: $spec.spawn.qosClamp) {
                    ForEach(SpawnSettings.QoSClamp.allCases, id: \.self) { Text($0 == .none ? "None" : $0.rawValue.capitalized).tag($0) }
                }.labelsHidden().fixedSize()
            }
            row("Role", help: "posix_spawnattr_set_darwin_role_np: the scheduler's role for it (PRIO_DARWIN_ROLE).") {
                Picker("", selection: $spec.spawn.role) {
                    ForEach(SpawnSettings.Role.allCases, id: \.self) { Text($0.label).tag($0) }
                }.labelsHidden().fixedSize()
            }
            row("Process type", help: "posix_spawnattr_setprocesstype_np: the resource policy launchd gives jobs of this kind (QoS, I/O, memory).") {
                Picker("", selection: $spec.spawn.processType) {
                    ForEach(SpawnSettings.ProcessType.allCases, id: \.self) { Text($0.label).tag($0) }
                }.labelsHidden().fixedSize()
            }
            row("Memory limit", help: "posix_spawnattr_setjetsam_ext, in MiB; 0: none.") {
                TextField("", value: $spec.spawn.memoryLimitMB, format: .number).textFieldStyle(.roundedBorder).frame(width: 70)
                Text("MiB").foregroundStyle(.secondary)
                Toggle("Kill when over it", isOn: $spec.spawn.memoryLimitFatal).disabled(spec.spawn.memoryLimitMB <= 0)
            }
            row("Jetsam priority", help: "-1: unchanged. Higher bands are killed later under memory pressure.") {
                TextField("", value: $spec.spawn.jetsamPriority, format: .number).textFieldStyle(.roundedBorder).frame(width: 70)
            }
            Toggle("No SMT (no core shared with other tasks)", isOn: $spec.spawn.noSMT)
            Toggle("All CPU security mitigations", isOn: $spec.spawn.cpuMitigations).help("posix_spawnattr_set_csm_np(POSIX_SPAWN_NP_CSM_ALL).")
        }
    }

    private var processSection: some View {
        SettingsSection("Limits, priority and sandbox (set by pxr-exec)") {
            Text("posix_spawn can't set these: pxr-exec sets them in the process, then execs the program with the same pid. A trace starts with those few calls.")
                .font(.caption2).foregroundStyle(.secondary)
            limitsGrid($spec.process.limits)
            row("umask", help: "Octal; empty keeps Proc X-Ray's.") {
                TextField("", text: $spec.process.umask, prompt: Text("022")).textFieldStyle(.roundedBorder).frame(width: 70)
            }
            row("Nice", help: "setpriority; empty keeps it. Below the parent's needs root.") {
                TextField("", text: optionalInt($spec.process.nice), prompt: Text("0")).textFieldStyle(.roundedBorder).frame(width: 70)
            }
            Toggle("Background priority (PRIO_DARWIN_BG)", isOn: $spec.process.darwinBackground)
            row("Disk I/O policy", help: "setiopolicy_np, process-wide.") {
                Picker("", selection: $spec.process.ioPolicy) {
                    ForEach(ProcessSettings.IOPolicy.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }.labelsHidden().fixedSize()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Sandbox profile (SBPL), as sandbox-exec -p").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $spec.process.sandboxProfile)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                HStack {
                    Button("No network") { spec.process.sandboxProfile = "(version 1)\n(allow default)\n(deny network*)" }
                    Button("No writes outside temp") { spec.process.sandboxProfile = "(version 1)\n(allow default)\n(deny file-write*)\n(allow file-write* (subpath \"/private/tmp\") (subpath \"/private/var/folders\") (literal \"/dev/null\"))" }
                    Button("Clear") { spec.process.sandboxProfile = "" }
                }
                Text("macOS's named profiles (no-network…) kill the program at launch on this macOS; write the rules instead.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var launchdSection: some View {
        SettingsSection("launchd job") {
            row("Process type", help: "ProcessType: the resource policy (Background is throttled, Interactive is not).") {
                Picker("", selection: $spec.launchd.processType) {
                    ForEach(LaunchdSettings.ProcessType.allCases, id: \.self) { Text($0 == .unset ? "Default" : $0.rawValue).tag($0) }
                }.labelsHidden().fixedSize()
            }
            row("Nice", help: "Nice; empty: unset.") {
                TextField("", text: optionalInt($spec.launchd.nice), prompt: Text("0")).textFieldStyle(.roundedBorder).frame(width: 70)
            }
            row("umask", help: "Umask, octal; empty: unset.") {
                TextField("", text: $spec.launchd.umask, prompt: Text("022")).textFieldStyle(.roundedBorder).frame(width: 70)
            }
            Toggle("Low priority I/O (LowPriorityIO)", isOn: $spec.launchd.lowPriorityIO)
            Toggle("Low priority I/O in the background (LowPriorityBackgroundIO)", isOn: $spec.launchd.lowPriorityBackgroundIO)
            Text("Resource limits (SoftResourceLimits, HardResourceLimits)").font(.caption).foregroundStyle(.secondary)
            limitsGrid($spec.launchd.limits, names: Set(LaunchdSettings.limitKeys.keys))
            Toggle("Start stopped, as for a debugger (WaitForDebugger)", isOn: $spec.launchd.waitForDebugger)
                .help(spec.trace ? "Always on while tracing: that's how the trace has it from its first instruction." : "Resume it from here.")
            Toggle("Restart it whenever it exits (KeepAlive)", isOn: $spec.launchd.keepAlive)
            Toggle("Keep its children when it ends (AbandonProcessGroup)", isOn: $spec.launchd.abandonProcessGroup)
            row("ExitTimeOut", help: "Seconds from SIGTERM to SIGKILL when the job stops; empty: 20.") {
                TextField("", text: optionalInt($spec.launchd.exitTimeOut), prompt: Text("20")).textFieldStyle(.roundedBorder).frame(width: 70)
            }
            row("ThrottleInterval", help: "Seconds before launchd starts it again; empty: 10.") {
                TextField("", text: optionalInt($spec.launchd.throttleInterval), prompt: Text("10")).textFieldStyle(.roundedBorder).frame(width: 70)
            }
            Toggle("Killable when idle under memory pressure (EnablePressuredExit)", isOn: $spec.launchd.enablePressuredExit)
            Toggle("Transactions keep it alive (EnableTransactions)", isOn: $spec.launchd.enableTransactions)
            Toggle("No timer coalescing (LegacyTimers)", isOn: $spec.launchd.legacyTimers)
            Toggle("Download dataless files it reads (MaterializeDatalessFiles)", isOn: $spec.launchd.materializeDatalessFiles)
            Toggle("A security session of its own (SessionCreate)", isOn: $spec.launchd.sessionCreate)
        }
    }

    private var launchServicesSection: some View {
        SettingsSection("Launch Services (NSWorkspace.OpenConfiguration)") {
            Toggle("Bring it to the front (activates)", isOn: $spec.launchServices.activates)
            Toggle("Hide it (hides)", isOn: $spec.launchServices.hides)
            Toggle("Hide the other apps (hidesOthers)", isOn: $spec.launchServices.hidesOthers)
            Toggle("A new instance even if it runs (createsNewApplicationInstance)", isOn: $spec.launchServices.createsNewInstance)
            Toggle("A running copy may stand in (allowsRunningApplicationSubstitution)", isOn: $spec.launchServices.allowsSubstitution)
            Toggle("Add to recent items (addsToRecentItems)", isOn: $spec.launchServices.addsToRecentItems)
            Toggle("Ask the user if needed (promptsUserIfNeeded)", isOn: $spec.launchServices.promptsUserIfNeeded)
            Toggle("Print the documents (isForPrinting)", isOn: $spec.launchServices.forPrinting)
            row("Architecture", help: "OpenConfiguration.architecture.") { archPicker($spec.launchServices.architecture, subtypes: false) }
            documents($spec.launchServices.documents)
        }
    }

    private var openSection: some View {
        SettingsSection("open command") {
            Toggle("A new instance even if it runs (-n)", isOn: $spec.open.newInstance)
            Toggle("Don't bring it to the front (-g)", isOn: $spec.open.background)
            Toggle("Launch it hidden (-j)", isOn: $spec.open.hidden)
            Toggle("Fresh: no windows restored (-F)", isOn: $spec.open.fresh)
            Toggle("Wait until it quits (-W)", isOn: $spec.open.wait)
            row("Architecture", help: "--arch.") { archPicker($spec.open.architecture, subtypes: false) }
            documents($spec.open.documents)
            Text("Arguments go after --args, variables as --env, stdio files as --stdin, --stdout and --stderr.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func documents(_ b: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Files or URLs to open with it, one per line").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: b)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 48)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
        }
    }

    private func archPicker(_ b: Binding<SpawnSettings.Architecture>, subtypes: Bool = true) -> some View {
        Picker("", selection: b) {
            ForEach(SpawnSettings.Architecture.allCases.filter { subtypes || $0 != .arm64e }, id: \.self) {
                Text(!subtypes && $0 == .arm64 ? "arm64" : $0.label).tag($0)
            }
        }.labelsHidden().fixedSize()
    }

    private func limitsGrid(_ b: Binding<[String: ProcessSettings.Limit]>, names: Set<String>? = nil) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 3) {
            GridRow {
                Text("Limit").font(.caption).foregroundStyle(.secondary)
                Text("Soft").font(.caption).foregroundStyle(.secondary)
                Text("Hard").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(ProcessSettings.resources.filter { names?.contains($0.name) ?? true }, id: \.name) { r in
                GridRow {
                    Text(r.label).font(.caption)
                    TextField("", text: limit(b, r.name, \.soft), prompt: Text("unchanged")).textFieldStyle(.roundedBorder).frame(width: 90)
                    TextField("", text: limit(b, r.name, \.hard), prompt: Text("unchanged")).textFieldStyle(.roundedBorder).frame(width: 90)
                }
            }
        }
        .help(names == nil ? "A number, “inf”, or empty to keep the current value (setrlimit)." : "A number, or empty to leave it unset.")
    }

    private func limit(_ b: Binding<[String: ProcessSettings.Limit]>, _ name: String,
                       _ field: WritableKeyPath<ProcessSettings.Limit, String>) -> Binding<String> {
        Binding(get: { b.wrappedValue[name]?[keyPath: field] ?? "" },
                set: { v in
                    var l = b.wrappedValue[name] ?? .init()
                    l[keyPath: field] = v
                    b.wrappedValue[name] = l.isSet ? l : nil
                })
    }

    private func optionalInt(_ b: Binding<Int?>) -> Binding<String> {
        Binding(get: { b.wrappedValue.map(String.init) ?? "" },
                set: { b.wrappedValue = Int($0.trimmingCharacters(in: .whitespaces)) })
    }

    private func row<Content: View>(_ label: String, help: String?, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(label).frame(width: 120, alignment: .leading)
            content()
        }
        .help(help ?? "")
    }

    // MARK: Results

    private var results: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            if session.child == nil && session.error == nil {
                ContentUnavailableView {
                    Label("Nothing launched yet", systemImage: "play.circle")
                } description: {
                    Text("Choose an app or a program, how to launch it, and launch it. What it writes shows here, and its trace when Trace is on.")
                }
            } else {
                Picker("", selection: $pane) { ForEach(Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().padding(6)
                switch pane {
                case .output: outputPane
                case .trace: tracePane
                }
            }
        }
        .onChange(of: session.generation) { _, _ in pane = session.traceTarget != nil && !session.method.hasOutput ? .trace : pane }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let c = session.child {
                    Text("\(c.name), pid \(String(c.pid))").bold()
                    Text(session.ended != nil ? "ended" : session.suspended ? "suspended" : "running")
                        .foregroundStyle(session.ended != nil ? Color.secondary : session.suspended ? Color.orange : Color.green)
                    Spacer()
                    if session.isRunning {
                        if session.suspended { Button("Resume") { session.signal(SIGCONT) } }
                        else { Button("Suspend") { session.signal(SIGSTOP) } }
                        Button("Quit (SIGTERM)") { session.signal(SIGTERM) }
                        Button("Kill") { session.signal(SIGKILL) }
                        Button("Show Process") {
                            openWindow(id: ProcessWindow.id, value: ProcessRef(pid: c.pid, start: c.start.timeIntervalSince1970))
                        }
                    }
                    if session.jobLabel != nil {
                        Button("Remove Job") { session.removeJob() }.help("launchctl bootout: unload the launchd job (ending it if it runs).")
                    }
                } else if session.launching {
                    ProgressView().controlSize(.small)
                    Text("Launching…")
                    Spacer()
                } else {
                    Spacer()
                }
            }
            .controlSize(.small)
            if let e = session.error { Text(e).foregroundStyle(.red).font(.caption) }
            if let e = session.ended { Text(e).foregroundStyle(e.hasPrefix("It exited with status 0") ? Color.secondary : Color.red).font(.caption) }
            ForEach(session.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(8)
        .frame(minHeight: 34)
    }

    @ViewBuilder private var outputPane: some View {
        if !session.method.hasOutput && session.child != nil {
            ContentUnavailableView("No output", systemImage: "text.alignleft",
                                   description: Text("Launch Services gives an app no stdout or stderr to read. Launch it with the open command to see them."))
        } else {
            VStack(spacing: 0) {
                HStack {
                    Picker("", selection: $streams) { ForEach(Streams.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .labelsHidden().fixedSize()
                    if session.output.dropped > 0 {
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(session.output.dropped), countStyle: .file)) of the oldest output dropped")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("stderr in red").font(.caption).foregroundStyle(.secondary)
                }
                .controlSize(.small).padding(.horizontal, 8).padding(.bottom, 4)
                OutputText(log: session.output, streams: streams)
            }
        }
    }

    @ViewBuilder private var tracePane: some View {
        if let target = session.traceTarget {
            SyscallTraceView(target: target, exited: session.ended != nil, tracer: session.tracer)
                .id(session.generation)
        } else {
            ContentUnavailableView("No trace", systemImage: "waveform.path.ecg",
                                   description: Text("Turn on Trace before launching to trace it."))
        }
    }
}

/// The output log as one selectable text, following its end.
private struct OutputText: View {
    let log: OutputLog
    let streams: LaunchView.Streams

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                Color.clear.frame(height: 1).id("end")
            }
            .onChange(of: log.revision) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var text: AttributedString {
        var out = AttributedString()
        for c in log.chunks {
            switch streams {
            case .stdout where c.stream != 1, .stderr where c.stream != 2: continue
            default: break
            }
            var a = AttributedString(c.text)
            if c.stream == 2 { a.foregroundColor = .red }
            out += a
        }
        if out.characters.isEmpty { out = AttributedString("Nothing yet.") ; out.foregroundColor = .secondary }
        return out
    }
}

/// A titled group of settings.
private struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// File ▸ Launch…, next to Open Binary….
struct LaunchCommand: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Launch…") { openWindow(id: LaunchView.id) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}
