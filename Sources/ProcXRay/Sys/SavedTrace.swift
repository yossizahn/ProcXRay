import Foundation

/// A syscall trace saved to a file (.pxrtrace) to open again: the calls as decoded, with every name the trace
/// worked out while it ran (message destinations, descriptors and socket peers, thread names, the frames of its
/// stacks), so it opens as it was recorded, on another boot or another Mac. Only Proc X-Ray reads it: a magic
/// line, then LZFSE-compressed JSON.
struct SavedTrace: Codable, Sendable {
    static let fileExtension = "pxrtrace"
    static let typeIdentifier = "local.procxray.trace"
    static let currentVersion = 1

    var version = Self.currentVersion
    var target: TraceTarget
    var saved: Date
    /// The system it was recorded on: "macOS 27.2 (26B123)".
    var system: String
    var records: [SyscallRecord]
    /// Calls still in the kernel when the trace stopped.
    var pending: [SyscallRecord]
    var notes: [String]
    var events: Int
    /// Oldest calls let go during the trace to bound its memory.
    var dropped: Int
    var context: SyscallActivity.Context
    var cpu: TraceCPU
    var withStacks: Bool
    var hasCallers: Bool
    var frames: [StackSymbols.SavedFrame]

    enum Failure: LocalizedError {
        case notATrace, newer(Int)
        var errorDescription: String? {
            switch self {
            case .notATrace: "This isn't a Proc X-Ray trace."
            case .newer(let v): "This trace was saved by a newer Proc X-Ray (format \(v)); update the app to open it."
            }
        }
    }

    private static let magic = Data("PXRTRACE\n".utf8)

    func encoded() throws -> Data {
        let json = try JSONEncoder().encode(self)
        return Self.magic + (try (json as NSData).compressed(using: .lzfse) as Data)
    }

    static func decode(_ data: Data) throws -> SavedTrace {
        guard data.starts(with: magic) else { throw Failure.notATrace }
        let json = try (Data(data.dropFirst(magic.count)) as NSData).decompressed(using: .lzfse) as Data
        // The version first: a newer format may not decode as this one at all.
        struct Header: Decodable { var version: Int }
        let v = try JSONDecoder().decode(Header.self, from: json).version
        guard v <= currentVersion else { throw Failure.newer(v) }
        return try JSONDecoder().decode(SavedTrace.self, from: json)
    }

    static var thisSystem: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var build = [CChar](repeating: 0, count: 32)
        var len = build.count
        let b = sysctlbyname("kern.osversion", &build, &len, nil, 0) == 0 ? " (" + String(cString: build) + ")" : ""
        return "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "") + b
    }
}
