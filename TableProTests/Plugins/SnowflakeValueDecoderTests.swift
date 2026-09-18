//
//  SnowflakeValueDecoderTests.swift
//  TableProTests
//
//  Tests for SnowflakeValueDecoder (compiled via symlink from SnowflakeDriverPlugin).
//

import Foundation
import Testing

@Suite("Snowflake Value Decoder")
struct SnowflakeValueDecoderTests {
    private func column(_ type: String, scale: Int? = nil) -> SnowflakeColumnMeta {
        SnowflakeColumnMeta(
            name: "c",
            internalType: type,
            nullable: true,
            precision: nil,
            scale: scale,
            length: nil
        )
    }

    private func decodedText(_ raw: String, _ type: String, scale: Int? = nil) -> String? {
        guard case .text(let value) = SnowflakeValueDecoder.decode(raw, as: column(type, scale: scale)) else {
            return nil
        }
        return value
    }

    private func decodedBytes(_ raw: String, _ type: String) -> Data? {
        guard case .bytes(let data) = SnowflakeValueDecoder.decode(raw, as: column(type)) else { return nil }
        return data
    }

    // MARK: - DATE

    @Test("Epoch days decode to the dates the issue names")
    func testReportedDates() {
        #expect(decodedText("18262", "date") == "2020-01-01")
        #expect(decodedText("20682", "date") == "2026-08-17")
    }

    @Test("Epoch day zero and its neighbours decode")
    func testEpochNeighbours() {
        #expect(decodedText("0", "date") == "1970-01-01")
        #expect(decodedText("1", "date") == "1970-01-02")
        #expect(decodedText("-1", "date") == "1969-12-31")
        #expect(decodedText("-25567", "date") == "1900-01-01")
    }

    /// Foundation renders this epoch day as 0001-01-03, because `Calendar(identifier: .gregorian)`,
    /// `Calendar(identifier: .iso8601)`, `ISO8601DateFormatter` and `Date.FormatStyle.iso8601` all
    /// apply the 1582 Julian cutover. Snowflake does not, so this case fails the moment the decoder
    /// is reimplemented on any of them.
    @Test("Dates before 1582 use the proleptic Gregorian calendar")
    func testProlepticGregorian() {
        #expect(decodedText("-719162", "date") == "0001-01-01")
        #expect(decodedText("-141427", "date") == "1582-10-15")
        #expect(decodedText("-141428", "date") == "1582-10-14")
    }

    @Test("The bounds of Snowflake's date range decode")
    func testRangeBounds() {
        #expect(decodedText("-719162", "date") == "0001-01-01")
        #expect(decodedText("2932896", "date") == "9999-12-31")
    }

    @Test("Epoch days outside the date range keep their raw text")
    func testOutOfRangeDatesArePreserved() {
        #expect(decodedText("2932897", "date") == "2932897")
        #expect(decodedText("-719163", "date") == "-719163")
        #expect(decodedText("100000000", "date") == "100000000")
    }

    @Test("A date value that is not an integer keeps its raw text")
    func testUndecodableDatesArePreserved() {
        #expect(decodedText("", "date") == "")
        #expect(decodedText("abc", "date") == "abc")
        #expect(decodedText("20682.5", "date") == "20682.5")
        #expect(decodedText("2026-08-17", "date") == "2026-08-17")
    }

    @Test("Decoding is keyed on the column, never on the value")
    func testIntegerInNonDateColumnIsUntouched() {
        #expect(decodedText("20682", "fixed") == "20682")
        #expect(decodedText("20682", "text") == "20682")
        #expect(decodedText("20682", "variant") == "20682")
        #expect(decodedText("20682", "boolean") == "20682")
    }

    @Test("An unknown internal type keeps its raw text")
    func testUnknownTypeIsUntouched() {
        #expect(decodedText("20682", "vector") == "20682")
    }

    // MARK: - TIME

    @Test("Seconds since midnight decode to a wall clock")
    func testTime() {
        #expect(decodedText("3600.000000000", "time", scale: 0) == "01:00:00")
        #expect(decodedText("82919.000000000", "time", scale: 0) == "23:01:59")
        #expect(decodedText("0.000000000", "time", scale: 0) == "00:00:00")
        #expect(decodedText("86399.000000000", "time", scale: 0) == "23:59:59")
    }

    @Test("A time column's scale decides how many fractional digits are written")
    func testTimeScale() {
        #expect(decodedText("3600.123456789", "time", scale: 0) == "01:00:00")
        #expect(decodedText("3600.123456789", "time", scale: 3) == "01:00:00.123")
        #expect(decodedText("3600.123456789", "time", scale: 9) == "01:00:00.123456789")
        #expect(decodedText("3600.5", "time", scale: 3) == "01:00:00.500")
    }

    @Test("A time outside a single day keeps its raw text")
    func testOutOfRangeTimeIsPreserved() {
        #expect(decodedText("86400.000000000", "time", scale: 0) == "86400.000000000")
        #expect(decodedText("-1.000000000", "time", scale: 0) == "-1.000000000")
        #expect(decodedText("noon", "time", scale: 0) == "noon")
    }

    // MARK: - TIMESTAMP

    @Test("TIMESTAMP_NTZ decodes to a bare wall clock")
    func testTimestampNtz() {
        #expect(decodedText("1755388800.000000000", "timestamp_ntz", scale: 0) == "2025-08-17 00:00:00")
        #expect(decodedText("1616173619.000000000", "timestamp_ntz", scale: 0) == "2021-03-19 17:06:59")
    }

