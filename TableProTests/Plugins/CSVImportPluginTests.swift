//
//  CSVImportPluginTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import TableProTabularIO
import Testing

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

    @Test("Quote character is applied, and the prepared text is always parsed as UTF-8")
    func testQuoteOverrideParsesUTF8() {
        var options = CSVImportOptions()
        options.quoteCharacter = .singleQuote
        options.encoding = .isoLatin1
        let dialect = CSVImportParsing.resolveDialect(in: data("a,b\n1,2\n"), options: options)
        #expect(dialect.quoteChar == 0x27)
        #expect(dialect.escapeChar == 0x27)
        #expect(dialect.encoding == .utf8)
    }

    @Test("A double quote inside a single-quoted field stays in the field")
    func testDoubleQuoteInsideSingleQuotedField() {
        var options = CSVImportOptions()
        options.quoteCharacter = .singleQuote
        options.hasHeaderRow = true
        let detected = CSVImportParsing.detectFields(in: data("a,b\n'say \"hi\"',x\nnext,row\n"), options: options)
        #expect(detected.map(\.name) == ["a", "b"])
        #expect(fields("a", detected)?.sampleValue == "say \"hi\"")
        #expect(fields("b", detected)?.sampleValue == "x")
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

    @Test("A header spelled out keeps its name over a blank header's placeholder that comes first")
    func testLiteralHeaderKeepsItsName() {
        let names = CSVImportParsing.columnNames(header: ["", "Column 1"], columnCount: 2)
        #expect(names == ["Column 1 2", "Column 1"])
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

    // MARK: - File encodings

    private func writeFile(_ bytes: Data, fileExtension: String = "csv") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CSVImportPluginTests-\(UUID().uuidString).\(fileExtension)")
        try bytes.write(to: url)
        return url
    }

    private func shiftJIS(_ text: String) throws -> Data {
        try #require(text.data(using: .shiftJIS, allowLossyConversion: false))
    }

    private func fields(ofFile bytes: Data, options: CSVImportOptions = CSVImportOptions(), fileExtension: String = "csv") throws -> [PluginImportField] {
        let url = try writeFile(bytes, fileExtension: fileExtension)
        defer { try? FileManager.default.removeItem(at: url) }
        let text = try CSVImportText.prefix(of: url, length: 1_048_576, encoding: options.encoding)
        return CSVImportParsing.detectFields(in: text.data, options: options)
    }

    @Test("A Shift JIS export keeps its commas when full-width dashes and ポ carry a pipe byte")
    func testShiftJISCommaFileWithPipeTrailBytes() throws {
        let bytes = try shiftJIS("""
        顧客ID,氏名,住所,電話
        1,山田太郎,東京都港区芝公園４－２－８,03－1234－5678
        2,ポイント商事,大阪府大阪市北区梅田１－１,06－9876－5432
        3,ソフト表示株式会社,愛知県名古屋市中区栄３－５,052－111－2222

        """)
        let detected = try fields(ofFile: bytes)
        #expect(detected.map(\.name) == ["顧客ID", "氏名", "住所", "電話"])
        #expect(fields("住所", detected)?.sampleValue == "東京都港区芝公園４－２－８")
        #expect(fields("氏名", detected)?.sampleValue == "山田太郎")
    }

    @Test("A pipe-delimited Shift JIS file splits on real pipes only")
    func testShiftJISPipeDelimitedFile() throws {
        let bytes = try shiftJIS("名称|読み\nポイント交換|ぽいんとこうかん\nソフト表示|そふとひょうじ\n")
        let detected = try fields(ofFile: bytes)
        #expect(detected.map(\.name) == ["名称", "読み"])
        #expect(fields("名称", detected)?.sampleValue == "ポイント交換")
    }

    @Test("A UTF-16 file with a byte order mark imports as text, not as split code units")
    func testUTF16TabSeparatedFile() throws {
        let text = "名前\t住所\n吉田\t三上\n本田\t日本\n"
        let bytes = Data([0xFF, 0xFE]) + (try #require(text.data(using: .utf16LittleEndian)))
        let detected = try fields(ofFile: bytes, fileExtension: "tsv")
        #expect(detected.map(\.name) == ["名前", "住所"])
        #expect(fields("住所", detected)?.sampleValue == "三上")
    }

    @Test("A chosen encoding wins over detection")
    func testChosenEncodingIsHonored() throws {
        var options = CSVImportOptions()
        options.encoding = .isoLatin1
        let bytes = Data([0x6E, 0x61, 0x6D, 0x65, 0x0A, 0x43, 0x61, 0x66, 0xE9, 0x0A])
        let detected = try fields(ofFile: bytes, options: options)
        #expect(fields("name", detected)?.sampleValue == "Caf\u{E9}")
    }

    private func makeCopyDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CSVImportPluginTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func copies(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }

    @Test("The whole-file import reads the same text as the preview and removes its UTF-8 copy")
    func testContentsTranscodeAndCleanUp() throws {
        let url = try writeFile(try shiftJIS("顧客ID,氏名\n1,髙橋\n"))
        let directory = try makeCopyDirectory()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: directory)
        }
        let text = try CSVImportText.contents(of: url, encoding: .auto, copyingInto: directory)
        #expect(text.encoding == .shiftJIS)
        #expect(String(data: text.data, encoding: .utf8) == "顧客ID,氏名\n1,髙橋\n")
        #expect(try copies(in: directory).count == 1)
        text.removeTemporaryFile()
        #expect(try copies(in: directory).isEmpty)
    }

    @Test("Stopping the import stops the transcode and leaves no UTF-8 copy")
    func testTranscodeStopsWhenCancelled() throws {
        let url = try writeFile(try shiftJIS(String(repeating: "1,髙橋\n", count: 400_000)))
        let directory = try makeCopyDirectory()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: directory)
        }
        #expect(throws: TabularCancellation.self) {
            try CSVImportText.contents(of: url, encoding: .auto, copyingInto: directory, isCancelled: { true })
        }
        #expect(try copies(in: directory).isEmpty)
    }

    @Test("Every encoding option names a real encoding")
    func testEncodingOptionsMapToTabularEncodings() {
        for option in CSVImportOptions.TextEncoding.allCases where option != .auto {
            #expect(option.tabularEncoding != nil, "\(option)")
        }
        #expect(CSVImportOptions.TextEncoding.auto.tabularEncoding == nil)
    }
}
