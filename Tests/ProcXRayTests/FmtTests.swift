import XCTest
@testable import ProcXRay

final class FmtTests: XCTestCase {
    /// Fmt.bytesText stands in for ByteCountFormatter where numbers are written the English way: it must give
    /// the same text, at the unit boundaries, at rounding ties and everywhere between.
    func testBytesTextMatchesTheSystemFormatter() throws {
        let l = Locale.current
        try XCTSkipUnless(l.language.languageCode?.identifier == "en" && l.decimalSeparator == "." && l.groupingSeparator == ",",
                          "the system formatter is used as is in this locale")
        var values: [UInt64] = [1, 2, 512, 999, 1000, 1023, 1024, 1025, 1535, 1536, 1537, 2560, 3584, 10_000, 1_023_999, 1_048_063, 1_048_064,
                                1_048_575, 1_048_576, 1_100_000, 5_293_880, 5_295_308, 5_295_309, 12_882_912, 1_049_176_000, 1_072_693_248,
                                1_073_741_823, 1_073_741_824, 1_610_612_736, 10_787_418_240, 1_099_511_627_776, 1_649_267_441_664]
        // Around every power of 1024 and its rounding edges, up to terabytes: at petabytes a value a hair under a
        // tie (1.00499999999999989 PB) is rounded up by the system's own arithmetic, which isn't worth copying.
        for p in 1...4 {
            let unit = UInt64(1) << UInt64(10 * p)
            for m in [1, 2, 9, 10, 99, 100, 999, 1000, 1023] as [UInt64] {
                for d in [-2, -1, 0, 1, 2] as [Int64] {
                    values.append(UInt64(Int64(unit * m) + d))
                    values.append(UInt64(Int64(unit * m + unit / 2) + d))
                    values.append(UInt64(Int64(unit * m + unit / 20) + d))
                    values.append(UInt64(Int64(unit * m + unit / 200) + d))
                }
            }
        }
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<60_000 {
            let bits = UInt64.random(in: 1...52, using: &rng)
            values.append(UInt64.random(in: 1...(UInt64(1) << bits), using: &rng))
        }
        var wrong: [String] = []
        for v in values where Fmt.bytesText(v) != Fmt.systemBytes(v) {
            wrong.append("\(v): \(Fmt.bytesText(v)) ≠ \(Fmt.systemBytes(v))")
            if wrong.count >= 12 { break }
        }
        XCTAssertTrue(wrong.isEmpty, wrong.joined(separator: "\n"))
    }
}