    /// TIMESTAMP_LTZ is an absolute instant stored in UTC. Without the marker the parser reads the
    /// UTC wall clock as if it were the reader's own, which moves the instant by their offset.
    @Test("TIMESTAMP_LTZ marks itself as UTC")
    func testTimestampLtz() {
        #expect(decodedText("1755388800.000000000", "timestamp_ltz", scale: 0) == "2025-08-17 00:00:00Z")
        #expect(decodedText("1616173619.000000000", "timestamp_ltz", scale: 3) == "2021-03-19 17:06:59.000Z")
    }

    @Test("TIMESTAMP_TZ applies the offset and writes it back")
    func testTimestampTz() {
        #expect(
            decodedText("1616173619.000000000 1500", "timestamp_tz", scale: 0) == "2021-03-19 18:06:59+01:00"
        )
        #expect(
            decodedText("1616173619.000000000 1140", "timestamp_tz", scale: 0) == "2021-03-19 12:06:59-05:00"
        )
        #expect(
            decodedText("1616173619.000000000 1440", "timestamp_tz", scale: 0) == "2021-03-19 17:06:59+00:00"
        )
    }

    @Test("A malformed TIMESTAMP_TZ keeps its raw text")
    func testUndecodableTimestampTzIsPreserved() {
        #expect(decodedText("1616173619.000000000", "timestamp_tz", scale: 0) == "1616173619.000000000")
        #expect(decodedText("1616173619.000000000 abc", "timestamp_tz", scale: 0) == "1616173619.000000000 abc")
        #expect(decodedText("1616173619.000000000 9999", "timestamp_tz", scale: 0) == "1616173619.000000000 9999")
    }

    /// `TimeZone(secondsFromGMT:)` is nil beyond eighteen hours and the shared parser reads that nil
    /// as GMT, so emitting `+18:30` would move the instant by eighteen and a half hours. Eighteen
    /// hours exactly is the last offset that survives the round trip.
    @Test("An offset the shared parser cannot represent keeps its raw text")
    func testOutOfRangeOffsetIsPreserved() {
        #expect(decodedText("0.000000000 2520", "timestamp_tz", scale: 0) == "1970-01-01 18:00:00+18:00")
        #expect(decodedText("0.000000000 360", "timestamp_tz", scale: 0) == "1969-12-31 06:00:00-18:00")
        #expect(decodedText("0.000000000 2550", "timestamp_tz", scale: 0) == "0.000000000 2550")
        #expect(decodedText("0.000000000 330", "timestamp_tz", scale: 0) == "0.000000000 330")
    }

    /// The wire writes nine decimal places, so the value carries more significant digits than a
    /// `Double` holds. Parsing it as a floating-point number drops the last nanoseconds silently.
    @Test("Nanosecond precision survives decoding")
    func testNanosecondPrecision() {
        #expect(
            decodedText("1616173619.123456789", "timestamp_ntz", scale: 9) == "2021-03-19 17:06:59.123456789"
        )
    }

    /// A value before the epoch is written as the negated magnitude, so the fraction is subtracted
    /// from the whole part rather than added to it. `-0.000000009` is the example Snowflake's own
    /// connector documents, and it is the case that proves the sign is not read off the integer
    /// half alone: `-0` parses to `0`.
    @Test("Timestamps before the epoch subtract their fraction")
    func testNegativeTimestamps() {
        #expect(decodedText("-1.000000000", "timestamp_ntz", scale: 0) == "1969-12-31 23:59:59")
        #expect(decodedText("-86400.000000000", "timestamp_ntz", scale: 0) == "1969-12-31 00:00:00")
        #expect(decodedText("-1.500000000", "timestamp_ntz", scale: 1) == "1969-12-31 23:59:58.5")
        #expect(
            decodedText("-0.000000009", "timestamp_ntz", scale: 9) == "1969-12-31 23:59:59.999999991"
        )
        #expect(decodedText("-0.500000000", "timestamp_ntz", scale: 1) == "1969-12-31 23:59:59.5")
    }

    @Test("A timestamp outside the date range keeps its raw text")
    func testOutOfRangeTimestampIsPreserved() {
        #expect(decodedText("999999999999.000000000", "timestamp_ntz", scale: 0) == "999999999999.000000000")
    }

    // MARK: - BINARY

    @Test("Binary hex decodes to bytes")
    func testBinary() {
        #expect(decodedBytes("48656C6C6F", "binary") == Data("Hello".utf8))
        #expect(decodedBytes("48656c6c6f", "binary") == Data("Hello".utf8))
        #expect(decodedBytes("00FF", "binary") == Data([0x00, 0xFF]))
    }

    @Test("A zero-length binary decodes to empty bytes, not to text")
    func testEmptyBinary() {
        #expect(decodedBytes("", "binary") == Data())
    }

    @Test("Binary that is not a whole hex string keeps its raw text")
    func testUndecodableBinaryIsPreserved() {
        #expect(decodedText("48656C6C6", "binary") == "48656C6C6")
        #expect(decodedText("zz", "binary") == "zz")
    }

    // MARK: - Type mapping

    @Test("Every logical type still maps to the display name the app classifies")
    func testDisplayNamesUnchanged() {
        #expect(SnowflakeTypeMapper.displayType(for: column("date")) == "DATE")
        #expect(SnowflakeTypeMapper.displayType(for: column("time")) == "TIME")
        #expect(SnowflakeTypeMapper.displayType(for: column("timestamp_ntz")) == "TIMESTAMP_NTZ")
        #expect(SnowflakeTypeMapper.displayType(for: column("timestamp_ltz")) == "TIMESTAMP_LTZ")
        #expect(SnowflakeTypeMapper.displayType(for: column("timestamp_tz")) == "TIMESTAMP_TZ")
        #expect(SnowflakeTypeMapper.displayType(for: column("binary")) == "BINARY")
    }
}
