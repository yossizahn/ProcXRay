import XCTest
@testable import ProcXRay

final class FunctionMapTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fnmap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [tool] + args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin") + ":" + NSHomeDirectory() + "/.cargo/bin"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw XCTSkip("\(tool) \(args.first ?? "") failed") }
        return String(decoding: data, as: UTF8.self)
    }

    /// Builds `source` with `compile`, notes where the functions whose nm line contains each name are, strips it.
    private func stripped(_ name: String, _ source: String, compile: (URL, URL) throws -> Void,
                          find: [String]) throws -> (URL, [UInt64]) {
        let src = dir.appendingPathComponent(name), bin = dir.appendingPathComponent("bin-" + name)
        try source.write(to: src, atomically: true, encoding: .utf8)
        try compile(src, bin)
        let nm = try run("nm", ["-U", bin.path]).split(separator: "\n")
        let offsets = try find.map { f in
            let line = try XCTUnwrap(nm.first { $0.contains(f) }, f)
            return try XCTUnwrap(UInt64(line.split(separator: " ")[0], radix: 16)) - 0x1_0000_0000
        }
        try run("strip", [bin.path])
        XCTAssertFalse(try run("nm", [bin.path]).contains(find[0]))
        return (bin, offsets)
    }

    /// A stripped program's function is named by its start and the sentence it logs; every place in it gets the
    /// same name, and code outside __text gets none.
    func testStrippedFunctionsNamedByWhatTheyReferTo() throws {
        let (bin, at) = try stripped("t.c", """
        #include <stdio.h>
        __attribute__((noinline)) void poll_displays(int n) {
            for (int i = 0; i < n; i++) puts("Poll framebuffer identities");
            puts("done");
        }
        __attribute__((noinline)) void quiet(void) { __asm__ volatile("nop"); }
        int main(int argc, char **argv) { poll_displays(argc); quiet(); return 0; }
        """, compile: { try self.run("xcrun", ["clang", "-O1", "-arch", "arm64", "-o", $1.path, $0.path]) },
        find: [" _poll_displays", " _quiet"])
        let poll = at[0], quiet = at[1]
        let map = try XCTUnwrap(FunctionMap(path: bin.path))
        let a = try XCTUnwrap(map.function(at: poll + 4)), b = try XCTUnwrap(map.function(at: poll + 12))
        XCTAssertEqual(a.start, poll)
        XCTAssertEqual(a.name, "fn_\(String(poll, radix: 16)) “Poll framebuffer identities”")
        XCTAssertEqual(b.name, a.name)
        XCTAssertEqual(map.function(at: quiet)?.name, "fn_\(String(quiet, radix: 16))")
        XCTAssertNil(map.function(at: 0))   // the Mach-O header, not code
        XCTAssertNil(FunctionMap(path: dir.appendingPathComponent("t.c").path))
    }

    /// Objective-C methods keep their names through stripping: instance, class and category methods.
    func testStrippedObjectiveCMethodsNamedExactly() throws {
        let (bin, at) = try stripped("t.m", """
        #import <Foundation/Foundation.h>
        @interface Poller : NSObject
        - (void)pollDisplays:(int)n;
        + (instancetype)shared;
        @end
        @implementation Poller
        - (void)pollDisplays:(int)n { for (int i = 0; i < n; i++) NSLog(@"Poll framebuffer identities"); }
        + (instancetype)shared { return [self new]; }
        @end
        @interface Poller (Extra)
        - (void)extra;
        @end
        @implementation Poller (Extra)
        - (void)extra { puts("extra"); }
        @end
        int main(int argc, char **argv) { @autoreleasepool { [[Poller shared] pollDisplays:argc]; [[Poller shared] extra]; } }
        """, compile: { try self.run("xcrun", ["clang", "-O1", "-arch", "arm64", "-fobjc-arc", "-framework", "Foundation",
                                               "-o", $1.path, $0.path]) },
        find: ["-[Poller pollDisplays:]", "+[Poller shared]", "-[Poller(Extra) extra]"])
        let map = try XCTUnwrap(FunctionMap(path: bin.path))
        XCTAssertEqual(map.function(at: at[0] + 4)?.name, "-[Poller pollDisplays:]")
        XCTAssertEqual(map.function(at: at[1])?.name, "+[Poller shared]")
        // ld merges a category on a class of the same image into the class's own list; one on another image's
        // class stays a category.
        XCTAssertTrue(["-[Poller extra]", "-[Poller(Extra) extra]"].contains(map.function(at: at[2] + 4)?.name ?? ""))
    }

    /// A stripped Rust function is named by the first panic location it refers to: its file and line.
    func testStrippedRustFunctionsNamedByPanicLocation() throws {
        let (bin, at) = try stripped("t.rs", """
        #[inline(never)]
        fn poll(v: &[u32]) -> u32 { v[3] + v[1] }
        fn main() {
            let v: Vec<u32> = std::env::args().map(|a| a.len() as u32).collect();
            println!("{}", poll(&v));
        }
        """, compile: { try self.run("rustc", ["-O", "--target", "aarch64-apple-darwin", "-o", $1.path, $0.path]) },
        find: ["4poll17h"])
        let map = try XCTUnwrap(FunctionMap(path: bin.path))
        let name = try XCTUnwrap(map.function(at: at[0] + 4)?.name)
        XCTAssertTrue(name.hasSuffix("/t.rs:2”"), name)
    }

    func testShortPathsAndSwiftClassNames() {
        XCTAssertEqual(FunctionMap.shortPath("/Users/x/.cargo/registry/src/index.crates.io-1949/tauri-2.1.0/src/app.rs"), "tauri-2.1.0/src/app.rs")
        XCTAssertEqual(FunctionMap.shortPath("/rustc/88d9e12a/library/core/src/option.rs"), "core/src/option.rs")
        XCTAssertEqual(FunctionMap.className("_TtC13BetterDisplay7AppCore"), "BetterDisplay.AppCore")
        XCTAssertEqual(FunctionMap.className("NSObject"), "NSObject")
        XCTAssertEqual(FunctionMap.className("_TtC3Bad"), "_TtC3Bad")
    }
}
