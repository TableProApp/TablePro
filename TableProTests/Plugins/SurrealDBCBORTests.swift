//
//  SurrealDBCBORTests.swift
//  TableProTests
//

import Foundation
import Testing

@Suite("SurrealDB - CBOR codec")
struct SurrealDBCBORTests {
    private func roundTrip(_ value: SurrealValue) throws -> SurrealValue {
        try SurrealCBOR.decode(SurrealCBOR.encode(value))
    }

    @Test("Scalars round-trip")
    func scalars() throws {
        let values: [SurrealValue] = [
            .null,
            .none,
            .bool(true),
            .bool(false),
            .int(0),
            .int(23),
            .int(24),
            .int(255),
            .int(65_535),
            .int(4_294_967_295),
            .int(9_223_372_036_854_775_807),
            .int(-1),
            .int(-1000),
            .double(1.5),
            .double(-0.25),
            .string(""),
            .string("hello"),
            .string("unicode ✓ 日本語"),
            .bytes(Data([0x00, 0x01, 0xFF])),
        ]
        for value in values {
            #expect(try roundTrip(value) == value)
        }
    }

    @Test("Tagged SurrealDB types round-trip")
    func taggedTypes() throws {
        let uuid = try #require(UUID(uuidString: "018a6680-0000-7000-8000-000000000000"))
        let values: [SurrealValue] = [
            .recordId(SurrealRecordID(table: "person", id: .string("alice"))),
            .recordId(SurrealRecordID(table: "person", id: .int(10))),
            .decimal("12.345"),
            .datetime(seconds: 1_726_403_696, nanoseconds: 789_000_000),
            .datetime(seconds: -14_182_940, nanoseconds: 0),
            .duration(seconds: 3600, nanoseconds: 0),
            .duration(seconds: 0, nanoseconds: 1),
            .uuid(uuid),
            .table("person"),
            .array([.int(1), .string("two")]),
            .object([(key: "a", value: .int(1)), (key: "b", value: .none)]),
        ]
        for value in values {
            #expect(try roundTrip(value) == value)
        }
    }

    @Test("Decodes the byte sequences a live SurrealDB server sends")
    func serverBytes() throws {
        let taggedRecordIdOfPersonAlice = Data(
            [0xC8, 0x82, 0x66, 0x70, 0x65, 0x72, 0x73, 0x6F, 0x6E, 0x65, 0x61, 0x6C, 0x69, 0x63, 0x65]
        )
        #expect(
            try SurrealCBOR.decode(taggedRecordIdOfPersonAlice)
                == .recordId(SurrealRecordID(table: "person", id: .string("alice")))
        )

        let taggedDecimalOf12Point345 = Data([0xCA, 0x66, 0x31, 0x32, 0x2E, 0x33, 0x34, 0x35])
        #expect(try SurrealCBOR.decode(taggedDecimalOf12Point345) == .decimal("12.345"))

