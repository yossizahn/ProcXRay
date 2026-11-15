import Foundation

/// Tools the helper answers from the kernel itself instead of running Apple's tool. Each returns the tool's own text
/// layout, so parsers, views and the Raw switch stay as they are; nil falls back to the tool. Gated at run time: the
/// task-port readers only answer when SIP allows task_for_pid (SystemSecurity), so on a normal Mac they return nil
/// at once; lsof only needs root, which the helper has. PROCXRAY_APPLE_TOOLS=1 in the environment forces Apple's
/// tools, for comparing the two.
enum NativeTools {
    static let enabled = ProcessInfo.processInfo.environment["PROCXRAY_APPLE_TOOLS"] == nil

    static func run(_ tool: HelperTool, pid: Int32) -> String? {
        guard enabled else { return nil }
        switch tool {
        case .vmmap: return NativeVMMap.summary(pid)
        case .taskinfo: return NativeTaskinfo.text(pid)
        case .lsof: return NativeLsof.table(pid)
        case .stacks: return NativeSample.text(pid)
        case .lsofAll: return NativeLsof.fields()
        default: return nil
        }
    }
}
