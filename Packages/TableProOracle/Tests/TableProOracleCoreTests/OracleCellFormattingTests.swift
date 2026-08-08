import XCTest
@testable import TableProOracleCore

final class OracleCellFormattingTests: XCTestCase {
    private static let referenceDate: Date = {
        var components = DateComponents()
        components.year = 2_026
        components.month = 5
        components.day = 3
        components.hour = 12
        components.minute = 29
        components.second = 44
        components.nanosecond = 123_000_000
        components.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar(identifier: .gregorian).date(from: components) ?? Date(timeIntervalSince1970: 0)
    }()

    func testDateRendersAsCalendarDay() {
        XCTAssertEqual(OracleCellFormatting.formatDate(Self.referenceDate), "2026-05-03")
    }

    func testTimestampUTC() {
        let result = OracleCellFormatting.formatTimestamp(Self.referenceDate, style: .utc)
        XCTAssertEqual(result, "2026-05-03T12:29:44.123Z")
    }

    func testTimestampLocalMatchesHostOffset() {
        let result = OracleCellFormatting.formatTimestamp(Self.referenceDate, style: .local)
        let offsetSeconds = TimeZone.current.secondsFromGMT(for: Self.referenceDate)
        let expectedSuffix = offsetSeconds == 0 ? "Z" : Self.isoOffset(seconds: offsetSeconds)
        XCTAssertTrue(result.hasSuffix(expectedSuffix), "expected \(expectedSuffix) at end of \(result)")
    }

    func testTimestampZonedAlwaysCarriesAnExplicitOffset() {
        let result = OracleCellFormatting.formatTimestamp(Self.referenceDate, style: .zoned)
        let offsetSeconds = TimeZone.current.secondsFromGMT(for: Self.referenceDate)
        XCTAssertTrue(
            result.hasSuffix(Self.isoOffset(seconds: offsetSeconds)),
            "zoned style must spell the offset out even at UTC, got \(result)"
        )
    }

    private static func isoOffset(seconds: Int) -> String {
        let magnitude = abs(seconds)
        return String(
            format: "%@%02d:%02d",
            seconds >= 0 ? "+" : "-",
            magnitude / 3_600,
            (magnitude % 3_600) / 60
        )
    }

    func testIntervalMillisecondsTrimToSignificantDigits() {
        let result = OracleCellFormatting.formatIntervalDS(
            days: 2, hours: 3, minutes: 4, seconds: 5, nanoseconds: 678_000_000
        )
        XCTAssertEqual(result, "2 03:04:05.678")
    }

    func testIntervalPreservesNanosecondPrecision() {
        let result = OracleCellFormatting.formatIntervalDS(
            days: 0, hours: 0, minutes: 0, seconds: 0, nanoseconds: 123_456_789
        )
        XCTAssertEqual(result, "0 00:00:00.123456789")
    }

    func testNegativeIntervalPrefixesSingleMinus() {
        let result = OracleCellFormatting.formatIntervalDS(
            days: -1, hours: -2, minutes: -3, seconds: -4, nanoseconds: -50_000_000
        )
        XCTAssertEqual(result, "-1 02:03:04.05")
    }

    func testZeroFractionalDropsDecimalPoint() {
        let result = OracleCellFormatting.formatIntervalDS(
            days: 5, hours: 3, minutes: 14, seconds: 0, nanoseconds: 0
        )
        XCTAssertEqual(result, "5 03:14:00")
    }

    func testZeroIntervalHasNoSignAndNoDecimal() {
        let result = OracleCellFormatting.formatIntervalDS(
            days: 0, hours: 0, minutes: 0, seconds: 0, nanoseconds: 0
        )
        XCTAssertEqual(result, "0 00:00:00")
    }

    func testIntervalYearToMonthPositive() {
        XCTAssertEqual(OracleCellFormatting.formatIntervalYM(years: 5, months: 3), "5-03")
    }

    func testIntervalYearToMonthNegative() {
        XCTAssertEqual(OracleCellFormatting.formatIntervalYM(years: -2, months: -7), "-2-07")
    }

    func testIntervalYearToMonthZero() {
        XCTAssertEqual(OracleCellFormatting.formatIntervalYM(years: 0, months: 0), "0-00")
    }

    func testHexEncodeProducesLowercaseBytes() {
        XCTAssertEqual(OracleCellFormatting.hexEncode([0x00, 0xff, 0xab, 0x10]), "00ffab10")
    }

    func testHexEncodeEmptyInput() {
        XCTAssertEqual(OracleCellFormatting.hexEncode([]), "")
    }

    func testHexEncodeTruncatesAndReportsTotalSize() {
        let result = OracleCellFormatting.hexEncode([UInt8](repeating: 0xab, count: 5_000))
        XCTAssertTrue(result.hasSuffix("… (5000 bytes)"))
        let hexPart = result.replacingOccurrences(of: "… (5000 bytes)", with: "")
        XCTAssertEqual(hexPart.count, OracleCellFormatting.maxHexBytes * 2)
    }

    func testUnsupportedPlaceholderEmbedsTypeName() {
        XCTAssertEqual(
            OracleCellFormatting.unsupportedPlaceholder(typeName: "interval year to month"),
            "<unsupported: interval year to month>"
        )
    }
}
