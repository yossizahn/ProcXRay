import SwiftUI

/// The Logs pane's data: a one-off `log show` (Run), or `log stream` after the last 10 minutes of history (Live).
@MainActor @Observable
final class LogSession {
    enum Mode { case snapshot, live }
    private(set) var mode: Mode = .snapshot
    private(set) var started = false
    private(set) var isActive = false
    private(set) var stopping = false
    /// Live: `log show` for the history is still running; streamed lines wait for it.
    private(set) var loadingHistory = false
    private(set) var entries: [LogEntry] = []
    /// Snapshot: the tool's whole output. Live: its lines, kept like `entries`.
    private(set) var rawText = ""
    private(set) var rawLines: [String] = []
    private(set) var notes: [String] = []
    /// Oldest entries let go to stay under `cap`.
    private(set) var dropped = 0
    /// Bumped on every change to `entries`.
    private(set) var revision = 0
    /// Bumped per Run or Live, so the table starts with fresh state (expansion, level chips).
    private(set) var runID = 0
    private var stopFlag: Shell.Cancel?

    /// WindowServer logged ~1,800 lines/s here (info and debug): this is about a minute of it.
    static let cap = 100_000

    var raw: String { mode == .snapshot ? rawText : rawLines.joined(separator: "\n") }

    private func reset(_ m: Mode) -> Shell.Cancel {
        mode = m; started = true; isActive = true; stopping = false; loadingHistory = false
        entries = []; rawText = ""; rawLines = []; notes = []; dropped = 0
        revision += 1; runID += 1
        let flag = Shell.Cancel()
        stopFlag = flag
        return flag
    }

    func stop() {
        guard isActive, !stopping else { return }
        stopping = true
        stopFlag?.cancel()
    }

    // MARK: Snapshot

    /// Kept as it was: events from the pid, or mentioning it, over the last 10 minutes.
    nonisolated static func snapshotPredicate(_ pid: Int32) -> String {
        "processID == \(pid) OR eventMessage CONTAINS \"\(pid)\""
    }

    func runSnapshot(pid: Int32) {
        guard !isActive else { return }
        let flag = reset(.snapshot)
        let id = runID
        Task.detached(priority: .userInitiated) { [self] in
            // Full path on purpose: zsh has a `log` builtin that silently shadows /usr/bin/log.
            let out = Shell.Cancel.$current.withValue(flag) {
                Shell.run("/usr/bin/log", ["show", "--last", "10m", "--style", "compact", "--info",
                                           "--predicate", Self.snapshotPredicate(pid)], timeout: 120)
            }
            let parsed = flag.isCancelled ? [] : LogParser.parse(out)
            await self.finishSnapshot(id, out, parsed, cancelled: flag.isCancelled)
        }
    }

    private func finishSnapshot(_ id: Int, _ out: String, _ parsed: [LogEntry], cancelled: Bool) {
        guard id == runID else { return }
        isActive = false; stopping = false
        if cancelled { started = false; return }   // as before: a stopped Run shows nothing
        rawText = out
        entries = parsed
        revision += 1
    }

    // MARK: Live

    /// Only the process's own events. Adding `eventMessage CONTAINS "<pid>"` as the snapshot does made
    /// `log stream` check every message on the system: on WindowServer it took the stream from 4% of a core
    /// to 18%, and added 7,000 lines in 10 s from other processes whose messages happened to contain "672".
    nonisolated static func livePredicate(_ pid: Int32) -> String { "processID == \(pid)" }

    func startLive(pid: Int32, start: Date) {
        guard !isActive else { return }
        let flag = reset(.live)
        loadingHistory = true
        let id = runID
        Task.detached(priority: .userInitiated) { [self] in
            await Self.live(pid: pid, start: start, flag: flag, id: id, session: self)
        }
    }

