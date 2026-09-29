//
//  JSONImportFieldDetectionTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct JSONImportFieldDetectionTests {
    private func write(_ bytes: Data, fileExtension: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("json-import-detection-\(UUID().uuidString).\(fileExtension)")
        try bytes.write(to: url)
        return url
    }

    private func detect(_ bytes: Data, fileExtension: String, targetTable: String? = nil) throws -> [PluginImportField] {
        let url = try write(bytes, fileExtension: fileExtension)
        defer { try? FileManager.default.removeItem(at: url) }
        return try JSONImportParsing.detectFields(at: url, targetTable: targetTable)
    }

    private func detectLines(_ lines: [String]) throws -> [PluginImportField] {
        try detect(Data(lines.map { $0 + "\n" }.joined().utf8), fileExtension: "ndjson")
    }

    private func field(_ name: String, in fields: [PluginImportField]) throws -> PluginImportField {
        try #require(fields.first { $0.name == name })
    }

    /// TablePro's own JSON export leaves a null key out of a row, so a column can first appear
    /// deep into the file. Detection used to read 200 rows and never offer it.
    @Test("A key first seen after row 200 of a JSON Lines file is detected")
    func lateKeyInJSONLines() throws {
        var lines = (1...200).map { #"{"id":\#($0)}"# }
        lines.append(#"{"id":201,"note":"late","score":1.5}"#)
        let fields = try detectLines(lines)
        #expect(fields.map(\.name) == ["id", "note", "score"])
        #expect(try field("note", in: fields).sampleValue == "late")
        #expect(try field("note", in: fields).inferredType == .text)
        #expect(try field("score", in: fields).inferredType == .real)
    }

    @Test("A key first seen after element 200 of a JSON array is detected")
    func lateKeyInJSONArray() throws {
        var elements = (1...250).map { #"{"id":\#($0)}"# }
        elements[229] = #"{"id":230,"deleted_at":"2026-01-02"}"#
        let fields = try detect(Data("[\(elements.joined(separator: ","))]".utf8), fileExtension: "json")
        #expect(fields.map(\.name) == ["deleted_at", "id"])
        #expect(try field("deleted_at", in: fields).sampleValue == "2026-01-02")
    }

    @Test("A table-keyed file reports the fields of the target table")
    func tableKeyedFileUsesTheTargetTable() throws {
        let json = #"{"users":[{"id":1}],"orders":[{"id":1},{"id":2,"total":2.5}]}"#
        let fields = try detect(Data(json.utf8), fileExtension: "json", targetTable: "orders")
        #expect(fields.map(\.name) == ["id", "total"])
    }

    @Test("A field's type fits every value in the file, not only the first rows")
    func typeFitsEveryValue() throws {
        var lines = (1...300).map { #"{"code":\#($0)}"# }
        lines.append(#"{"code":"A-301"}"#)
        #expect(try field("code", in: detectLines(lines)).inferredType == .text)
    }

    @Test("A key first seen past the first megabyte is detected")
    func lateKeyPastTheFirstChunk() throws {
        let padding = String(repeating: "x", count: 1_000)
        var lines = Array(repeating: #"{"pad":"\#(padding)"}"#, count: 1_200)
        lines.append(#"{"pad":"y","city":"Hà Nội"}"#)
        let fields = try detectLines(lines)
        #expect(try field("city", in: fields).sampleValue == "Hà Nội")
    }

    /// Detection decoded the first 262,144 bytes as UTF-8 text, which fails outright when that
    /// byte falls inside a character, so the whole file read as having no fields.
    @Test("Text whose characters straddle the old prefix and the read chunk is detected")
    func multiByteCharacterAtTheOldPrefixEnd() throws {
        var bytes = Data()
        let namePrefixLength = #"{"name":""#.utf8.count
        func appendLine(_ line: String) {
            bytes.append(Data((line + "\n").utf8))
        }
        func appendPadding(untilNextLineStartsAt start: Int) {
            let fixedLength = #"{"pad":""}"#.utf8.count + 1
            appendLine(#"{"pad":""# + String(repeating: "x", count: start - bytes.count - fixedLength) + #""}"#)
        }
        appendPadding(untilNextLineStartsAt: 262_144 - 1 - namePrefixLength)
        appendLine(#"{"name":"東京"}"#)
        appendPadding(untilNextLineStartsAt: JSONLineReader.defaultChunkSize - 1 - namePrefixLength)
        appendLine(#"{"name":"東京","city":"Hà Nội"}"#)
        try #require(bytes[262_144] & 0xC0 == 0x80)
        try #require(bytes[JSONLineReader.defaultChunkSize] & 0xC0 == 0x80)

        let fields = try detect(bytes, fileExtension: "ndjson")
        #expect(fields.map(\.name) == ["city", "name", "pad"])
        #expect(try field("name", in: fields).sampleValue == "東京")
        #expect(try field("city", in: fields).sampleValue == "Hà Nội")
    }

    @Test("A JSON Lines file with CRLF line endings is detected")
    func crlfLineEndings() throws {
        let fields = try detect(Data("{\"a\":1}\r\n{\"a\":2,\"b\":\"x\"}\r\n".utf8), fileExtension: "jsonl")
        #expect(fields.map(\.name) == ["a", "b"])
        #expect(try field("a", in: fields).inferredType == .integer)
    }

    @Test("A string holding U+2028 stays one row")
    func lineSeparatorInsideAString() throws {
        let fields = try detectLines(["{\"note\":\"a\u{2028}b\"}"])
        #expect(try field("note", in: fields).sampleValue == "a\u{2028}b")
    }

    @Test("Unreadable and non-object lines are passed over")
    func unreadableLinesArePassedOver() throws {
        let fields = try detectLines([#"{"a":1}"#, "{ this is not json", "[1, 2]", "", #"{"b":2}"#])
        #expect(fields.map(\.name) == ["a", "b"])
    }

    @Test("A field that is only ever null is detected as text with no sample")
    func nullOnlyField() throws {
        let fields = try detectLines([#"{"a":null}"#, #"{"a":null}"#])
        #expect(try field("a", in: fields).inferredType == .text)
        #expect(try field("a", in: fields).sampleValue == nil)
    }

    @Test("Detection stops once its task is cancelled", arguments: ["ndjson", "json"])
    func cancelledDetectionStops(fileExtension: String) async throws {
        let contents = fileExtension == "json" ? #"[{"a":1}]"# : "{\"a\":1}\n"
        let url = try write(Data(contents.utf8), fileExtension: fileExtension)
        defer { try? FileManager.default.removeItem(at: url) }
        let detection = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try JSONImportParsing.detectFields(at: url, targetTable: nil)
        }
        await #expect(throws: CancellationError.self) {
            _ = try await detection.value
        }
    }
}
