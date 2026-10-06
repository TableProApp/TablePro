@testable import TableProOracleCore
import XCTest

/// Wire bytes measured on Oracle 23ai, with a session time zone of +07:00 and a database time zone of +00:00.
final class OracleCellFormattingTests: XCTestCase {
    /// 2024-01-02 03:04:05, the date and time every TIMESTAMP case below starts from.
    private static let wholeSecond: [UInt8] = [0x78, 0x7c, 0x01, 0x02, 0x04, 0x05, 0x06]

    private static func timestamp(nanoseconds: [UInt8]) -> [UInt8] {
        wholeSecond + nanoseconds
    }

    /// Oracle's DATE always carries a time of day, and dropping it lost the time from every read.
    func testDateKeepsItsTimeOfDay() {
        XCTAssertEqual(
            OracleCellFormatting.dateText(wire: [0x78, 0x7e, 0x0a, 0x06, 0x10, 0x17, 0x15]),
            "2026-10-06 15:22:20"
        )
    }

    func testDateBeforeYear1000KeepsFourDigits() {
        XCTAssertEqual(OracleCellFormatting.dateText(wire: [0x64, 0x69, 0x03, 0x04, 0x02, 0x03, 0x04]), "0005-03-04 01:02:03")
    }

    func testBCYearsKeepOraclesSign() {
        XCTAssertEqual(OracleCellFormatting.dateText(wire: [0x35, 0x58, 0x01, 0x01, 0x01, 0x01, 0x01]), "-4712-01-01 00:00:00")
        XCTAssertEqual(
            OracleCellFormatting.timestampText(wire: [0x64, 0x38, 0x03, 0x0f, 0x0d, 0x01, 0x01], fractionDigits: 6),
            "-0044-03-15 12:00:00.000000"
        )
    }

    /// The fraction is nanoseconds. Reading it through the driver's `Date` turned `.05` into `.5` and
    /// `.000001` into `.1`.
    func testFractionHasExactlyTheColumnsDigits() {
        XCTAssertEqual(
            OracleCellFormatting.timestampText(wire: Self.timestamp(nanoseconds: [0x02, 0xfa, 0xf0, 0x80]), fractionDigits: 6),
            "2024-01-02 03:04:05.050000"
        )
        XCTAssertEqual(
            OracleCellFormatting.timestampText(wire: Self.timestamp(nanoseconds: [0x00, 0x00, 0x03, 0xe8]), fractionDigits: 6),
            "2024-01-02 03:04:05.000001"
        )
        XCTAssertEqual(
            OracleCellFormatting.timestampText(wire: Self.timestamp(nanoseconds: [0x3b, 0x9a, 0xc9, 0xff]), fractionDigits: 9),
            "2024-01-02 03:04:05.999999999"
        )
    }

    /// A whole second arrives as seven bytes. TIMESTAMP(0) has no fraction at all, and TIMESTAMP(3) still
    /// shows its three digits, so neither ends in a bare `.`.
    func testWholeSecondFollowsThePrecision() {
        XCTAssertEqual(OracleCellFormatting.timestampText(wire: Self.wholeSecond, fractionDigits: 0), "2024-01-02 03:04:05")
        XCTAssertEqual(OracleCellFormatting.timestampText(wire: Self.wholeSecond, fractionDigits: 3), "2024-01-02 03:04:05.000")
    }

    /// The bytes are UTC and the text is the wall clock at the value's own offset. A zone west of UTC
    /// sends bytes below their bias, which the driver's decode trapped on.
    func testTimeZoneTextUsesTheValuesOwnOffset() {
        let minusFiveThirty: [UInt8] = [0x78, 0x7c, 0x01, 0x02, 0x09, 0x23, 0x06, 0x07, 0x5b, 0xca, 0x00, 0x0f, 0x1e]
        XCTAssertEqual(
            OracleCellFormatting.timestampWithTimeZoneText(wire: minusFiveThirty, fractionDigits: 6),
            "2024-01-02 03:04:05.123456-05:30"
        )
        let plusTwo: [UInt8] = [0x78, 0x7c, 0x01, 0x02, 0x02, 0x05, 0x06, 0x1d, 0xcd, 0x65, 0x00, 0x16, 0x3c]
        XCTAssertEqual(
            OracleCellFormatting.timestampWithTimeZoneText(wire: plusTwo, fractionDigits: 1),
            "2024-01-02 03:04:05.5+02:00"
        )
    }