    private nonisolated static func live(pid: Int32, start: Date, flag: Shell.Cancel, id: Int, session: LogSession) async {
        let predicate = livePredicate(pid)
        let buffer = LineBuffer()
        // The stream starts first and the history is read after it, so they overlap instead of leaving
        // a gap; the overlap is dropped below (`overlap`).
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Shell.Cancel.$current.withValue(flag) {
                Shell.stream("/usr/bin/log", ["stream", "--style", "compact", "--info", "--predicate", predicate]) {
                    buffer.add($0)
                }
            }
            buffer.finish(r)
        }
        // `log stream` prints "Filtering the log data using …" once it's running.
        let t0 = Date()
        while !buffer.hasOutput, !buffer.isFinished, !flag.isCancelled, Date().timeIntervalSince(t0) < 3 {
            try? await Task.sleep(for: .milliseconds(20))
        }

        var parser = LogParser.Incremental()
        var history: [Substring] = []
        var endNote: String?
        if !flag.isCancelled {
            let hist = Shell.Cancel.$current.withValue(flag) {
                Shell.exec("/usr/bin/log", ["show", "--last", "10m", "--style", "compact", "--info",
                                            "--predicate", predicate], timeout: 120)
            }
            let lines = hist.output.split(separator: "\n", omittingEmptySubsequences: false)
            for l in lines { parser.feed(l) }
            history = lines
            var note: String?
            if !hist.ok && !flag.isCancelled {
                note = "log show (the last 10 minutes) " + (hist.timedOut ? "ran past its time limit" : "failed (status \(hist.status))")
                    + ": only events from now on."
            }
            await session.receive(id, parser.drain(), raw: lines.filter { !$0.isEmpty }.map(String.init),
                                  historyDone: true, note: note)
        }

