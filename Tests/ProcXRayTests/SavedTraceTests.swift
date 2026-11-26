import XCTest
@testable import ProcXRay

final class SavedTraceTests: XCTestCase {
    private func sample() -> SavedTrace {
        var r = SyscallRecord(id: 7, start: 100, end: 250, thread: 0x9_9999, mach: true, number: -31, name: "mach_msg2_trap",
                              args: [0x16b5_64c4_0, UInt64.max, 0x5c_0000_0000, 0x17f5f])
        r.stack = [0x1_8000_1234, 0x1_0000_3100 | 0]
        r.kernelRoutine = 12
        r.receiver = 443
        r.cpu = 80
        r.blocked = false
        r.caller = "IOServiceGetMatchingServices  (IOKit)"
        r.api = "IOServiceGetMatchingServices  (IOKit)"; r.site = "App + 0xa29068"
        r.trigger = "dispatch source · App + 0x3883dc"; r.triggerInner = "App + 0xd12d10"
        r.firstFDLabel = "/tmp/a"
        r.paths = ["/tmp/a", "/tmp/b"]
        r.argValues = ["0x16b564c40", "…"]
        r.resultText = "KERN_SUCCESS"
        r.expected = true
        var pending = SyscallRecord(id: 8, start: 300, end: nil, thread: 1, mach: false, number: 3, name: "read", args: nil)
        pending.state = .inProgress
        var context = SyscallActivity.Context(pid: 42, ports: [0x17f5f: 443], processNames: [443: "WindowServer"],
                                              portKinds: [0x203: "task port"], threadNames: [0x9_9999: "main thread"])
        context.cwd = "/Users/x"
        var cpu = TraceCPU()
        cpu.add([SyscallDecoder.Run(thread: 0x9_9999, start: 10, end: 90)], open: [], measured: true)
        let frame = StackSymbols.Frame(image: "IOKit", symbol: "IOServiceGetMatchingServices", offset: 220, address: 0x1_8000_1234, system: true)
        return SavedTrace(target: TraceTarget(pid: 42, start: Date(timeIntervalSince1970: 1_800_000_000), name: "BetterDisplay"),
                          saved: Date(timeIntervalSince1970: 1_800_000_100), system: "macOS 27.2 (26B123)",
                          records: [r], pending: [pending], notes: ["a note"], events: 1234, dropped: 5, context: context,
                          cpu: cpu, withStacks: true, hasCallers: true, frames: [.init(key: 0x1_8000_1234, frame: frame)])
    }

    /// Everything a trace view shows comes back as saved: 64-bit arguments, the names, the CPU runs, the frames.
    func testRoundTrip() throws {
        let t = sample()
        let back = try SavedTrace.decode(try t.encoded())
        XCTAssertEqual(back.records, t.records)
        XCTAssertEqual(back.records[0].args?[1], UInt64.max)
        XCTAssertEqual(back.pending, t.pending)
        XCTAssertEqual(back.target, t.target)
        XCTAssertEqual(back.context.ports, [0x17f5f: 443])
        XCTAssertEqual(back.context.processNames, [443: "WindowServer"])
        XCTAssertEqual(back.context.threadNames, [0x9_9999: "main thread"])
        XCTAssertEqual(back.context.cwd, "/Users/x")
        XCTAssertEqual(back.cpu.total(0x9_9999), 80)
        XCTAssertEqual(back.frames.first?.frame.short, "IOServiceGetMatchingServices  (IOKit)")
        XCTAssertEqual(back.system, "macOS 27.2 (26B123)")
        XCTAssertEqual([back.events, back.dropped], [1234, 5])
    }

    func testRejectsOtherFilesAndNewerFormats() throws {
        XCTAssertThrowsError(try SavedTrace.decode(Data("hello".utf8))) {
            XCTAssertEqual($0.localizedDescription, SavedTrace.Failure.notATrace.localizedDescription)
        }
        var newer = sample()
        newer.version = SavedTrace.currentVersion + 1
        XCTAssertThrowsError(try SavedTrace.decode(try newer.encoded())) {
            XCTAssertTrue($0.localizedDescription.contains("newer Proc X-Ray"))
        }
    }

    /// An opened trace shows the saved calls and frame names, and never traces or clears.
    @MainActor func testOpenedTracer() {
        let t = sample()
        let tracer = SyscallTracer.opened(t, from: URL(fileURLWithPath: "/tmp/x.pxrtrace"))
        XCTAssertEqual(tracer.phase, .stopped)
        XCTAssertEqual(tracer.records.map(\.id), [7])
        XCTAssertEqual(tracer.symbols.frame(0x1_8000_1234, isReturn: false).short, "IOServiceGetMatchingServices  (IOKit)")
        tracer.clear()
        XCTAssertEqual(tracer.records.count, 1)
        tracer.start(pid: 42, start: Date(), stacks: false)
        XCTAssertEqual(tracer.phase, .stopped)
        let again = tracer.saved(target: t.target)
        XCTAssertEqual(again.system, t.system)
        XCTAssertEqual(again.records, t.records)
    }
}
