//
//  CSVImportPluginTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("CSV Import Plugin")
struct CSVImportPluginTests {
    private func data(_ text: String) -> Data {
        Data(text.utf8)
    }

    private func fields(_ name: String, _ list: [PluginImportField]) -> PluginImportField? {
        list.first { $0.name == name }
    }

    // MARK: - Dialect resolution

    @Test("Auto dialect detects the comma delimiter")
    func testAutoDelimiter() {
        let dialect = CSVImportParsing.resolveDialect(in: data("a,b,c\n1,2,3\n"), options: CSVImportOptions())
        #expect(dialect.delimiter == 0x2C)
    }

    @Test("Explicit delimiter overrides detection")
    func testDelimiterOverride() {
        var options = CSVImportOptions()
        options.delimiter = .semicolon
        let dialect = CSVImportParsing.resolveDialect(in: data("a,b\n1,2\n"), options: options)
        #expect(dialect.delimiter == 0x3B)
    }

    @Test("Quote character and forced encoding are applied")
    func testQuoteAndEncodingOverride() {
        var options = CSVImportOptions()
        options.quoteCharacter = .singleQuote
        options.encoding = .isoLatin1
        let dialect = CSVImportParsing.resolveDialect(in: data("a,b\n1,2\n"), options: options)
        #expect(dialect.quoteChar == 0x27)
        #expect(dialect.encoding == .isoLatin1)
    }

    // MARK: - Column names

    @Test("Header names are trimmed and empty headers get a placeholder")
    func testColumnNamesFromHeader() {
        let names = CSVImportParsing.columnNames(header: [" id ", "", "name"], columnCount: 3)
        #expect(names == ["id", "Column 2", "name"])
    }

    @Test("Duplicate header names are made unique")
    func testColumnNamesDeduplicated() {
        let names = CSVImportParsing.columnNames(header: ["x", "x", "x"], columnCount: 3)
        #expect(names == ["x", "x 2", "x 3"])
    }

    @Test("Without a header, names are synthesized positionally")
    func testColumnNamesSynthesized() {
        let names = CSVImportParsing.columnNames(header: nil, columnCount: 3)
        #expect(names == ["Column 1", "Column 2", "Column 3"])
    }

    // MARK: - Cell values

    @Test("Empty fields become NULL by default")
    func testEmptyAsNull() {
        #expect(CSVImportParsing.cellValue(from: "", options: CSVImportOptions()) == .null)
    }

    @Test("Empty fields stay empty text when emptyAsNull is off")
    func testEmptyAsText() {
        var options = CSVImportOptions()
        options.emptyAsNull = false
        #expect(CSVImportParsing.cellValue(from: "", options: options) == .text(""))
    }

    @Test("A configured NULL token becomes NULL")
    func testNullToken() {
        var options = CSVImportOptions()
        options.nullString = "\\N"
        #expect(CSVImportParsing.cellValue(from: "\\N", options: options) == .null)
        #expect(CSVImportParsing.cellValue(from: "value", options: options) == .text("value"))
    }

    @Test("Whitespace is trimmed only when requested")
    func testTrimWhitespace() {
        var options = CSVImportOptions()
        options.trimWhitespace = true
        #expect(CSVImportParsing.cellValue(from: "  hi  ", options: options) == .text("hi"))
        #expect(CSVImportParsing.cellValue(from: "  hi  ", options: CSVImportOptions()) == .text("  hi  "))
    }

    @Test("Trimming an all-space field yields NULL when emptyAsNull is on")
    func testTrimToNull() {
        var options = CSVImportOptions()
        options.trimWhitespace = true
        #expect(CSVImportParsing.cellValue(from: "   ", options: options) == .null)
    }

    // MARK: - Row mapping

    @Test("Fields map to column names by position")
    func testRowMapping() {
        let row = CSVImportParsing.row(fields: ["1", "Alice"], columnNames: ["id", "name"], options: CSVImportOptions())
        #expect(row["id"] == .text("1"))
        #expect(row["name"] == .text("Alice"))
    }

    @Test("Missing trailing fields become NULL")
    func testRaggedShortRow() {
        let row = CSVImportParsing.row(fields: ["1"], columnNames: ["id", "name"], options: CSVImportOptions())
        #expect(row["id"] == .text("1"))
        #expect(row["name"] == .null)
    }