        // Everything streamed while the history was read; the stream is ~1 ms behind the events.
        try? await Task.sleep(for: .milliseconds(300))
        var first = true
        var preamble: [String] = []   // what the stream wrote before any event: its errors, if it fails
        var sawEvent = false
        var exitSeen: Date?
        while true {
            var (lines, finished) = buffer.take()
            if first {
                first = false
                lines.removeSubrange(overlap(history: history, stream: lines))
                history = []
            }
            var raw: [String] = []
            for l in lines where !l.isEmpty {
                let st = stamp(l)
                if st != nil { sawEvent = true }
                if !sawEvent, preamble.count < 5, !l.hasPrefix("Filtering the log data"), !l.hasPrefix("Timestamp") {
                    preamble.append(String(l))
                }
                raw.append(String(l))
                // Not a continuation of the history's last event, which comes just before it.
                if l.hasPrefix("Filtering the log data") { continue }
                parser.feed(l)
            }
            let new = parser.drain()
            if !new.isEmpty || !raw.isEmpty { await session.receive(id, new, raw: raw, historyDone: false, note: nil) }
            if let f = finished {
                if !flag.isCancelled {
                    var n = f.error ?? "log stream ended (status \(f.status))."
                    if f.error == nil, !preamble.isEmpty { n += " " + preamble.joined(separator: " ") }
                    endNote = endNote ?? n
                }
                break
            }
            // The process's last lines can arrive just after it exits: give them a moment.
            if exitSeen == nil, !Native.isSame(pid, start: start) { exitSeen = Date() }
            if let t = exitSeen, Date().timeIntervalSince(t) > 1, !flag.isCancelled {
                endNote = "The process exited."
                flag.cancel()
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        await session.finishLive(id, note: endNote)
    }

    /// The stream's lines that repeat the end of the history: the longest run of events that ends the
    /// history and starts the stream. Matched on everything but the timestamp, because the two tools stamp
    /// the same event differently: `log show` 56 ms (55–57) later than `log stream` on this Mac, in the
    /// same order. A run only counts if its first event's two stamps are within a second of each other,
    /// so a stream that starts with a repeat of the history's last message (one logged every second, say)
    /// isn't mistaken for an overlap.
    nonisolated static func overlap(history: [Substring], stream: [Substring]) -> Range<Int> {
        struct Event { var sig: String; var stamp: Substring; var lines: Range<Int> }
        func events(_ lines: [Substring]) -> [Event] {
            var out: [Event] = []
            for (i, l) in lines.enumerated() {
                if let st = stamp(l) {
                    out.append(Event(sig: String(l[st.endIndex...]), stamp: st, lines: i..<i + 1))
                } else if !out.isEmpty, !l.isEmpty {
                    out[out.count - 1].sig += "\n" + l
                    out[out.count - 1].lines = out[out.count - 1].lines.lowerBound..<i + 1
                }
            }
            return out
        }
        let h = events(history), p = events(stream)
        guard !h.isEmpty, !p.isEmpty else { return 0..<0 }
        // KMP: the longest prefix of the stream's events that is a suffix of the history's.
        var pi = [Int](repeating: 0, count: p.count)
        var k = 0
        for i in 1..<max(p.count, 1) {
            while k > 0 && p[i].sig != p[k].sig { k = pi[k - 1] }
            if p[i].sig == p[k].sig { k += 1 }
            pi[i] = k
        }
        var q = 0
        for e in h {
            while q > 0 && (q == p.count || e.sig != p[q].sig) { q = pi[q - 1] }
            if e.sig == p[q].sig { q += 1 }
        }
        // Shorter runs that also fit, longest first, until one passes the time check.
        while q > 0 {
            if let a = seconds(h[h.count - q].stamp), let b = seconds(p[0].stamp), abs(a - b) < 1 { break }
            q = pi[q - 1]
        }
        return q == 0 ? 0..<0 : p[0].lines.lowerBound..<p[q - 1].lines.upperBound
    }

    private nonisolated static func seconds(_ stamp: Substring) -> Double? {
        guard let d = stampFormatter.date(from: String(stamp.prefix(19))) else { return nil }
        return d.timeIntervalSinceReferenceDate + (Double("0" + stamp.dropFirst(19)) ?? 0)
    }

    private nonisolated static let stampFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()

    /// "yyyy-MM-dd HH:mm:ss.SSS…" at the start of an event line.
    private nonisolated static func stamp(_ line: Substring) -> Substring? {
        guard line.utf8.count > 20, line.utf8.first.map({ $0 >= 0x30 && $0 <= 0x39 }) == true,
              let sp = line.dropFirst(11).firstIndex(of: " ") else { return nil }
        return line[..<sp]
    }

    private func receive(_ id: Int, _ new: [LogEntry], raw: [String], historyDone: Bool, note: String?) {
        guard id == runID else { return }
        if historyDone { loadingHistory = false }
        if let note { notes.append(note) }
        for e in new {
            // An entry handed over again: a continuation line extended its message.
            if let last = entries.last, last.id == e.id { entries[entries.count - 1] = e } else { entries.append(e) }
        }
        if entries.count > Self.cap {
            // Drop in slabs of 10%, not one by one: removeFirst is O(n).
            let cut = entries.count - Self.cap + Self.cap / 10
            entries.removeFirst(cut)
            dropped += cut
        }
        rawLines.append(contentsOf: raw)
        if rawLines.count > Self.cap { rawLines.removeFirst(rawLines.count - Self.cap + Self.cap / 10) }
        if !new.isEmpty || historyDone { revision += 1 }
    }

    private func finishLive(_ id: Int, note: String?) {
        guard id == runID else { return }
        if let note { notes.append(note) }
        isActive = false; stopping = false; loadingHistory = false
        revision += 1
    }
}

/// Lines from the stream's reader thread, picked up by the session's loop.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [Substring] = []
    private var any = false
    private var result: (status: Int32, error: String?)?

