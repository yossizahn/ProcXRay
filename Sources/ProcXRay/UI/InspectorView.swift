import AppKit
import SwiftUI

struct InspectorView: View {
    @Environment(Store.self) var store
    let proc: ProcInfo
    /// The process is gone and `proc` is its last snapshot. Its pid may already belong to another
    /// process, so nothing is read from the pid any more: tabs keep what they showed, or say why not.
    var exited = false
    /// Signing details the window saw while the process ran; the store drops them once it's gone.
    var lastSign: SignInfo?
    /// The tab is remembered per window: a click in one Inspector must not switch (and so discard the
    /// collected output of) the others. The app-wide value is only the default for a new window.
    @AppStorage("inspectorTab") private var lastTab: InspectorTab = .overview
    @SceneStorage("inspectorTab") private var windowTab: String?
    private var tab: Binding<InspectorTab> {
        Binding(get: { windowTab.flatMap(InspectorTab.init(rawValue:)) ?? lastTab },
                set: { windowTab = $0.rawValue; lastTab = $0 })
    }
    /// Which pane Resources and Activity show; each holds two of the old tabs until steps 8 and 12.
    @AppStorage("inspector.resourcesPane") private var resourcesPane = "Counters"
    @AppStorage("inspector.activityPane") private var activityPane = "Logs"

    private var sign: SignInfo? { store.signInfo(for: proc) ?? lastSign }