    func testTimeZoneOffsetCanCrossIntoTheNextYear() {
        let utc: [UInt8] = [0x78, 0x7b, 0x0c, 0x1f, 0x14, 0x1f, 0x01, 0x00, 0x00, 0x00, 0x00, 0x19, 0x3c]
        XCTAssertEqual(
            OracleCellFormatting.timestampWithTimeZoneText(wire: utc, fractionDigits: 0),
            "2024-01-01 00:30:00+05:00"
        )
    }

    /// A zone stored by region name is an id into Oracle's time zone file. It used to read `<decode error>`.
    func testRegionNamedZoneIsAPlaceholder() {
        let paris: [UInt8] = [0x78, 0x7c, 0x01, 0x02, 0x03, 0x05, 0x06, 0x1d, 0xcd, 0x65, 0x00, 0x85, 0xf8]
        XCTAssertEqual(
            OracleCellFormatting.timestampWithTimeZoneText(wire: paris, fractionDigits: 6),
            "<unsupported: time zone region>"
        )
    }

    /// The bytes are the value in the database's zone; the text is the session's wall clock and the session's
    /// offset, so the instant survives a copy into a type with a zone.
    func testLocalTimeZoneTextIsTheSessionsWallClockAndOffset() throws {
        var bytes = Self.timestamp(nanoseconds: [0x00, 0x00, 0x03, 0xe8])
        bytes[4] = 0x02  // 01:04:05 in the database's zone
        let plusSeven = try XCTUnwrap(TimeZone(secondsFromGMT: 7 * 3_600))
        XCTAssertEqual(
            OracleCellFormatting.localTimestampText(
                wire: bytes, fractionDigits: 6, zones: OracleSessionTimeZones(database: .gmt, session: plusSeven)
            ),
            "2024-01-02 08:04:05.000001+07:00"
        )
        let minusThree = try XCTUnwrap(TimeZone(secondsFromGMT: -3 * 3_600))
        XCTAssertEqual(
            OracleCellFormatting.localTimestampText(
                wire: bytes, fractionDigits: 6, zones: OracleSessionTimeZones(database: .gmt, session: minusThree)
            ),
            "2024-01-01 22:04:05.000001-03:00"
        )
    }

    func testLocalTimeZoneTextFollowsTheSessionRegionsDaylightSaving() throws {
        let paris = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
        let zones = OracleSessionTimeZones(database: .gmt, session: paris)
        let july: [UInt8] = [0x78, 0x7c, 0x07, 0x01, 0x0d, 0x01, 0x01]
        XCTAssertEqual(
            OracleCellFormatting.localTimestampText(wire: july, fractionDigits: 0, zones: zones),
            "2024-07-01 14:00:00+02:00"
        )
        let january: [UInt8] = [0x78, 0x7c, 0x01, 0x01, 0x0d, 0x01, 0x01]
        XCTAssertEqual(
            OracleCellFormatting.localTimestampText(wire: january, fractionDigits: 0, zones: zones),
            "2024-01-01 13:00:00+01:00"
        )
    }

    func testLocalTimeZoneTextMovesFromANonUTCDatabaseZone() throws {
        let plusTwo = try XCTUnwrap(TimeZone(secondsFromGMT: 2 * 3_600))
        let zones = OracleSessionTimeZones(database: plusTwo, session: .gmt)
        XCTAssertEqual(
            OracleCellFormatting.localTimestampText(wire: Self.wholeSecond, fractionDigits: 0, zones: zones),
            "2024-01-02 01:04:05+00:00"
        )
    }

    /// Paris kept local mean time, nine minutes and 21 seconds ahead of UTC, until 1891. The suffix holds whole
    /// minutes, so the wall clock moves by the same whole minutes and the text still names the instant.
    func testLocalTimeZoneOffsetIsWholeMinutes() throws {
        let paris = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
        let zones = OracleSessionTimeZones(database: .gmt, session: paris)
        let noonIn1880: [UInt8] = [0x76, 0x64 + 80, 0x06, 0x01, 0x0d, 0x01, 0x01]
        let text = try XCTUnwrap(OracleCellFormatting.localTimestampText(wire: noonIn1880, fractionDigits: 0, zones: zones))
        XCTAssertTrue(text.hasPrefix("1880-06-01 12:09:00"), text)
        XCTAssertTrue(text.hasSuffix("+00:09"), text)
    }

