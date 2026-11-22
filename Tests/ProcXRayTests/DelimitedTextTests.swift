import XCTest
@testable import ProcXRay

final class DelimitedTextTests: XCTestCase {
    func testTabSeparatedKeepsOneCellPerColumn() {
        let text = DelimitedText.join([["Label", "PID"], ["a\tb", "1"], ["two\nlines", "2"]], separator: "\t")
        XCTAssertEqual(text, "Label\tPID\na b\t1\ntwo lines\t2")
    }

    func testCSVQuotesWhatNeedsIt() {
        let text = DelimitedText.join([["Name", "Path"], ["plain", "/usr/bin/x"], ["a, b", "say \"hi\""], ["two\nlines", ""]], separator: ",")
        XCTAssertEqual(text, "Name,Path\nplain,/usr/bin/x\n\"a, b\",\"say \"\"hi\"\"\"\n\"two\nlines\",")
    }
}
