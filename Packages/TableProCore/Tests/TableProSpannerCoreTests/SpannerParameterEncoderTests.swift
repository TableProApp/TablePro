import Foundation
import Testing

@testable import TableProSpannerCore

@Suite("SpannerParameterEncoder")
struct SpannerParameterEncoderTests {
    private static let bool = SpannerType(code: "BOOL")
    private static let float64 = SpannerType(code: "FLOAT64")
    private static let float32 = SpannerType(code: "FLOAT32")
    private static let int64 = SpannerType(code: "INT64")
    private static let bytes = SpannerType(code: "BYTES")
    private static let json = SpannerType(code: "JSON")

    private static func array(_ element: SpannerType) -> SpannerType {
        SpannerType(code: "ARRAY", arrayElementType: element)
    }

    private func encode(_ cell: SpannerCell, _ type: SpannerType, index: Int = 1) throws -> SpannerJSONValue {
        try SpannerParameterEncoder.encode(cell, as: type, index: index)
    }

    @Test("NULL is sent as JSON null for every type", arguments: [
        SpannerType(code: "BOOL"), SpannerType(code: "STRUCT"), SpannerType(code: "ARRAY")
    ])
    func nulls(type: SpannerType) throws {
        #expect(try encode(.null, type) == .null)
    }

    @Test("BOOL accepts true, false, 1 and 0 in any case")
    func booleans() throws {
        #expect(try encode(.text("TRUE"), Self.bool) == .bool(true))
        #expect(try encode(.text(" false "), Self.bool) == .bool(false))
        #expect(try encode(.text("1"), Self.bool) == .bool(true))
        #expect(try encode(.text("0"), Self.bool) == .bool(false))
    }

    @Test("BOOL refuses anything else and names the parameter")
    func notBoolean() {
        #expect(throws: SpannerParameterEncodingError.notBoolean(index: 3)) {
            try encode(.text("yes"), Self.bool, index: 3)
        }
    }

    @Test("Floats are JSON numbers, and the special values are their canonical strings")
    func floats() throws {
        #expect(try encode(.text("1.5"), Self.float64) == .number(1.5))
        #expect(try encode(.text(" -2e3 "), Self.float32) == .number(-2_000))
        #expect(try encode(.text("nan"), Self.float64) == .string("NaN"))
        #expect(try encode(.text("Infinity"), Self.float64) == .string("Infinity"))
        #expect(try encode(.text("-inf"), Self.float32) == .string("-Infinity"))
    }

    @Test("A float that does not parse is refused", arguments: ["abc", "", "1.5.5", "1e999"])
    func notNumber(text: String) {
        #expect(throws: SpannerParameterEncodingError.notNumber(index: 2)) {
            try encode(.text(text), Self.float64, index: 2)
        }
    }

    @Test("Exact and textual types are JSON strings", arguments: ["INT64", "NUMERIC", "STRING", "DATE", "TIMESTAMP", "JSON", "UUID"])
    func strings(code: String) throws {
        #expect(try encode(.text("12"), SpannerType(code: code)) == .string("12"))
    }

    @Test("Bytes are base64, and text for a BYTES column is taken as base64 as given")
    func bytesValues() throws {
        #expect(try encode(.bytes(Data([0x00, 0xFF])), Self.bytes) == .string("AP8="))
        #expect(try encode(.text("AP8="), Self.bytes) == .string("AP8="))
    }

    @Test("Bytes for a text column are sent as their UTF-8 text")
    func bytesForText() throws {
        #expect(try encode(.bytes(Data("hi".utf8)), SpannerType(code: "STRING")) == .string("hi"))
        #expect(throws: SpannerParameterEncodingError.unsupportedType("STRING")) {
            try encode(.bytes(Data([0xFF, 0xFE])), SpannerType(code: "STRING"))
        }
    }

    @Test("ARRAY<INT64> numbers become decimal strings, strings stay strings, nulls stay null")
    func int64Array() throws {
        let encoded = try encode(.text(#"[1, "2", null, 9007199254740993]"#), Self.array(Self.int64))
        #expect(encoded == .list([.string("1"), .string("2"), .null, .string("9007199254740993")]))
    }

    @Test("ARRAY<BOOL> and ARRAY<FLOAT64> coerce their elements")
    func typedArrays() throws {
        #expect(try encode(.text(#"[true, "false", 1]"#), Self.array(Self.bool)) == .list([.bool(true), .bool(false), .bool(true)]))
        #expect(try encode(.text(#"[1.5, "NaN", 2]"#), Self.array(Self.float64)) == .list([.number(1.5), .string("NaN"), .number(2)]))
        #expect(throws: SpannerParameterEncodingError.notBoolean(index: 4)) {
            try encode(.text(#"["maybe"]"#), Self.array(Self.bool), index: 4)
        }
        #expect(throws: SpannerParameterEncodingError.notNumber(index: 4)) {
            try encode(.text("[true]"), Self.array(Self.float64), index: 4)
        }
    }

    @Test("ARRAY<BYTES> strings are sent as given base64")
    func bytesArray() throws {
        #expect(try encode(.text(#"["YWI=", null]"#), Self.array(Self.bytes)) == .list([.string("YWI="), .null]))
    }

    @Test("ARRAY<JSON> sends each element as JSON text")
    func jsonArray() throws {
        let encoded = try encode(.text(#"[{"b":1,"a":[2]}, "x", 3]"#), Self.array(Self.json))
        #expect(encoded == .list([.string(#"{"a":[2],"b":1}"#), .string("x"), .string("3")]))
    }

    @Test("Text that is not a JSON array is refused for an ARRAY", arguments: ["1,2", "[1,2", "\"[1]\"", "{\"a\":1}", ""])
    func notJSONArray(text: String) {
        #expect(throws: SpannerParameterEncodingError.notJSONArray(index: 5)) {
            try encode(.text(text), Self.array(Self.int64), index: 5)
        }
    }

    @Test("A nested value where a scalar element belongs is refused")
    func nestedElement() {
        #expect(throws: SpannerParameterEncodingError.notJSONArray(index: 1)) {
            try encode(.text("[[1]]"), Self.array(Self.int64))
        }
    }

    @Test("STRUCT parameters and arrays of structs are unsupported")
    func structs() {
        let structType = SpannerType(code: "STRUCT", structFields: [SpannerField(name: "a", type: Self.int64)])
        #expect(throws: SpannerParameterEncodingError.unsupportedType("STRUCT<a INT64>")) {
            try encode(.text("{}"), structType)
        }
        #expect(throws: SpannerParameterEncodingError.unsupportedType("STRUCT<a INT64>")) {
            try encode(.text("[{}]"), Self.array(structType))
        }
    }

    @Test("An array type with no element type is unsupported")
    func arrayWithoutElement() {
        #expect(throws: SpannerParameterEncodingError.unsupportedType("ARRAY")) {
            try encode(.text("[1]"), SpannerType(code: "ARRAY"))
        }
    }
}
