import Foundation
@testable import TableProOracleCore
import Testing

/// Wire bytes measured on Oracle 23ai, with a session time zone of +07:00 and a database time zone of +00:00.
struct OracleCellFormattingTests {
    /// 2024-01-02 03:04:05, the date and time every TIMESTAMP case below starts from.
    private static let wholeSecond: [UInt8] = [0x78, 0x7c, 0x01, 0x02, 0x04, 0x05, 0x06]

    private static func timestamp(nanoseconds: [UInt8]) -> [UInt8] {
        wholeSecond + nanoseconds
    }

    /// Oracle's DATE always carries a time of day, and dropping it lost the time from every read.
    @Test func testDateKeepsItsTimeOfDay() {
        #expect(OracleCellFormatting.dateText(wire: [0x78, 0x7e, 0x0a, 0x06, 0x10, 0x17, 0x15]) == "2026-10-06 15:22:20")
    }

    @Test func testDateBeforeYear1000KeepsFourDigits() {
        #expect(OracleCellFormatting.dateText(wire: [0x64, 0x69, 0x03, 0x04, 0x02, 0x03, 0x04]) == "0005-03-04 01:02:03")
    }

    @Test func testBCYearsKeepOraclesSign() {
        #expect(OracleCellFormatting.dateText(wire: [0x35, 0x58, 0x01, 0x01, 0x01, 0x01, 0x01]) == "-4712-01-01 00:00:00")
        #expect(OracleCellFormatting.timestampText(wire: [0x64, 0x38, 0x03, 0x0f, 0x0d, 0x01, 0x01], fractionDigits: 6) == "-0044-03-15 12:00:00.000000")
    }

    /// The fraction is nanoseconds. Reading it through the driver's `Date` turned `.05` into `.5` and
    /// `.000001` into `.1`.
    @Test func testFractionHasExactlyTheColumnsDigits() {
        #expect(OracleCellFormatting.timestampText(wire: Self.timestamp(nanoseconds: [0x02, 0xfa, 0xf0, 0x80]), fractionDigits: 6) == "2024-01-02 03:04:05.050000")
        #expect(OracleCellFormatting.timestampText(wire: Self.timestamp(nanoseconds: [0x00, 0x00, 0x03, 0xe8]), fractionDigits: 6) == "2024-01-02 03:04:05.000001")
        #expect(OracleCellFormatting.timestampText(wire: Self.timestamp(nanoseconds: [0x3b, 0x9a, 0xc9, 0xff]), fractionDigits: 9) == "2024-01-02 03:04:05.999999999")
    }

    /// A whole second arrives as seven bytes. TIMESTAMP(0) has no fraction at all, and TIMESTAMP(3) still
    /// shows its three digits, so neither ends in a bare `.`.
    @Test func testWholeSecondFollowsThePrecision() {
        #expect(OracleCellFormatting.timestampText(wire: Self.wholeSecond, fractionDigits: 0) == "2024-01-02 03:04:05")
        #expect(OracleCellFormatting.timestampText(wire: Self.wholeSecond, fractionDigits: 3) == "2024-01-02 03:04:05.000")
    }

    /// The bytes are UTC and the text is the wall clock at the value's own offset. A zone west of UTC
    /// sends bytes below their bias, which the driver's decode trapped on.
    @Test func testTimeZoneTextUsesTheValuesOwnOffset() {
        let minusFiveThirty: [UInt8] = [0x78, 0x7c, 0x01, 0x02, 0x09, 0x23, 0x06, 0x07, 0x5b, 0xca, 0x00, 0x0f, 0x1e]
        #expect(OracleCellFormatting.timestampWithTimeZoneText(wire: minusFiveThirty, fractionDigits: 6) == "2024-01-02 03:04:05.123456-05:30")
        let plusTwo: [UInt8] = [0x78, 0x7c, 0x01, 0x02, 0x02, 0x05, 0x06, 0x1d, 0xcd, 0x65, 0x00, 0x16, 0x3c]
        #expect(OracleCellFormatting.timestampWithTimeZoneText(wire: plusTwo, fractionDigits: 1) == "2024-01-02 03:04:05.5+02:00")
    }

