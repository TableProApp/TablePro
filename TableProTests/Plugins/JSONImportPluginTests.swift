//
//  JSONImportPluginTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct JSONImportPluginTests {
    private func object(_ json: String) throws -> NSDictionary {
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try #require(parsed as? NSDictionary)
    }

    private func anyValue(_ json: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(json.utf8))
    }

    private func field(_ json: String, _ key: String) throws -> Any {
        try #require(object(json)[key])
    }

    // MARK: - Value conversion

    @Test("Null converts to a SQL null cell")
    func testNullValue() {
        #expect(JSONImportParsing.cellValue(from: NSNull()) == .null)
    }

    @Test("Booleans convert to true/false text, not 1/0")
    func testBooleanValue() throws {
        #expect(JSONImportParsing.cellValue(from: try field(#"{"yes": true}"#, "yes")) == .text("true"))
        #expect(JSONImportParsing.cellValue(from: try field(#"{"no": false}"#, "no")) == .text("false"))
    }

    @Test("Numbers convert to their text form")
    func testNumberValues() throws {
        #expect(JSONImportParsing.cellValue(from: try field(#"{"i": 42}"#, "i")) == .text("42"))
        #expect(JSONImportParsing.cellValue(from: try field(#"{"d": 3.5}"#, "d")) == .text("3.5"))
        #expect(JSONImportParsing.cellValue(from: try field(#"{"big": 9007199254740993}"#, "big")) == .text("9007199254740993"))
    }

    @Test("Imported doubles keep every digit needed to round-trip")
    func testDoubleValuesRoundTrip() throws {
        #expect(
            JSONImportParsing.cellValue(from: try field(#"{"d": -3.9192320754595876e-07}"#, "d"))
                == .text("-3.9192320754595876e-07")
        )
        #expect(JSONImportParsing.cellValue(from: try field(#"{"d": 1847.27}"#, "d")) == .text("1847.27"))
        #expect(JSONImportParsing.cellValue(from: try field(#"{"d": 0.1}"#, "d")) == .text("0.1"))
    }

    @Test("Strings pass through unchanged")
    func testStringValue() {
        #expect(JSONImportParsing.cellValue(from: "hello") == .text("hello"))
    }

    @Test("Nested objects and arrays serialize to JSON text")
    func testNestedValue() throws {
        #expect(JSONImportParsing.cellValue(from: try field(#"{"tags": ["a", "b"]}"#, "tags")) == .text("[\"a\",\"b\"]"))
        #expect(JSONImportParsing.cellValue(from: try field(#"{"meta": {"k": 1}}"#, "meta")) == .text("{\"k\":1}"))
    }

    // MARK: - Row extraction

    @Test("Bare array of objects yields rows")
    func testBareArray() throws {
        let rows = try JSONImportParsing.extractRows(from: try anyValue("[{\"id\":1},{\"id\":2}]"), targetTable: nil)
        #expect(rows.count == 2)
    }

    @Test("Single-key table wrapper yields that table's rows")
    func testSingleKeyWrapper() throws {
        let rows = try JSONImportParsing.extractRows(from: try anyValue(#"{"users":[{"id":1}]}"#), targetTable: nil)
        #expect(rows.count == 1)
    }

    @Test("Multi-table wrapper selects the array matching the target table")
    func testMultiTableWrapperMatchesTarget() throws {
        let json = #"{"users":[{"id":1}],"orders":[{"id":1},{"id":2}]}"#
        let rows = try JSONImportParsing.extractRows(from: try anyValue(json), targetTable: "orders")
        #expect(rows.count == 2)
    }

    @Test("Schema-qualified wrapper key matches the unqualified target table")
    func testQualifiedKeyMatch() throws {
        let rows = try JSONImportParsing.extractRows(from: try anyValue(#"{"public.users":[{"id":1}]}"#), targetTable: "users")
        #expect(rows.count == 1)
    }

    @Test("Multi-table wrapper with no match throws")
    func testMultiTableNoMatchThrows() {
        #expect(throws: PluginImportError.self) {
            _ = try JSONImportParsing.extractRows(
                from: try anyValue(#"{"users":[{"id":1}],"orders":[{"id":1}]}"#),
                targetTable: "products"
            )
        }
    }

    @Test("A lone JSON object is treated as a single row")
    func testSingleObjectRow() throws {
        let rows = try JSONImportParsing.extractRows(from: try anyValue(#"{"id":1,"tags":["a"]}"#), targetTable: nil)
        #expect(rows.count == 1)
        #expect(rows[0]["id"] != nil)
    }

    // MARK: - NDJSON line parsing

    @Test("A JSON object line parses to a row")
    func testNdjsonLine() throws {
        let row = try #require(try JSONImportParsing.parseRow(fromLine: Data(#"{"id":1,"name":"x"}"#.utf8)))
        #expect(row["id"] == .text("1"))
        #expect(row["name"] == .text("x"))
    }

    @Test("A non-object line throws")
    func testNdjsonNonObjectThrows() {
        #expect(throws: PluginImportError.self) {
            _ = try JSONImportParsing.parseRow(fromLine: Data("[1, 2, 3]".utf8))
        }
    }

    @Test("A line of JSON whitespace is blank, not an error")
    func testNdjsonBlankLine() throws {
        #expect(try JSONImportParsing.parseRow(fromLine: Data()) == nil)
        #expect(try JSONImportParsing.parseRow(fromLine: Data(" \t\r".utf8)) == nil)
    }

    @Test("A line ending in a carriage return parses")
    func testNdjsonCarriageReturnLine() throws {
        let row = try #require(try JSONImportParsing.parseRow(fromLine: Data("{\"id\":1}\r".utf8)))
        #expect(row["id"] == .text("1"))
    }

    @Test("A line whose bytes are not UTF-8 throws rather than importing replacement characters")
    func testNdjsonInvalidUTF8Throws() {
        let line = Data(#"{"name":""#.utf8) + Data([0xFF]) + Data(#""}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONImportParsing.parseRow(fromLine: line)
        }
    }

    // MARK: - Round trip with the export shape

    @Test("Rows shaped like JSONExportPlugin output convert losslessly")
    func testExportShapeRoundTrip() throws {
        let row = JSONImportParsing.convertRow(
            try object(#"{"id":1,"name":"Alice","deleted_at":null,"score":3.14,"active":true}"#)
        )
        #expect(row["id"] == .text("1"))
        #expect(row["name"] == .text("Alice"))
        #expect(row["deleted_at"] == .null)
        #expect(row["score"] == .text("3.14"))
        #expect(row["active"] == .text("true"))
    }

    // MARK: - Type inference

    private func array(_ json: String) throws -> [Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any])
    }

    private func inferredType(_ json: String) throws -> PluginImportFieldType {
        var kinds = JSONValueKinds()
        for value in try array(json) {
            kinds.add(JSONValueKind(of: value))
        }
        return kinds.inferredType
    }

    @Test("Inference: all integers")
    func testInferInteger() throws {
        #expect(try inferredType("[1, 2, 3]") == .integer)
    }

    @Test("Inference: any decimal makes the field real")
    func testInferReal() throws {
        #expect(try inferredType("[1, 2.5, 3]") == .real)
    }

    @Test("Inference: all booleans")
    func testInferBoolean() throws {
        #expect(try inferredType("[true, false]") == .boolean)
    }

    @Test("Inference: all-nested values are json")
    func testInferJSON() throws {
        #expect(try inferredType(#"[{"a":1}, [1,2]]"#) == .json)
    }

    @Test("Inference: mixed types fall back to text")
    func testInferText() throws {
        #expect(try inferredType(#"["a", 1]"#) == .text)
    }

    @Test("Inference: a value after the type settles on text keeps it text")
    func testInferTextIsFinal() throws {
        #expect(try inferredType(#"["a", 1, true, {"k":1}]"#) == .text)
    }

    @Test("Inference: empty values are text")
    func testInferEmpty() throws {
        #expect(try inferredType("[]") == .text)
    }

    @Test("detectFields reports sorted fields with inferred types and a sample")
    func testDetectFields() throws {
        let raw = #"[{"id":1,"name":"a","active":true},{"id":2,"name":"b","active":false}]"#
        let rows = try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [NSDictionary])
        let fields = try JSONImportParsing.detectFields(in: rows)
        #expect(fields.map(\.name) == ["active", "id", "name"])
        #expect(fields.first { $0.name == "id" }?.inferredType == .integer)
        #expect(fields.first { $0.name == "active" }?.inferredType == .boolean)
        #expect(fields.first { $0.name == "name" }?.inferredType == .text)
        #expect(fields.first { $0.name == "id" }?.sampleValue == "1")
    }
}