    /// The grid reads a datetime through `DatabaseDateParser`, whose grammar takes an offset straight after the
    /// seconds or the fraction.
    func testDatetimeSpellingsFitTheGridsGrammar() throws {
        let grammar = try NSRegularExpression(
            pattern: #"^(?:(\d{4})-(\d{1,2})-(\d{1,2}))?(?:([ T])?(\d{1,2}):(\d{2}):(\d{2})(\.\d+)?)?(Z|[+-]\d{2}(?::?\d{2})?)?$"#
        )
        let spellings = [
            "2026-10-06 15:22:20",
            "2024-01-02 03:04:05.050000",
            "2024-01-02 03:04:05.123456-05:30",
            "2024-01-02 08:04:05.000001+07:00",
            "2024-07-01 14:00:00+02:00",
        ]
        for spelling in spellings {
            let range = NSRange(spelling.startIndex..., in: spelling)
            XCTAssertNotNil(grammar.firstMatch(in: spelling, range: range), spelling)
        }
    }

    func testTooShortWireIsNotADate() {
        XCTAssertNil(OracleCellFormatting.dateText(wire: [0x78, 0x7c]))
    }

    /// A schema can hold its own DUAL, which an unqualified name resolves to first.
    func testZoneQueryReadsTheDictionarysDual() {
        XCTAssertTrue(OracleSessionTimeZones.query.hasSuffix("FROM \(OracleDictionary.dual)"))
    }

    func testSessionZonesReadOffsetsAndRegionNames() throws {
        let measured = try XCTUnwrap(OracleSessionTimeZones(row: [.string("+00:00"), .string("+07:00"), .string("+00:00"), .string("+07:00")]))
        XCTAssertEqual(measured.database.secondsFromGMT(), 0)
        XCTAssertEqual(measured.session.secondsFromGMT(), 7 * 3_600)

        let region = try XCTUnwrap(OracleSessionTimeZones(row: [.string("-05:30"), .string("Europe/Paris"), .string("-05:30"), .string("+01:00")]))
        XCTAssertEqual(region.database.secondsFromGMT(), -(5 * 3_600 + 30 * 60))
        XCTAssertEqual(region.session.identifier, "Europe/Paris")

        let unknownRegion = try XCTUnwrap(OracleSessionTimeZones(row: [.string("+00:00"), .string("Not/AZone"), .string("+00:00"), .string("+04:00")]))
        XCTAssertEqual(unknownRegion.session.secondsFromGMT(), 4 * 3_600)

        XCTAssertNil(OracleSessionTimeZones(row: [.null, .null, .null, .null]))
    }

    /// The zone text comes from the server. Out-of-range parts overflowed the arithmetic; they now read as an
    /// unparseable zone, which falls back to the offset column and then to no zones at all.
    func testOutOfRangeOffsetsAreRefused() {
        XCTAssertNil(OracleSessionTimeZones.zone(fromOffset: "+99999999999999999:00"))
        XCTAssertNil(OracleSessionTimeZones.zone(fromOffset: "-19:00"))
        XCTAssertNil(OracleSessionTimeZones.zone(fromOffset: "+05:60"))
        XCTAssertNil(OracleSessionTimeZones.zone(fromOffset: "+05:-1"))
        XCTAssertEqual(OracleSessionTimeZones.zone(fromOffset: "+14:00")?.secondsFromGMT(), 14 * 3_600)
        XCTAssertEqual(OracleSessionTimeZones.zone(fromOffset: "-12:00")?.secondsFromGMT(), -12 * 3_600)

        let hostile = OracleSessionTimeZones(row: [
            .string("+99999999999999999:00"), .string("+07:00"), .string("+00:00"), .string("+07:00"),
        ])
        XCTAssertEqual(hostile?.database.secondsFromGMT(), 0)
        XCTAssertNil(OracleSessionTimeZones(row: [
            .string("+99999999999999999:00"), .string("+07:00"), .string("+99999999999999999:00"), .string("+07:00"),
        ]))
    }

    func testOnlyAnAlterSessionCanChangeTheZones() {
        XCTAssertTrue(OracleSessionTimeZones.mayChange(after: "ALTER SESSION SET TIME_ZONE = '-03:00'"))
        XCTAssertTrue(OracleSessionTimeZones.mayChange(after: "  alter session set time_zone = dbtimezone"))
        XCTAssertFalse(OracleSessionTimeZones.mayChange(after: "ALTER TABLE t ADD c NUMBER"))
        XCTAssertFalse(OracleSessionTimeZones.mayChange(after: "SELECT 1 FROM DUAL"))
    }

    func testBFILETextIsTheCallThatCreatesIt() {
        XCTAssertEqual(
            OracleCellFormatting.bfileText(directory: "DATA_PUMP_DIR", fileName: "x.bin"),
            "BFILENAME('DATA_PUMP_DIR', 'x.bin')"
        )
        XCTAssertEqual(
            OracleCellFormatting.bfileText(directory: "D", fileName: "it's.bin"),
            "BFILENAME('D', 'it''s.bin')"
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
