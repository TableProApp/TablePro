import Foundation
import Testing

@testable import TableProSpannerCore

@Suite("SpannerValueDecoder")
struct SpannerValueDecoderTests {
    private static let int64 = SpannerType(code: "INT64")
    private static let string = SpannerType(code: "STRING")
    private static let float64 = SpannerType(code: "FLOAT64")
    private static let float32 = SpannerType(code: "FLOAT32")
    private static let bytes = SpannerType(code: "BYTES")
    private static let bool = SpannerType(code: "BOOL")
    private static let numeric = SpannerType(code: "NUMERIC")
    private static let json = SpannerType(code: "JSON")

    private static func array(_ element: SpannerType) -> SpannerType {
        SpannerType(code: "ARRAY", arrayElementType: element)
    }

    private func text(_ value: SpannerJSONValue, _ type: SpannerType) -> String? {
        guard case .text(let text) = SpannerValueDecoder.cell(value, type: type) else { return nil }
        return text
    }

    @Test("NULL of any type is a null cell")
    func nulls() {
        #expect(SpannerValueDecoder.cell(.null, type: Self.int64) == .null)
        #expect(SpannerValueDecoder.cell(.null, type: Self.bytes) == .null)
        #expect(SpannerValueDecoder.cell(.null, type: Self.array(Self.int64)) == .null)
    }

    @Test("Exact types keep their server text verbatim")
    func verbatimStrings() {
        #expect(text(.string("9223372036854775807"), Self.int64) == "9223372036854775807")
        #expect(text(.string("1.50"), Self.numeric) == "1.50")
        #expect(text(.string("2024-01-01"), SpannerType(code: "DATE")) == "2024-01-01")
        #expect(text(.string("2024-01-01T00:00:00.123456Z"), SpannerType(code: "TIMESTAMP")) == "2024-01-01T00:00:00.123456Z")
        #expect(text(.string("null"), Self.string) == "null")
        #expect(text(.string(""), Self.string) == "")
        #expect(text(.string("P1Y2M3D"), SpannerType(code: "INTERVAL")) == "P1Y2M3D")
        #expect(text(.string(#"{"a":1}"#), Self.json) == #"{"a":1}"#)
    }

    @Test("Booleans are true and false")
    func booleans() {
        #expect(text(.bool(true), Self.bool) == "true")
        #expect(text(.bool(false), Self.bool) == "false")
    }

    @Test("Floats print their shortest round-trip text without a trailing .0")
    func floats() {
        #expect(text(.number(1.5), Self.float64) == "1.5")
        #expect(text(.number(3), Self.float64) == "3")
        #expect(text(.number(1e300), Self.float64) == "1e+300")
        #expect(text(.number(1e20), Self.float64) == "1e+20")
        #expect(text(.number(-0.25), Self.float64) == "-0.25")
        #expect(text(.number(0.10000000149011612), Self.float32) == "0.1")
        #expect(text(.string("NaN"), Self.float64) == "NaN")
        #expect(text(.string("-Infinity"), Self.float32) == "-Infinity")
    }

    @Test("Bytes decode from base64, and bad base64 stays text")
    func bytesCells() {
        #expect(SpannerValueDecoder.cell(.string("AAE="), type: Self.bytes) == .bytes(Data([0x00, 0x01])))
        #expect(SpannerValueDecoder.cell(.string("not base64!"), type: Self.bytes) == .text("not base64!"))
    }

    @Test("Arrays render as compact JSON with typed elements")
    func arrays() {
        #expect(text(.list([.string("1"), .string("2"), .null]), Self.array(Self.int64)) == "[1,2,null]")
        #expect(text(.list([.string("a\"b"), .string("line\nbreak")]), Self.array(Self.string)) == #"["a\"b","line\nbreak"]"#)
        #expect(text(.list([.bool(true), .bool(false)]), Self.array(Self.bool)) == "[true,false]")
        #expect(text(.list([.number(1.5), .string("NaN"), .number(2)]), Self.array(Self.float64)) == #"[1.5,"NaN",2]"#)
        #expect(text(.list([.string("YWI=")]), Self.array(Self.bytes)) == #"["YWI="]"#)
        #expect(text(.list([.string("1.50")]), Self.array(Self.numeric)) == "[1.50]")
        #expect(text(.list([.string(#"{"k":[1]}"#)]), Self.array(Self.json)) == #"[{"k":[1]}]"#)
        #expect(text(.list([]), Self.array(Self.int64)) == "[]")
    }

    @Test("A PG numeric NaN inside an array stays a JSON string")
    func pgNumericNaN() {
        let type = Self.array(SpannerType(code: "NUMERIC", typeAnnotation: "PG_NUMERIC"))
        #expect(text(.list([.string("NaN"), .string("-3")]), type) == #"["NaN",-3]"#)
    }

    @Test("Structs render as objects keyed by field name, unnamed fields by position")
    func structs() {
        let type = Self.array(SpannerType(code: "STRUCT", structFields: [
            SpannerField(name: "x", type: Self.int64),
            SpannerField(name: "", type: Self.string),
            SpannerField(name: "tags", type: Self.array(Self.string))
        ]))
        let value = SpannerJSONValue.list([.list([.string("1"), .string("y"), .list([.string("t")])])])
        #expect(text(value, type) == #"[{"x":1,"_1":"y","tags":["t"]}]"#)
    }

    @Test("Control characters and quotes in keys and strings are escaped")
    func escaping() {
        let type = SpannerType(code: "STRUCT", structFields: [SpannerField(name: "a\"b", type: Self.string)])
        #expect(text(.list([.string("\u{01}\t\\")]), type) == "{\"a\\\"b\":\"\\u0001\\t\\\\\"}")
    }

    @Test("Rows decode per field, padding a short row with nulls")
    func rows() {
        let fields = [SpannerField(name: "", type: Self.int64), SpannerField(name: "b", type: Self.bytes)]
        let rows = SpannerValueDecoder.rows([[.string("1"), .string("AAE=")], [.string("2")]], fields: fields)
        #expect(rows == [[.text("1"), .bytes(Data([0x00, 0x01]))], [.text("2"), .null]])
    }

    @Test("Display type names are canonical")
    func displayNames() {
        #expect(SpannerValueDecoder.displayTypeName(Self.int64) == "INT64")
        #expect(SpannerValueDecoder.displayTypeName(Self.array(Self.int64)) == "ARRAY<INT64>")
        #expect(SpannerValueDecoder.displayTypeName(SpannerType(code: "JSON", typeAnnotation: "PG_JSONB")) == "JSONB")
        #expect(SpannerValueDecoder.displayTypeName(SpannerType(code: "NUMERIC", typeAnnotation: "PG_NUMERIC")) == "NUMERIC")
        let structType = SpannerType(code: "STRUCT", structFields: [
            SpannerField(name: "a", type: Self.int64),
            SpannerField(name: "", type: Self.array(Self.string))
        ])
        #expect(SpannerValueDecoder.displayTypeName(structType) == "STRUCT<a INT64, ARRAY<STRING>>")
        #expect(SpannerValueDecoder.displayTypeName(Self.array(structType)) == "ARRAY<STRUCT<a INT64, ARRAY<STRING>>>")
    }
}