    @Test func testTimeZoneOffsetCanCrossIntoTheNextYear() {
        let utc: [UInt8] = [0x78, 0x7b, 0x0c, 0x1f, 0x14, 0x1f, 0x01, 0x00, 0x00, 0x00, 0x00, 0x19, 0x3c]
        #expect(OracleCellFormatting.timestampWithTimeZoneText(wire: utc, fractionDigits: 0) == "2024-01-01 00:30:00+05:00")
    }

    /// A zone stored by region name is an id into Oracle's time zone file. It used to read `<decode error>`.
    @Test func testRegionNamedZoneIsAPlaceholder() {
        let paris: [UInt8] = [0x78, 0x7c, 0x01, 0x02, 0x03, 0x05, 0x06, 0x1d, 0xcd, 0x65, 0x00, 0x85, 0xf8]
        #expect(OracleCellFormatting.timestampWithTimeZoneText(wire: paris, fractionDigits: 6) == "<unsupported: time zone region>")
    }

    /// The bytes are the value in the database's zone; the text is the session's wall clock and the session's
    /// offset, so the instant survives a copy into a type with a zone.
    @Test func testLocalTimeZoneTextIsTheSessionsWallClockAndOffset() throws {
        var bytes = Self.timestamp(nanoseconds: [0x00, 0x00, 0x03, 0xe8])
        bytes[4] = 0x02  // 01:04:05 in the database's zone
        let plusSeven = try #require(TimeZone(secondsFromGMT: 7 * 3_600))
        #expect(OracleCellFormatting.localTimestampText(
                wire: bytes, fractionDigits: 6, zones: OracleSessionTimeZones(database: .gmt, session: plusSeven)
            ) == "2024-01-02 08:04:05.000001+07:00")
        let minusThree = try #require(TimeZone(secondsFromGMT: -3 * 3_600))
        #expect(OracleCellFormatting.localTimestampText(
                wire: bytes, fractionDigits: 6, zones: OracleSessionTimeZones(database: .gmt, session: minusThree)
            ) == "2024-01-01 22:04:05.000001-03:00")
    }

    @Test func testLocalTimeZoneTextFollowsTheSessionRegionsDaylightSaving() throws {
        let paris = try #require(TimeZone(identifier: "Europe/Paris"))
        let zones = OracleSessionTimeZones(database: .gmt, session: paris)
        let july: [UInt8] = [0x78, 0x7c, 0x07, 0x01, 0x0d, 0x01, 0x01]
        #expect(OracleCellFormatting.localTimestampText(wire: july, fractionDigits: 0, zones: zones) == "2024-07-01 14:00:00+02:00")
        let january: [UInt8] = [0x78, 0x7c, 0x01, 0x01, 0x0d, 0x01, 0x01]
        #expect(OracleCellFormatting.localTimestampText(wire: january, fractionDigits: 0, zones: zones) == "2024-01-01 13:00:00+01:00")
    }

    @Test func testLocalTimeZoneTextMovesFromANonUTCDatabaseZone() throws {
        let plusTwo = try #require(TimeZone(secondsFromGMT: 2 * 3_600))
        let zones = OracleSessionTimeZones(database: plusTwo, session: .gmt)
        #expect(OracleCellFormatting.localTimestampText(wire: Self.wholeSecond, fractionDigits: 0, zones: zones) == "2024-01-02 01:04:05+00:00")
    }

    /// Paris kept local mean time, nine minutes and 21 seconds ahead of UTC, until 1891. The suffix holds whole
    /// minutes, so the wall clock moves by the same whole minutes and the text still names the instant.
    @Test func testLocalTimeZoneOffsetIsWholeMinutes() throws {
        let paris = try #require(TimeZone(identifier: "Europe/Paris"))
        let zones = OracleSessionTimeZones(database: .gmt, session: paris)
        let noonIn1880: [UInt8] = [0x76, 0x64 + 80, 0x06, 0x01, 0x0d, 0x01, 0x01]
        let text = try #require(OracleCellFormatting.localTimestampText(wire: noonIn1880, fractionDigits: 0, zones: zones))
        #expect(text.hasPrefix("1880-06-01 12:09:00"), "\(text)")
        #expect(text.hasSuffix("+00:09"), "\(text)")
    }

    /// The grid reads a datetime through `DatabaseDateParser`, whose grammar takes an offset straight after the
    /// seconds or the fraction.
    @Test func testDatetimeSpellingsFitTheGridsGrammar() throws {
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
            #expect(grammar.firstMatch(in: spelling, range: range) != nil, "\(spelling)")
        }
    }

    @Test func testTooShortWireIsNotADate() {
        #expect(OracleCellFormatting.dateText(wire: [0x78, 0x7c]) == nil)
    }

    /// A schema can hold its own DUAL, which an unqualified name resolves to first.
    @Test func testZoneQueryReadsTheDictionarysDual() {
        #expect(OracleSessionTimeZones.query.hasSuffix("FROM \(OracleDictionary.dual)"))
    }

    @Test func testSessionZonesReadOffsetsAndRegionNames() throws {
        let measured = try #require(OracleSessionTimeZones(row: [.string("+00:00"), .string("+07:00"), .string("+00:00"), .string("+07:00")]))
        #expect(measured.database.secondsFromGMT() == 0)
        #expect(measured.session.secondsFromGMT() == 7 * 3_600)

        let region = try #require(OracleSessionTimeZones(row: [.string("-05:30"), .string("Europe/Paris"), .string("-05:30"), .string("+01:00")]))
        #expect(region.database.secondsFromGMT() == -(5 * 3_600 + 30 * 60))
        #expect(region.session.identifier == "Europe/Paris")

        let unknownRegion = try #require(OracleSessionTimeZones(row: [.string("+00:00"), .string("Not/AZone"), .string("+00:00"), .string("+04:00")]))
        #expect(unknownRegion.session.secondsFromGMT() == 4 * 3_600)

        #expect(OracleSessionTimeZones(row: [.null, .null, .null, .null]) == nil)
    }

    /// The zone text comes from the server. Out-of-range parts overflowed the arithmetic; they now read as an
    /// unparseable zone, which falls back to the offset column and then to no zones at all.
    @Test func testOutOfRangeOffsetsAreRefused() {
        #expect(OracleSessionTimeZones.zone(fromOffset: "+99999999999999999:00") == nil)
        #expect(OracleSessionTimeZones.zone(fromOffset: "-19:00") == nil)
        #expect(OracleSessionTimeZones.zone(fromOffset: "+05:60") == nil)
        #expect(OracleSessionTimeZones.zone(fromOffset: "+05:-1") == nil)
        #expect(OracleSessionTimeZones.zone(fromOffset: "+14:00")?.secondsFromGMT() == 14 * 3_600)
        #expect(OracleSessionTimeZones.zone(fromOffset: "-12:00")?.secondsFromGMT() == -12 * 3_600)

        let hostile = OracleSessionTimeZones(row: [
            .string("+99999999999999999:00"), .string("+07:00"), .string("+00:00"), .string("+07:00"),
        ])
        #expect(hostile?.database.secondsFromGMT() == 0)
        #expect(OracleSessionTimeZones(row: [
            .string("+99999999999999999:00"), .string("+07:00"), .string("+99999999999999999:00"), .string("+07:00"),
        ]) == nil)
    }

    @Test func testAlterSessionAndPLSQLCanChangeTheZones() {
        #expect(OracleSessionTimeZones.mayChange(after: "ALTER SESSION SET TIME_ZONE = '-03:00'"))
        #expect(OracleSessionTimeZones.mayChange(after: "  alter session set time_zone = dbtimezone"))
        #expect(!OracleSessionTimeZones.mayChange(after: "ALTER TABLE t ADD c NUMBER"))
        #expect(!OracleSessionTimeZones.mayChange(after: "SELECT 1 FROM DUAL"))
        #expect(!OracleSessionTimeZones.mayChange(after: "UPDATE t SET c = 1"))
        #expect(OracleSessionTimeZones.mayChange(
            after: "BEGIN EXECUTE IMMEDIATE 'ALTER SESSION SET TIME_ZONE = ''-03:00'''; END;"
        ))
        #expect(OracleSessionTimeZones.mayChange(after: "declare x number; begin null; end;"))
        #expect(OracleSessionTimeZones.mayChange(after: "CALL set_zone()"))
        #expect(OracleSessionTimeZones.mayChange(after: "<<outer>> BEGIN NULL; END;"))
    }

    @Test func testBFILETextIsTheCallThatCreatesIt() {
        #expect(OracleCellFormatting.bfileText(directory: "DATA_PUMP_DIR", fileName: "x.bin") == "BFILENAME('DATA_PUMP_DIR', 'x.bin')")
        #expect(OracleCellFormatting.bfileText(directory: "D", fileName: "it's.bin") == "BFILENAME('D', 'it''s.bin')")
    }

    @Test func testIntervalMillisecondsTrimToSignificantDigits() {
        let result = OracleCellFormatting.formatIntervalDS(
            days: 2, hours: 3, minutes: 4, seconds: 5, nanoseconds: 678_000_000
        )
        #expect(result == "2 03:04:05.678")
    }

    @Test func testIntervalPreservesNanosecondPrecision() {
        let result = OracleCellFormatting.formatIntervalDS(
            days: 0, hours: 0, minutes: 0, seconds: 0, nanoseconds: 123_456_789
        )
        #expect(result == "0 00:00:00.123456789")
    }

    @Test func testNegativeIntervalPrefixesSingleMinus() {
        let result = OracleCellFormatting.formatIntervalDS(
            days: -1, hours: -2, minutes: -3, seconds: -4, nanoseconds: -50_000_000
        )
        #expect(result == "-1 02:03:04.05")
    }

    @Test func testZeroFractionalDropsDecimalPoint() {
        let result = OracleCellFormatting.formatIntervalDS(
            days: 5, hours: 3, minutes: 14, seconds: 0, nanoseconds: 0
        )
        #expect(result == "5 03:14:00")
    }

    @Test func testZeroIntervalHasNoSignAndNoDecimal() {
        let result = OracleCellFormatting.formatIntervalDS(
            days: 0, hours: 0, minutes: 0, seconds: 0, nanoseconds: 0
        )
        #expect(result == "0 00:00:00")
    }

    @Test func testIntervalYearToMonthPositive() {
        #expect(OracleCellFormatting.formatIntervalYM(years: 5, months: 3) == "5-03")
    }

    @Test func testIntervalYearToMonthNegative() {
        #expect(OracleCellFormatting.formatIntervalYM(years: -2, months: -7) == "-2-07")
    }

    @Test func testIntervalYearToMonthZero() {
        #expect(OracleCellFormatting.formatIntervalYM(years: 0, months: 0) == "0-00")
    }

    @Test func testHexEncodeProducesLowercaseBytes() {
        #expect(OracleCellFormatting.hexEncode([0x00, 0xff, 0xab, 0x10]) == "00ffab10")
    }

    @Test func testHexEncodeEmptyInput() {
        #expect(OracleCellFormatting.hexEncode([]) == "")
    }

    @Test func testHexEncodeTruncatesAndReportsTotalSize() {
        let result = OracleCellFormatting.hexEncode([UInt8](repeating: 0xab, count: 5_000))
        #expect(result.hasSuffix("… (5000 bytes)"))
        let hexPart = result.replacingOccurrences(of: "… (5000 bytes)", with: "")
        #expect(hexPart.count == OracleCellFormatting.maxHexBytes * 2)
    }

    @Test func testUnsupportedPlaceholderEmbedsTypeName() {
        #expect(OracleCellFormatting.unsupportedPlaceholder(typeName: "interval year to month") == "<unsupported: interval year to month>")
    }
}