        let taggedNone = Data([0xC6, 0xF6])
        let plainNull = Data([0xF6])
        #expect(try SurrealCBOR.decode(taggedNone) == .none)
        #expect(try SurrealCBOR.decode(plainNull) == .null)
        #expect(SurrealValue.none != SurrealValue.null)
    }

    @Test("Range keeps its inclusive and exclusive bounds")
    func ranges() throws {
        let value = SurrealValue.range(
            from: SurrealBound(value: .int(1), isInclusive: true),
            to: SurrealBound(value: .int(10), isInclusive: false)
        )
        #expect(try roundTrip(value) == value)
    }

    @Test("Malformed input throws instead of trapping")
    func malformed() {
        #expect(throws: SurrealCBORError.self) { try SurrealCBOR.decode(Data()) }
        #expect(throws: SurrealCBORError.self) { try SurrealCBOR.decode(Data([0x64, 0x61])) }
        #expect(throws: SurrealCBORError.self) { try SurrealCBOR.decode(Data([0x1B, 0x00])) }
        #expect(throws: SurrealCBORError.self) { try SurrealCBOR.decode(Data([0x9F, 0x01])) }
    }

    @Test("A length header near Int max throws instead of overflowing")
    func lengthOverflow() {
        // byte string (major 2) claiming an 8-byte length of Int64.max
        #expect(throws: SurrealCBORError.self) {
            try SurrealCBOR.decode(Data([0x5B, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))
        }
        // text string (major 3) claiming the same
        #expect(throws: SurrealCBORError.self) {
            try SurrealCBOR.decode(Data([0x7B, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))
        }
    }

    @Test("Deeply nested input throws nestingTooDeep instead of overflowing the stack")
    func nestingDepth() {
        var deep = Data(repeating: 0x81, count: 100_000)
        deep.append(0xF6)
        #expect(throws: SurrealCBORError.nestingTooDeep) { try SurrealCBOR.decode(deep) }

        // A legitimately deep-but-bounded value still decodes.
        var shallow = Data(repeating: 0x81, count: 10)
        shallow.append(0x01)
        #expect(throws: Never.self) { try SurrealCBOR.decode(shallow) }
    }

    @Test("Unknown tags fall back to the wrapped value")
    func unknownTag() throws {
        let unknown = Data([0xD8, 0x63, 0x01])
        #expect(try SurrealCBOR.decode(unknown) == .int(1))
    }
}

@Suite("SurrealDB - value display")
struct SurrealDBDisplayTests {
    @Test("Record ids render as table:id")
    func recordIds() {
        #expect(SurrealValue.recordId(SurrealRecordID(table: "person", id: .string("alice"))).displayText == "person:alice")
        #expect(SurrealValue.recordId(SurrealRecordID(table: "person", id: .int(10))).displayText == "person:10")
        #expect(SurrealValue.recordId(SurrealRecordID(table: "person", id: .string("a b"))).displayText == "person:`a b`")
    }

    @Test("Datetimes keep nanosecond precision and handle pre-epoch")
    func datetimes() {
        #expect(SurrealValue.datetime(seconds: 1_726_403_696, nanoseconds: 789_000_000).displayText
            == "2024-09-15T12:34:56.789Z")
        #expect(SurrealValue.datetime(seconds: 1_704_067_200, nanoseconds: 123_456_789).displayText
            == "2024-01-01T00:00:00.123456789Z")
        #expect(SurrealValue.datetime(seconds: -14_182_940, nanoseconds: 0).displayText
            == "1969-07-20T20:17:40Z")
    }

    @Test("Durations render as SurrealQL literals")
    func durations() {
        #expect(SurrealValue.duration(seconds: 3600, nanoseconds: 0).displayText == "1h")
        #expect(SurrealValue.duration(seconds: 5400, nanoseconds: 0).displayText == "1h30m")
        #expect(SurrealValue.duration(seconds: 0, nanoseconds: 500_000_000).displayText == "500ms")
        #expect(SurrealValue.duration(seconds: 0, nanoseconds: 1).displayText == "1ns")
        #expect(SurrealValue.duration(seconds: 0, nanoseconds: 0).displayText == "0ns")
    }

    @Test("Nested values render as compact JSON, capped")
    func nested() {
        let object = SurrealValue.object([
            (key: "city", value: .string("Ho Chi Minh")),
            (key: "n", value: .int(2)),
        ])
        #expect(object.displayText == #"{"city":"Ho Chi Minh","n":2}"#)
        #expect(SurrealValue.array([.string("red"), .string("blue")]).displayText == #"["red","blue"]"#)

        let huge = SurrealValue.array(Array(repeating: .string(String(repeating: "x", count: 100)), count: 500))
        #expect(huge.displayText.count <= SurrealValue.maxSerializedLength + 3)
    }

    @Test("Geometry renders as GeoJSON")
    func geometry() {
        let point = SurrealValue.tagged(tag: 88, value: .array([.double(12.34), .double(56.78)]))
        #expect(point.displayText == #"{"type":"Point","coordinates":[12.34,56.78]}"#)
    }
}
