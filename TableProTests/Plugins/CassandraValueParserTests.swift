//
//  CassandraValueParserTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct CassandraValueParserTests {
    @Test("Integers bind at the width their column declares")
    func integersKeepTheirWidth() throws {
        #expect(try CassandraValueParser.parse("-7", as: .tinyint) == .int8(-7))
        #expect(try CassandraValueParser.parse("300", as: .smallint) == .int16(300))
        #expect(try CassandraValueParser.parse(" 99 ", as: .int) == .int32(99))
        #expect(try CassandraValueParser.parse("9000000000", as: .bigint) == .int64(9_000_000_000))
        #expect(try CassandraValueParser.parse("5", as: .counter) == .int64(5))
    }

    @Test("A value that overflows or is not a number is refused, never sent as text")
    func invalidIntegersAreRefused() {
        #expect(throws: CassandraValueRefusal.invalid("300", typeName: "tinyint")) {
            try CassandraValueParser.parse("300", as: .tinyint)
        }
        #expect(throws: CassandraValueRefusal.invalid("abc", typeName: "int")) {
            try CassandraValueParser.parse("abc", as: .int)
        }
    }

    @Test("Floats, doubles and booleans")
    func scalarTypes() throws {
        #expect(try CassandraValueParser.parse("1.5", as: .float) == .float(1.5))
        #expect(try CassandraValueParser.parse("2.25", as: .double) == .double(2.25))
        #expect(try CassandraValueParser.parse("TRUE", as: .boolean) == .bool(true))
        #expect(try CassandraValueParser.parse("0", as: .boolean) == .bool(false))
        #expect(throws: CassandraValueRefusal.self) { try CassandraValueParser.parse("yes", as: .boolean) }
    }

    @Test("A uuid is validated and lowercased for either uuid type")
    func uuids() throws {
        let text = "123E4567-E89B-12D3-A456-426614174000"
        #expect(try CassandraValueParser.parse(text, as: .uuid) == .uuid(text.lowercased()))
        #expect(try CassandraValueParser.parse(text, as: .timeuuid) == .uuid(text.lowercased()))
        #expect(throws: CassandraValueRefusal.self) { try CassandraValueParser.parse("not-a-uuid", as: .uuid) }
    }

    @Test("A timestamp reads as the grid shows it, as cqlsh shows it, as a date, or as milliseconds")
    func timestamps() throws {
        let expected: Int64 = 1_704_067_200_000
        #expect(try CassandraValueParser.timestampMilliseconds("2024-01-01T00:00:00.000Z") == expected)
        #expect(try CassandraValueParser.timestampMilliseconds("2024-01-01T00:00:00Z") == expected)
        #expect(try CassandraValueParser.timestampMilliseconds("2024-01-01 00:00:00.000000+0000") == expected)
        #expect(try CassandraValueParser.timestampMilliseconds("2024-01-01 00:00:00") == expected)
        #expect(try CassandraValueParser.timestampMilliseconds("2024-01-01") == expected)
        #expect(try CassandraValueParser.timestampMilliseconds("1704067200000") == expected)
        #expect(try CassandraValueParser.timestampMilliseconds("2024-01-01T02:00:00+02:00") == expected)
        #expect(throws: CassandraValueRefusal.self) { try CassandraValueParser.timestampMilliseconds("yesterday") }
    }

    @Test("A date is days since the epoch, biased by 2^31 the way CQL stores it")
    func dates() throws {
        #expect(try CassandraValueParser.dateDays("1970-01-01") == 2_147_483_648)
        #expect(try CassandraValueParser.dateDays("2024-01-01") == 2_147_483_648 + 19_723)
        #expect(try CassandraValueParser.dateDays("1969-12-31") == 2_147_483_647)
        #expect(throws: CassandraValueRefusal.self) { try CassandraValueParser.dateDays("2024-02-30") }
        #expect(throws: CassandraValueRefusal.self) { try CassandraValueParser.dateDays("2024-1-1") }
    }

    @Test("A time is nanoseconds since midnight")
    func times() throws {
        #expect(try CassandraValueParser.timeNanoseconds("00:00:01") == 1_000_000_000)
        #expect(try CassandraValueParser.timeNanoseconds("01:02:03.5") == 3_723_500_000_000)
        #expect(try CassandraValueParser.timeNanoseconds("23:59:59.123456789") == 86_399_123_456_789)
        #expect(throws: CassandraValueRefusal.self) { try CassandraValueParser.timeNanoseconds("24:00:00") }
    }

    @Test("A time is shown with every digit it holds, so a time key binds back to the same row", arguments: [
        Int64(0), 1_000_000_000, 3_723_500_000_000, 3_723_000_001_000, 86_399_123_456_789, 1
    ])
    func timeTextRoundTrips(nanoseconds: Int64) throws {
        let text = CassandraValueParser.timeText(nanoseconds: nanoseconds)
        #expect(try CassandraValueParser.timeNanoseconds(text) == nanoseconds)
    }

    @Test("A time keeps the millisecond form when that is all it holds")
    func timeTextShape() {
        #expect(CassandraValueParser.timeText(nanoseconds: 3_723_500_000_000) == "01:02:03.500")
        #expect(CassandraValueParser.timeText(nanoseconds: 3_723_000_001_000) == "01:02:03.000001")
        #expect(CassandraValueParser.timeText(nanoseconds: 86_399_123_456_789) == "23:59:59.123456789")
        #expect(CassandraValueParser.timeText(nanoseconds: 60_000_000_000) == "00:01:00")
    }

    @Test("A blob reads the hex the grid shows, and bytes bind as they are")
    func blobs() throws {
        #expect(try CassandraValueParser.parse("0xCAFE", as: .blob) == .bytes(Data([0xCA, 0xFE])))
        #expect(try CassandraValueParser.bind(.bytes(Data([1, 2])), as: .blob) == .bytes(Data([1, 2])))
        #expect(throws: CassandraValueRefusal.self) { try CassandraValueParser.parse("CAFE", as: .blob) }
    }

    @Test("NULL binds as null whatever the column")
    func nullIsNull() throws {
        #expect(try CassandraValueParser.bind(.null, as: .int) == .null)
        #expect(try CassandraValueParser.bind(.null, as: .unsupported("list")) == .null)
    }

    @Test("A collection, tuple or user-defined value is refused by name")
    func unsupportedTypesAreRefused() {
        #expect(throws: CassandraValueRefusal.unsupported(typeName: "list")) {
            try CassandraValueParser.parse("[1, 2]", as: .unsupported("list"))
        }
    }

    @Test("A varint round-trips through the bytes CQL stores", arguments: [
        "0", "1", "-1", "127", "128", "-128", "-129", "255", "256", "123456789012345678901234567890",
        "-98765432109876543210"
    ])
    func varintRoundTrip(text: String) throws {
        let bytes = try #require(CassandraVarint.bytes(fromDecimalInteger: text))
        #expect(CassandraVarint.decimalString(fromTwosComplement: bytes) == text)
    }

    @Test("A varint is minimal two's complement")
    func varintEncoding() {
        #expect(CassandraVarint.bytes(fromDecimalInteger: "127") == Data([0x7F]))
        #expect(CassandraVarint.bytes(fromDecimalInteger: "128") == Data([0x00, 0x80]))
        #expect(CassandraVarint.bytes(fromDecimalInteger: "-128") == Data([0x80]))
        #expect(CassandraVarint.bytes(fromDecimalInteger: "-129") == Data([0xFF, 0x7F]))
        #expect(CassandraVarint.bytes(fromDecimalInteger: "12a") == nil)
    }

    @Test("A decimal round-trips through its unscaled value and scale", arguments: [
        "0.5", "-12.340", "1000", "0.001", "-0.05", "123456789.987654321"
    ])
    func decimalRoundTrip(text: String) throws {
        let decimal = try #require(CassandraVarint.decimal(fromText: text))
        #expect(CassandraVarint.decimalString(unscaled: decimal.unscaled, scale: decimal.scale) == text)
    }

    @Test("A decimal whose scale would expand past the bound is shown with an exponent, even at the wire's limits")
    func extremeDecimalScalesDoNotExpand() throws {
        let one = try #require(CassandraVarint.bytes(fromDecimalInteger: "1"))

        #expect(CassandraVarint.decimalString(unscaled: one, scale: Int32.min) == "1E2147483648")
        #expect(CassandraVarint.decimalString(unscaled: one, scale: Int32.max) == "1E-2147483647")
        #expect(CassandraVarint.decimalString(unscaled: one, scale: -64).count == 65)
        #expect(CassandraVarint.decimalString(unscaled: one, scale: -65) == "1E65")
    }

    @Test("An exponent too large for any scale is refused rather than trapping")
    func extremeExponentIsRefused() {
        #expect(CassandraVarint.decimal(fromText: "1e-9223372036854775808") == nil)
        #expect(CassandraVarint.decimal(fromText: "1e9223372036854775807") == nil)
        #expect(throws: CassandraValueRefusal.self) { try CassandraValueParser.parse("1e-9223372036854775808", as: .decimal) }
    }

    @Test("A decimal in exponent form keeps its value")
    func decimalExponent() throws {
        let decimal = try #require(CassandraVarint.decimal(fromText: "1.5E3"))
        #expect(decimal.scale == -2)
        #expect(CassandraVarint.decimalString(unscaled: decimal.unscaled, scale: decimal.scale) == "1500")
        #expect(CassandraVarint.decimal(fromText: "1.2.3") == nil)
    }
}
