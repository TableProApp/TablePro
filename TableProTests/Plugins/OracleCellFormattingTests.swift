//
//  OracleCellFormattingTests.swift
//  TableProTests
//

import Foundation
import Testing

@Suite("Oracle cell formatting")
struct OracleCellFormattingTests {
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

    @Test("DATE renders as POSIX yyyy-MM-dd in UTC")
    func dateRendersAsCalendarDay() {
        let result = OracleCellFormatting.formatDate(Self.referenceDate)
        #expect(result == "2026-05-03")
    }

    @Test("TIMESTAMP UTC style renders ISO-8601 with Z and fractional seconds")
    func timestampUTC() {
        let result = OracleCellFormatting.formatTimestamp(Self.referenceDate, style: .utc)
        #expect(result == "2026-05-03T12:29:44.123Z")
    }

    @Test("TIMESTAMP zoned style renders explicit offset, never bare Z")
    func timestampZoned() {
        let result = OracleCellFormatting.formatTimestamp(Self.referenceDate, style: .zoned)
        #expect(!result.hasSuffix("Z"))
        #expect(result.contains("2026-05-03T"))
    }

    @Test("TIMESTAMP local style renders an offset matching the host's current zone")
    func timestampLocal() {
        let result = OracleCellFormatting.formatTimestamp(Self.referenceDate, style: .local)
        #expect(!result.hasSuffix("Z"))
        let expectedOffsetSeconds = TimeZone.current.secondsFromGMT(for: Self.referenceDate)
        let sign = expectedOffsetSeconds >= 0 ? "+" : "-"
        let offsetMagnitude = abs(expectedOffsetSeconds)
        let hours = offsetMagnitude / 3_600
        let minutes = (offsetMagnitude % 3_600) / 60
        let expectedOffset = String(format: "%@%02d%02d", sign, hours, minutes)
        #expect(result.hasSuffix(expectedOffset), "expected offset \(expectedOffset) at end of \(result)")
    }

    @Test("INTERVAL DAY TO SECOND with milliseconds trims to significant digits")
    func intervalMilliseconds() {
        let result = OracleCellFormatting.formatIntervalDS(
            days: 2, hours: 3, minutes: 4, seconds: 5, nanoseconds: 678_000_000
        )
        #expect(result == "2 03:04:05.678")
    }

    @Test("INTERVAL DAY TO SECOND preserves nanosecond precision when present")
    func intervalNanoseconds() {
        let result = OracleCellFormatting.formatIntervalDS(
            days: 0, hours: 0, minutes: 0, seconds: 0, nanoseconds: 123_456_789
        )
        #expect(result == "0 00:00:00.123456789")
    }

    @Test("Negative INTERVAL DAY TO SECOND prefixes a single minus sign")
    func intervalNegative() {
        let result = OracleCellFormatting.formatIntervalDS(
            days: -1, hours: -2, minutes: -3, seconds: -4, nanoseconds: -50_000_000
        )
        #expect(result == "-1 02:03:04.05")
    }

    @Test("Zero fractional component drops the decimal point entirely")
    func intervalZeroFractional() {
        let result = OracleCellFormatting.formatIntervalDS(
            days: 5, hours: 3, minutes: 14, seconds: 0, nanoseconds: 0
        )
        #expect(result == "5 03:14:00")
    }

    @Test("Zero INTERVAL DAY TO SECOND has no sign and no decimal")
    func intervalZero() {
        let result = OracleCellFormatting.formatIntervalDS(
            days: 0, hours: 0, minutes: 0, seconds: 0, nanoseconds: 0
        )
        #expect(result == "0 00:00:00")
    }

    @Test("Positive INTERVAL YEAR TO MONTH formats as Y-MM")
    func intervalYMPositive() {
        let result = OracleCellFormatting.formatIntervalYM(years: 5, months: 3)
        #expect(result == "5-03")
    }

    @Test("Negative INTERVAL YEAR TO MONTH prefixes a minus sign")
    func intervalYMNegative() {
        let result = OracleCellFormatting.formatIntervalYM(years: -2, months: -7)
        #expect(result == "-2-07")
    }

    @Test("Zero INTERVAL YEAR TO MONTH renders as 0-00")
    func intervalYMZero() {
        let result = OracleCellFormatting.formatIntervalYM(years: 0, months: 0)
        #expect(result == "0-00")
    }

    @Test("Hex encode produces lowercase concatenated bytes")
    func hexEncodeBasic() {
        let bytes: [UInt8] = [0x00, 0xff, 0xab, 0x10]
        #expect(OracleCellFormatting.hexEncode(bytes) == "00ffab10")
    }

    @Test("Hex encode is empty for empty input")
    func hexEncodeEmpty() {
        #expect(OracleCellFormatting.hexEncode([]) == "")
    }

    @Test("Hex encode truncates beyond 4 KB and reports total size")
    func hexEncodeTruncates() {
        let bytes = [UInt8](repeating: 0xab, count: 5_000)
        let result = OracleCellFormatting.hexEncode(bytes)
        #expect(result.hasSuffix("… (5000 bytes)"))
        let hexPart = result.replacingOccurrences(of: "… (5000 bytes)", with: "")
        #expect(hexPart.count == OracleCellFormatting.maxHexBytes * 2)
    }

    @Test("Unsupported placeholder embeds the type name verbatim")
    func unsupportedPlaceholder() {
        #expect(OracleCellFormatting.unsupportedPlaceholder(typeName: "interval year to month")
            == "<unsupported: interval year to month>")
    }
}
