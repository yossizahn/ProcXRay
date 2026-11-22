import XCTest
@testable import ProcXRay

final class HeapParserTests: XCTestCase {
    /// Trimmed `heap <pid>` output from macOS 27.2: header, size histogram, then the class table, including an
    /// untyped row with no TYPE or BINARY and a name that overflows its column.
    static let sample = """
    Process:         t [6529]
    Path:            /private/tmp/*/t
    Identifier:      t
    Analysis Tool:   /usr/bin/heap

    Physical footprint:         1744K
    Physical footprint (peak):  1744K
    Idle exit:                  untracked
    ----

    Process 6529: 2 zones

    All zones: 950 nodes malloced - Sizes: 10KB[1] 2.5KB[1] 896[1] 32[263] 16[221] 

    Found:  165 ObjC classes  43 Swift classes  12 C++ classes  66 CFTypes
    Type names for non-objects could be derived from allocation backtraces if the process used MallocStackLogging

    -----------------------------------------------------------------------
    All zones: 950 nodes (107056 bytes)

       COUNT      BYTES       AVG   CLASS_NAME                                        TYPE    BINARY
       =====      =====       ===   ==========                                        ====    ======
         205       6560      32.0   Metaclass.data (metaclass_rw_v2_t)                C       libobjc.A.dylib
         140      37888     270.6   non-object                                                
           2        192      96.0   Swift._ContiguousArrayStorage<Swift.Array<Swift.UInt8>>  Swift   libswiftCore.dylib
           4        448     112.0   CGColorSpace                                      CFType  CoreGraphics
           1        160     160.0   Helper                                            Swift   Proc X-Ray Dev
          67     100544    1500.7   __DataStorage._bytes (malloc)                             Foundation
           3       1088     362.7   NetworkAgent.NetworkAgentBackingClass.data._position (malloc)          Network
    """

    func testParsesReport() {
        let r = HeapParser.parse(Self.sample)
        XCTAssertEqual(r.footprint, 1744 << 10)
        XCTAssertEqual(r.zoneCount, 2)
        XCTAssertEqual(r.totalNodes, 950)
        XCTAssertEqual(r.totalBytes, 107056)
        XCTAssertEqual(r.sizes.map(\.size), [10240, 2560, 896, 32, 16])
        XCTAssertEqual(r.sizes.map(\.count), [1, 1, 1, 263, 221])
        XCTAssertEqual(r.found.map(\.1), [165, 43, 12, 66])
        XCTAssertEqual(r.found[2].0, "C++ classes")
        XCTAssertEqual(r.notes.count, 1)
        XCTAssertEqual(r.classes.count, 7)

        let c = r.classes
        XCTAssertEqual(c[0].name, "Metaclass.data (metaclass_rw_v2_t)")
        XCTAssertEqual(c[0].type, "C")
        XCTAssertEqual(c[0].binary, "libobjc.A.dylib")
        XCTAssertEqual(c[0].count, 205)
        XCTAssertEqual(c[0].bytes, 6560)
        XCTAssertTrue(c[1].isUntyped)
        XCTAssertEqual(c[1].binary, "")
        XCTAssertEqual(c[1].average, 270.6)
        XCTAssertEqual(c[2].name, "Swift._ContiguousArrayStorage<Swift.Array<Swift.UInt8>>")
        XCTAssertEqual(c[2].type, "Swift")
        XCTAssertEqual(c[3].type, "CFType")
        XCTAssertEqual(c[4].binary, "Proc X-Ray Dev")
        XCTAssertEqual(c[5].name, "__DataStorage._bytes (malloc)")
        XCTAssertEqual(c[5].type, "")
        XCTAssertEqual(c[5].binary, "Foundation")
        XCTAssertFalse(c[5].isUntyped)
        XCTAssertEqual(c[6].name, "NetworkAgent.NetworkAgentBackingClass.data._position (malloc)")
        XCTAssertEqual(c[6].binary, "Network")
    }

    func testErrorOutputIsEmpty() {
        XCTAssertTrue(HeapParser.parse("heap[123]: process 99 not found\n").isEmpty)
    }
}
