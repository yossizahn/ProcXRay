import Foundation
import XCTest
@testable import ProcXRay

final class ByteSearchTests: XCTestCase {
    /// Same answers as Foundation's search, including non-ASCII paths, substrings and bridged strings.
    func testMatchesFoundation() {
        let paths = [
            "/Applications/Safari.app/Contents/MacOS/Safari",
            "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator",
            "/Applications/Café ☕️.app/Contents/PlugIns/Wïdget.appex/Contents/MacOS/Wïdget",
            "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/x",
            "/usr/libexec/app", ".app/", "", "a.ap", "🎉.app/🎉.app/x",
            NSString(string: "/Applications/Ñandú.app/Contents/MacOS/Ñandú") as String,
        ]
        for p in paths {
            for needle in [".app/", ".appex/", "/XPCServices/", ".xpc/Contents/MacOS/"] {
                for back in [false, true] {
                    let want = p.range(of: needle, options: back ? .backwards : [])
                    XCTAssertEqual(p.byteRange(of: needle, backwards: back), want, "\(p) \(needle) \(back)")
                    if let r = want { XCTAssertEqual(String(p[..<r.lowerBound]), String(p[..<p.byteRange(of: needle, backwards: back)!.lowerBound])) }
                }
                XCTAssertEqual(p.containsBytes(needle), p.contains(needle))
                let sub = p.dropFirst(min(3, p.count))
                XCTAssertEqual(sub.byteRange(of: needle, backwards: true), sub.range(of: needle, options: .backwards), "\(sub) \(needle)")
            }
        }
        XCTAssertEqual(SmartTree.enclosingApps("/A.app/Contents/B.app/Contents/MacOS/b"), ["/A.app/Contents/B.app", "/A.app"])
    }
}
