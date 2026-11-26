import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A saved trace's file, the value a trace window is opened for.
struct SavedTraceRef: Hashable, Codable {
    var path: String
}

/// Opening saved traces (.pxrtrace): File ▸ Open Trace…, Finder, a Dock drop.
enum SavedTraceFiles {
    static let contentType = UTType(exportedAs: SavedTrace.typeIdentifier, conformingTo: .data)

    static func isTrace(_ path: String) -> Bool { (path as NSString).pathExtension.lowercased() == SavedTrace.fileExtension }

    @MainActor static func open(_ path: String, _ openWindow: OpenWindowAction? = nil) {
        guard let open = openWindow ?? AppRouter.openWindow else { return }
        open(id: SavedTraceWindow.id, value: SavedTraceRef(path: path))
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor static func openPanel(_ openWindow: OpenWindowAction) {
        let p = NSOpenPanel()
        p.title = "Open Trace"
        p.message = "Choose a syscall trace saved by Proc X-Ray."
        p.allowedContentTypes = [contentType]
        p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return }
        for u in p.urls { open(u.path, openWindow) }
    }
}

/// File ▸ Open Trace… (⌘O).
struct OpenTraceCommand: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Trace…") { SavedTraceFiles.openPanel(openWindow) }
                .keyboardShortcut("o")
        }
    }
}

/// A saved trace, in the views a live one has (Activity, Calls, Lanes, Summary), read off the main thread.
struct SavedTraceWindow: View {
    static let id = "savedTrace"
    @Binding var ref: SavedTraceRef?
    @State private var loaded: Result<(SavedTrace, SyscallTracer), Error>?

    var body: some View {
        Group {
            switch loaded {
            case nil:
                ProgressView("Opening the trace…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failure(let e):
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.secondary)
                    Text("The trace couldn't be opened").font(.headline)
                    Text(e.localizedDescription).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .success(let (t, tracer)):
                SyscallTraceView(target: t.target, exited: true, tracer: tracer)
            }
        }
        .frame(minWidth: 700, minHeight: 420)
        .navigationTitle(title)
        .task(id: ref?.path) {
            guard let path = ref?.path else { return }
            loaded = nil
            let read = await Task.detached(priority: .userInitiated) {
                Result { try SavedTrace.decode(Data(contentsOf: URL(fileURLWithPath: path))) }
            }.value
            loaded = read.map { ($0, SyscallTracer.opened($0, from: URL(fileURLWithPath: path))) }
        }
    }

    private var title: String {
        guard let path = ref?.path else { return "Trace" }
        let file = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        if case .success(let (t, _)) = loaded { return "\(t.target.name) — \(file)" }
        return file
    }
}