    @Test("Extra fields beyond the column count are ignored")
    func testRaggedLongRow() {
        let row = CSVImportParsing.row(fields: ["1", "Alice", "extra"], columnNames: ["id", "name"], options: CSVImportOptions())
        #expect(row.count == 2)
        #expect(row["name"] == .text("Alice"))
    }

    // MARK: - Type mapping

    @Test("Inspector types map to import field types, date falls back to text")
    func testImportFieldTypeMapping() {
        #expect(CSVImportParsing.importFieldType(for: .integer) == .integer)
        #expect(CSVImportParsing.importFieldType(for: .real) == .real)
        #expect(CSVImportParsing.importFieldType(for: .boolean) == .boolean)
        #expect(CSVImportParsing.importFieldType(for: .text) == .text)
        #expect(CSVImportParsing.importFieldType(for: .date) == .text)
    }

    @Test("Blank rows are detected")
    func testIsBlank() {
        #expect(CSVImportParsing.isBlank([""]))
        #expect(CSVImportParsing.isBlank(["", ""]))
        #expect(!CSVImportParsing.isBlank(["", "x"]))
    }

    // MARK: - Field detection

    @Test("Detects header names, sample values, and inferred types")
    func testDetectFields() {
        let csv = "id,name,score,active\n1,Alice,1.5,true\n2,Bob,2.0,false\n"
        let result = CSVImportParsing.detectFields(in: data(csv), options: CSVImportOptions())
        #expect(result.map(\.name) == ["id", "name", "score", "active"])
        #expect(fields("id", result)?.inferredType == .integer)
        #expect(fields("name", result)?.inferredType == .text)
        #expect(fields("score", result)?.inferredType == .real)
        #expect(fields("active", result)?.inferredType == .boolean)
        #expect(fields("name", result)?.sampleValue == "Alice")
    }

    @Test("Quoted fields keep embedded delimiters and newlines")
    func testDetectQuotedFields() {
        let csv = "name,note\n\"a,b\",\"line1\nline2\"\n"
        let result = CSVImportParsing.detectFields(in: data(csv), options: CSVImportOptions())
        #expect(result.map(\.name) == ["name", "note"])
        #expect(fields("name", result)?.sampleValue == "a,b")
        #expect(fields("note", result)?.sampleValue == "line1\nline2")
    }

    @Test("Doubled quotes decode to a single quote")
    func testDetectDoubledQuotes() {
        let csv = "label\n\"say \"\"hi\"\"\"\n"
        let result = CSVImportParsing.detectFields(in: data(csv), options: CSVImportOptions())
        #expect(fields("label", result)?.sampleValue == "say \"hi\"")
    }

    @Test("Header-less detection uses positional names")
    func testDetectWithoutHeader() {
        var options = CSVImportOptions()
        options.hasHeaderRow = false
        let result = CSVImportParsing.detectFields(in: data("1,Alice\n2,Bob\n"), options: options)
        #expect(result.map(\.name) == ["Column 1", "Column 2"])
        #expect(fields("Column 1", result)?.inferredType == .integer)
    }

    @Test("Semicolon-delimited files are auto-detected")
    func testDetectSemicolon() {
        let result = CSVImportParsing.detectFields(in: data("a;b;c\n1;2;3\n"), options: CSVImportOptions())
        #expect(result.map(\.name) == ["a", "b", "c"])
    }

    @Test("Trim option applies during detection, matching imported values")
    func testDetectTrimAffectsInference() {
        let csv = "n\n 1 \n 2 \n"
        var options = CSVImportOptions()
        options.trimWhitespace = true
        let trimmed = CSVImportParsing.detectFields(in: data(csv), options: options)
        #expect(fields("n", trimmed)?.inferredType == .integer)
        #expect(fields("n", trimmed)?.sampleValue == "1")

        let untrimmed = CSVImportParsing.detectFields(in: data(csv), options: CSVImportOptions())
        #expect(fields("n", untrimmed)?.inferredType == .text)
    }

    @Test("NULL token values are excluded from detection samples")
    func testDetectNullTokenExcluded() {
        var options = CSVImportOptions()
        options.nullString = "\\N"
        let result = CSVImportParsing.detectFields(in: data("n\n\\N\n5\n"), options: options)
        #expect(fields("n", result)?.inferredType == .integer)
        #expect(fields("n", result)?.sampleValue == "5")
    }
}