    var body: some View {
        VStack(spacing: 0) {
            // Fixed height: a missing icon, owner or badge must not shift the tab strip below it.
            InspectorHeader(proc: proc, exited: exited, sign: sign)
            InspectorTabStrip(selection: tab)
            Divider()
            Group {
                switch tab.wrappedValue {
                case .overview: OverviewTab(proc: proc, exited: exited, sign: sign) { tab.wrappedValue = $0 }
                case .origin: OriginTab(proc: proc, exited: exited)
                case .trust: TrustTab(proc: proc, sign: sign, exited: exited)
                case .resources:
                    SubPanes(selection: $resourcesPane, names: ["Counters", "Memory map"]) {
                        if resourcesPane == "Memory map" {
                            toolTab(.vmmap, auto: false, title: "vmmap --summary \(proc.pid)",
                                    parse: VmmapParser.parse, isEmpty: \.isEmpty) { VmmapView(s: $0, filter: $1) }
                        } else {
                            CountersTab(proc: proc)
                        }
                    }
                case .connections:
                    toolTab(.lsof, auto: true, title: "lsof -n -P -p \(proc.pid)",
                            parse: LsofParser.parse, isEmpty: \.isEmpty) { LsofView(entries: $0, filter: $1) }
                case .activity:
                    SubPanes(selection: $activityPane, names: ["Logs", "Sample"]) {
                        if activityPane == "Sample" {
                            toolTab(.sample, auto: false, title: "sample \(proc.pid) 1 (all thread stacks for 1s)",
                                    parse: SampleParser.parse, isEmpty: \.threads.isEmpty) { SampleView(report: $0, filter: $1) }
                        } else {
                            logs
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Pin a new window to the tab in use when it opened; from then on other windows don't move it.
        .onAppear { if windowTab == nil { windowTab = lastTab.rawValue } }
    }

    private var logs: some View {
        let pid = proc.pid
        // `log show` reads history, not the process, so it still works after an exit.
        return CommandTab(key: "log\(proc.key)", auto: false,
                          title: "/usr/bin/log show --last 10m — events from pid \(pid) or mentioning it",
                          command: {
                              // Full path on purpose: zsh has a `log` builtin that silently shadows /usr/bin/log.
                              Shell.run("/usr/bin/log", ["show", "--last", "10m", "--style", "compact", "--info",
                                  "--predicate", "processID == \(pid) OR eventMessage CONTAINS \"\(pid)\""], timeout: 120)
                          },
                          parse: LogParser.parse, isEmpty: \.isEmpty) { LogView(entries: $0, filter: $1) }
    }

    /// lsof / vmmap / sample need root (or task_for_pid rights) for most processes: route them through
    /// the helper whenever it's running; otherwise run them as the user and explain failures.
    private func toolTab<P, V: View>(_ tool: HelperTool, auto: Bool, title: String,
                                     parse: @escaping @Sendable (String) -> P, isEmpty: @escaping (P) -> Bool,
                                     @ViewBuilder visual: @escaping (P, String) -> V) -> some View {
        let viaHelper = store.helperState.isRunning
        let pid = proc.pid, start = proc.start
        let platform = sign?.isPlatform == true
        return CommandTab(key: "\(tool)\(proc.key)\(viaHelper)", auto: auto,
                          title: title + (viaHelper ? "   [as root via helper]" : "   [as \(NSUserName())]"),
                          disabledReason: exited ? Self.exitedNote : nil,
                          command: {
            // The pid may have been reused since this window last saw the process: check right before
            // running (sample suspends its target) and again before showing the output.
            guard Native.isSame(pid, start: start) else { return Self.goneNote(pid) }
            var out: String
            if viaHelper {
                out = HelperClient.shared.run(tool, pid: pid) ?? "helper did not answer"
            } else {
                // argv refuses pid 0 (kernel_task): it isn't a user-space task these tools can attach to.
                guard let (path, args) = tool.argv(pid: pid) else {
                    return "\(tool) can't inspect pid \(pid) (kernel_task is not a user-space process)."
                }
                out = Shell.run(path, args, timeout: tool.timeout)
            }
            guard Native.isSame(pid, start: start) else { return Self.goneNote(pid) }
            let failed = out.isEmpty || out.contains("not permitted") || out.contains("Unable to") || out.contains("failed")
            if failed && tool != .lsof {
                out += viaHelper && platform
                    ? "\n\n— SIP prevents inspecting Apple platform binaries' memory, even as root."
                    : (viaHelper ? "" : "\n\n— Needs task_for_pid rights. Install the privileged helper (sidebar) to run this as root.")
            } else if tool == .lsof && !viaHelper && proc.uid != getuid() {
                out += "\n\n— Running as \(NSUserName()): another user's open files aren't visible. Install the helper for full output."
            }
            return out
        }, parse: parse, isEmpty: isEmpty, visual: visual)
    }

    static let exitedNote = "The process has exited, so this can't be collected any more."
    nonisolated static func goneNote(_ pid: pid_t) -> String {
        "Process \(pid) has exited (its pid may now belong to another process); nothing was collected."
    }
}

/// Leading-anchored tab strip. Each tab is sized to its own label (no weight change on selection,
/// which would resize it), and the strip scrolls horizontally when the pane is too narrow instead of
/// overflowing and getting re-centred — the overflow is what made the old segmented control jump.
struct InspectorTabStrip: View {
    @Binding var selection: InspectorTab

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(InspectorTab.allCases) { t in
                    let on = t == selection
                    Button { selection = t } label: {
                        Text(t.rawValue)
                            .font(.system(size: 12))
                            .foregroundStyle(on ? Color.primary : Color.secondary)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(on ? Color.accentColor.opacity(0.18) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 34)
    }
}

// MARK: - Key/value grid

/// A value in the key/value grid: text, or a link to a process followed by optional text.
enum KVValue {
    case text(String)
    case process(ProcInfo, note: String = "")
}

struct KV: View {
    let rows: [(String, KVValue)]
    init(rows: [(String, KVValue)]) { self.rows = rows }
    init(rows: [(String, String)]) { self.rows = rows.map { ($0.0, .text($0.1)) } }

    var body: some View {
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    GridRow {
                        Text(r.0).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        switch r.1 {
                        case .text(let t):
                            Text(t).textSelection(.enabled).font(.system(.body, design: .monospaced))
                        case .process(let p, let note):
                            HStack(spacing: 6) {
                                ProcessChip(proc: p)
                                if !note.isEmpty { Text(note).foregroundStyle(.secondary).textSelection(.enabled) }
                            }
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// What the process has used: memory, CPU and I/O counters, lifetime totals. (Step 8 turns this into
/// the Resources tab proper, with rates beside the totals.)
struct CountersTab: View {
    let proc: ProcInfo

    var body: some View {
        let p = proc
        var rows: [(String, String)] = []
        if p.isInspectable {
            let c = p.counters
            rows += [
                ("Footprint", Fmt.bytes(p.footprint)),
                ("Resident", Fmt.bytes(p.rss)),
                ("Virtual", Fmt.bytes(p.virt)),
                ("CPU time", Fmt.secs(p.cpuNanos)),
                ("CPU now", p.cpuPercent.map { String(format: "%.1f %%", $0) } ?? "—"),
                ("Threads", p.threads.map { t in c?.runningThreads.map { "\(t) (\($0) running)" } ?? "\(t)" } ?? "—"),
                ("Disk read / written", "\(Fmt.bytes(p.diskRead)) / \(Fmt.bytes(p.diskWrite))"),
                ("Energy", p.energyNJ.map { String(format: "%.2f J", Double($0) / 1e9) } ?? "—"),
                ("Billed energy", c?.billedEnergyNJ.map { String(format: "%.2f J", Double($0) / 1e9) } ?? "—"),
                ("Wakeups (idle + interrupt)", p.wakeups.map(String.init) ?? "—"),
            ]
            if let c {
                rows += [
                    ("Performance cores", c.pCoreNanos.map { pc in
                        let share = p.cpuNanos.flatMap { $0 > 0 ? Double(pc) / Double($0) * 100 : nil }
                        return Fmt.secs(pc) + (share.map { String(format: "  (%.0f %% of CPU time)", $0) } ?? "")
                    } ?? "—"),
                    ("Waiting for a CPU", Fmt.secs(c.waitingNanos)),
                    ("Instructions / cycles", "\(Fmt.count(c.instructions)) / \(Fmt.count(c.cycles))"
                        + (c.instructions.flatMap { i in c.cycles.flatMap { $0 > 0 ? String(format: "  (%.2f per cycle)", Double(i) / Double($0)) : nil } } ?? "")),
                    ("Context switches", Fmt.count(c.contextSwitches)),
                    ("Page faults", "\(Fmt.count(c.faults)) (\(Fmt.count(c.cowFaults)) copy-on-write)"),
                    ("Page-ins", Fmt.count(c.pageins)),
                    ("Mach messages sent / received", "\(Fmt.count(c.machMsgsSent)) / \(Fmt.count(c.machMsgsReceived))"),
                    ("System calls", "\(Fmt.count(c.unixSyscalls)) BSD · \(Fmt.count(c.machSyscalls)) Mach"),
                    ("Peak footprint", Fmt.bytes(c.peakFootprint)),
                    ("Neural Engine memory", Fmt.bytes(c.neuralFootprint)),
                    ("Logical writes", Fmt.bytes(c.logicalWrites)),
                ]
            }
        } else {
            rows.append(("Task info", "not accessible (owned by \(p.user)) — install the privileged helper to read it"))
        }
        if p.viaHelper { rows.append(("Source", "task metrics read as root via the privileged helper")) }
        return KV(rows: rows)
    }
}

/// Two panes in one tab, picked with a small segmented control above them.
struct SubPanes<Content: View>: View {
    @Binding var selection: String
    let names: [String]
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selection) {
                ForEach(names, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .padding(.vertical, 6)
            Divider()
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Lineage

extension Store {
    /// The process responsible for `p`, running and distinct from `p` (nil for self, unknown, exited
    /// or Left Behind, which responsibleDescription spells out).
    func responsibleProcess(_ p: ProcInfo) -> ProcInfo? {
        guard p.leftBehindText == nil, let r = p.responsible, r != p.pid else { return nil }
        return procs[r]
    }

    /// One-line account of who is responsible for `p`, shared by the General and Lineage tabs.
    func responsibleDescription(_ p: ProcInfo) -> String {
        if let t = p.leftBehindText { return "† \(t) — exited and left this process running" }
        guard let r = p.responsible else { return "unknown" }
        if r == p.pid { return "self (\(r))" }
        if let rp = procs[r] { return "\(rp.name) (\(r))" }
        let name = lsApps.first { $0.pid == r }?.name
        return "† \(name ?? "exited process") (\(r)) — no longer running"
    }
}

extension String {
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}

// MARK: - Shell-backed tabs

struct CommandTab<Parsed, Visual: View>: View {
    let key: String
    let auto: Bool
    let title: String
    /// Set when the command can't run any more (the process exited); earlier output stays visible.
    var disabledReason: String? = nil
    let command: @Sendable () -> String
    let parse: @Sendable (String) -> Parsed
    let isEmpty: (Parsed) -> Bool
    @ViewBuilder let visual: (Parsed, String) -> Visual
    @State private var output: String?
    @State private var parsed: Parsed?
    @State private var generation = 0
    @State private var running = false
    @State private var runTask: Task<Void, Never>?
    @State private var filter = ""
    @AppStorage("showRawOutput") private var showRaw = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                RawToggle(showRaw: $showRaw)
                Text(title).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                TextField(showRaw ? "filter lines" : "filter", text: $filter).textFieldStyle(.roundedBorder).frame(width: 180)
                Button(output == nil ? "Run" : "Re-run") { run() }.disabled(running || disabledReason != nil)
                    .help(disabledReason ?? "")
                if running { ProgressView().controlSize(.small) }
            }
            .padding(6)
            Divider()
            if let output {
                if let parsed, !isEmpty(parsed) {
                    // The visual view stays alive under Raw (hidden), so the Raw switch, which every window
                    // shares, doesn't wipe chips or expansion in other windows.
                    ZStack {
                        visual(parsed, filter).id(generation)   // fresh view state (expansion, chips) per run
                            .opacity(showRaw ? 0 : 1)
                            .allowsHitTesting(!showRaw)
                            .accessibilityHidden(showRaw)
                        if showRaw { MonoText(text: filterLines(output, filter)) }
                    }
                } else if showRaw {
                    MonoText(text: filterLines(output, filter))
                } else if parsed != nil {
                    UnparsedNote(raw: output)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: disabledReason == nil ? "play.circle" : "xmark.circle")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text(disabledReason ?? "Press Run to collect this data.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(running ? 0 : 1)
            }
        }
        .task(id: key) {
            // A new process (or helper state): stop the previous run so its output can't land here.
            runTask?.cancel()
            runTask = nil
            running = false
            output = nil
            parsed = nil
            if auto && disabledReason == nil { run() }
        }
        .onChange(of: disabledReason) { _, r in
            // Exited mid-run: stop it (sample would otherwise go on suspending whatever has the pid).
            if r != nil, running { runTask?.cancel(); runTask = nil; running = false }
        }
        .onDisappear { runTask?.cancel() }   // window closed: don't let sample / log show run on
    }

    private func run() {
        runTask?.cancel()
        running = true
        let cmd = command, parse = parse
        let cancel = Shell.Cancel()
        runTask = Task {
            let (out, p) = await withTaskCancellationHandler {
                await Task.detached { () -> (String, Parsed) in
                    let o = Shell.Cancel.$current.withValue(cancel) { cmd() }
                    return (o, parse(o))
                }.value
            } onCancel: { cancel.cancel() }
            guard !Task.isCancelled else { return }
            output = out
            parsed = p
            generation += 1
            running = false
        }
    }
}

/// Fast, selectable monospaced text (SwiftUI Text chokes on 10k-line outputs).
struct MonoText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSTextView.scrollableTextView()
        let tv = sv.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.isAutomaticLinkDetectionEnabled = false
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let tv = sv.documentView as! NSTextView
        if tv.string != text {
            tv.string = text
            tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            tv.textColor = .labelColor
        }
    }
}