    func add(_ l: [Substring]) { lock.lock(); lines += l; any = true; lock.unlock() }
    func finish(_ r: (status: Int32, error: String?)) { lock.lock(); result = r; lock.unlock() }
    var hasOutput: Bool { lock.lock(); defer { lock.unlock() }; return any }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return result != nil }
    /// Everything so far, and the stream's end once it has ended and every line before it was taken.
    func take() -> ([Substring], (status: Int32, error: String?)?) {
        lock.lock(); defer { lock.unlock() }
        let l = lines
        lines = []
        return (l, result)
    }
}

struct LogsPane: View {
    let proc: ProcInfo
    let exited: Bool
    @State private var session = LogSession()
    @State private var filter = ""
    @AppStorage("logs.follow") private var follow = true
    @AppStorage("showRawOutput") private var showRaw = false

    private var title: String {
        let pid = proc.pid
        return session.started && session.mode == .live
            ? "/usr/bin/log stream — events from pid \(pid), after the last 10 minutes of them"
            : "/usr/bin/log show --last 10m — events from pid \(pid) or mentioning it"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !session.notes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(session.notes, id: \.self) { Text($0) }
                }
                .font(.caption).foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.bottom, 4)
            }
            Divider()
            content
        }
        .onDisappear { session.stop() }   // window closed or pane switched: don't let the tool run on
    }

    private var header: some View {
        HStack {
            RawToggle(showRaw: $showRaw)
            Text(title).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).truncationHelp(title)
            Spacer()
            if session.mode == .live && session.isActive && !session.loadingHistory {
                Label("Live", systemImage: "circle.fill").font(.caption).foregroundStyle(.red)
                    .labelStyle(.titleAndIcon).imageScale(.small)
            }
            if session.mode == .live && session.started {
                Toggle("Follow", isOn: $follow).toggleStyle(.checkbox).font(.caption)
                    .help("Keep the newest event in view")
            }
            TextField(showRaw ? "filter lines" : "filter", text: $filter).textFieldStyle(.roundedBorder).frame(width: 180)
            // `log show` reads history, not the process, so Run still works after an exit.
            Button(session.started && session.mode == .snapshot ? "Re-run" : "Run") { session.runSnapshot(pid: proc.pid) }
                .disabled(session.isActive)
                .help("The last 10 minutes of this process's events, and others' that mention its pid")
            if session.mode == .live && session.isActive {
                Button { session.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .disabled(session.stopping)
            } else {
                Button { session.startLive(pid: proc.pid, start: proc.start) } label: {
                    Label("Live", systemImage: "dot.radiowaves.left.and.right")
                }
                .disabled(session.isActive || exited)
                .help(exited ? InspectorView.exitedNote
                      : "This process's events from the last 10 minutes, then new ones as it logs them (log stream). "
                        + "log stream can't stream state dumps (Sd): only the history has them.")
            }
            if session.isActive && (session.mode == .snapshot || session.loadingHistory) { ProgressView().controlSize(.small) }
        }
        .padding(6)
    }

    @ViewBuilder private var content: some View {
        if !session.started {
            VStack(spacing: 8) {
                Image(systemName: "play.circle").font(.largeTitle).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if session.isActive && (session.mode == .snapshot || (session.loadingHistory && session.entries.isEmpty)) {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if showRaw {
            MonoText(text: filterLines(session.raw, filter))
        } else if session.mode == .snapshot && session.entries.isEmpty {
            UnparsedNote(raw: session.rawText)
        } else {
            // The visual view stays alive under Raw in CommandTab; here the session keeps the data,
            // so it can simply be rebuilt.
            LogView(entries: session.entries, filter: filter, revision: session.revision,
                    follow: session.mode == .live && follow, dropped: session.dropped)
                .id(session.runID)
                .overlay {
                    if session.entries.isEmpty {
                        Text(session.isActive ? "No events yet — new ones appear here as pid \(proc.pid) logs them."
                                              : "No events.")
                            .foregroundStyle(.secondary)
                    }
                }
        }
    }
}
