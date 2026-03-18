//
//  JsonRowConverterTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

@Suite("JSON Row Converter")
struct JsonRowConverterTests {
    private func makeConverter(columns: [String], columnTypes: [ColumnType]) -> JsonRowConverter {
        JsonRowConverter(columns: columns, columnTypes: columnTypes)
    }

    // MARK: - Basic

    @Test("Empty rows produces empty JSON array")
    func emptyRows() {
        let converter = makeConverter(columns: ["id"], columnTypes: [.integer(rawType: nil)])
        let result = converter.generateJson(rows: [])
        #expect(result == "[]")
    }

    @Test("Nil values produce JSON null")
    func nilValues() {
        let converter = makeConverter(columns: ["name"], columnTypes: [.text(rawType: nil)])
        let result = converter.generateJson(rows: [[nil]])
        #expect(result.contains("null"))
        #expect(!result.contains("\"null\""))
    }

    // MARK: - Integer

    @Test("Integer column produces unquoted number")
    func integerColumn() {
        let converter = makeConverter(columns: ["id"], columnTypes: [.integer(rawType: nil)])
        let result = converter.generateJson(rows: [["42"]])
        #expect(result.contains(": 42"))
        #expect(!result.contains("\"42\""))
    }

    @Test("Integer fallback for non-numeric value produces quoted string")
    func integerFallback() {
        let converter = makeConverter(columns: ["id"], columnTypes: [.integer(rawType: nil)])
        let result = converter.generateJson(rows: [["abc"]])
        #expect(result.contains("\"abc\""))
    }

    // MARK: - Decimal

    @Test("Decimal column produces unquoted number")
    func decimalColumn() {
        let converter = makeConverter(columns: ["price"], columnTypes: [.decimal(rawType: nil)])
        let result = converter.generateJson(rows: [["3.14"]])
        #expect(result.contains(": 3.14"))
        #expect(!result.contains("\"3.14\""))
    }

    @Test("Decimal preserves full precision for high-precision values")
    func decimalPrecision() {
        let converter = makeConverter(columns: ["amount"], columnTypes: [.decimal(rawType: nil)])
        let result = converter.generateJson(rows: [["123456.789"]])
        #expect(result.contains(": 123456.789"))
    }

    @Test("Decimal infinity and NaN produce quoted strings")
    func decimalInfinityNaN() {
        let converter = makeConverter(columns: ["a", "b"], columnTypes: [.decimal(rawType: nil), .decimal(rawType: nil)])
        let result = converter.generateJson(rows: [["inf", "nan"]])
        #expect(result.contains("\"inf\""))
        #expect(result.contains("\"nan\""))
    }

    // MARK: - Boolean

    @Test("Boolean true variants")
    func booleanTrueVariants() {
        let converter = makeConverter(
            columns: ["a", "b", "c", "d"],
            columnTypes: Array(repeating: ColumnType.boolean(rawType: nil), count: 4)
        )
        let result = converter.generateJson(rows: [["true", "1", "yes", "on"]])
        let trueCount = result.components(separatedBy: ": true").count - 1
        #expect(trueCount == 4)
    }

    @Test("Boolean false variants")
    func booleanFalseVariants() {
        let converter = makeConverter(
            columns: ["a", "b", "c", "d"],
            columnTypes: Array(repeating: ColumnType.boolean(rawType: nil), count: 4)
        )
        let result = converter.generateJson(rows: [["false", "0", "no", "off"]])
        let falseCount = result.components(separatedBy: ": false").count - 1
        #expect(falseCount == 4)
    }

    @Test("Boolean unknown value produces quoted string")
    func booleanUnknown() {
        let converter = makeConverter(columns: ["flag"], columnTypes: [.boolean(rawType: nil)])
        let result = converter.generateJson(rows: [["maybe"]])
        #expect(result.contains("\"maybe\""))
    }

    // MARK: - JSON

    @Test("Valid JSON column is embedded verbatim")
    func validJsonColumn() {
        let converter = makeConverter(columns: ["data"], columnTypes: [.json(rawType: nil)])
        let jsonValue = "{\"key\":\"value\"}"
        let result = converter.generateJson(rows: [[jsonValue]])
        #expect(result.contains(": {\"key\":\"value\"}"))
    }

    @Test("Invalid JSON column produces quoted string")
    func invalidJsonColumn() {
        let converter = makeConverter(columns: ["data"], columnTypes: [.json(rawType: nil)])
        let result = converter.generateJson(rows: [["{broken"]])
        #expect(result.contains("\"{broken\""))
    }

    @Test("JSON column with trailing whitespace is trimmed before embedding")
    func jsonColumnTrimmed() {
        let converter = makeConverter(columns: ["data"], columnTypes: [.json(rawType: nil)])
        let result = converter.generateJson(rows: [["{\"k\":1}\n"]])
        #expect(result.contains(": {\"k\":1}"))
        #expect(!result.contains(": {\"k\":1}\n\n"))
    }

    // MARK: - String escaping

    @Test("Text with double quotes is escaped")
    func textWithDoubleQuotes() {
        let converter = makeConverter(columns: ["name"], columnTypes: [.text(rawType: nil)])
        let result = converter.generateJson(rows: [["say \"hello\""]])
        #expect(result.contains("say \\\"hello\\\""))
    }

    @Test("Text with backslashes is escaped")
    func textWithBackslashes() {
        let converter = makeConverter(columns: ["path"], columnTypes: [.text(rawType: nil)])
        let result = converter.generateJson(rows: [["C:\\Users\\test"]])
        #expect(result.contains("C:\\\\Users\\\\test"))
    }

    @Test("Text with control characters is escaped")
    func textWithControlCharacters() {
        let converter = makeConverter(columns: ["text"], columnTypes: [.text(rawType: nil)])
        let result = converter.generateJson(rows: [["line1\nline2\ttab"]])
        #expect(result.contains("line1\\nline2\\ttab"))
    }

    // MARK: - Column name escaping

    @Test("Column name with special characters is escaped in key")
    func columnNameSpecialChars() {
        let converter = makeConverter(columns: ["col\"umn"], columnTypes: [.text(rawType: nil)])
        let result = converter.generateJson(rows: [["value"]])
        #expect(result.contains("\"col\\\"umn\""))
    }

    // MARK: - Row cap

    @Test("Output is capped at 50,000 rows")
    func rowCap() {
        let converter = makeConverter(columns: ["id"], columnTypes: [.text(rawType: nil)])
        let marker = "MARKER_VAL"
        let rows = Array(repeating: [marker] as [String?], count: 50_001)
        let result = converter.generateJson(rows: rows)
        let count = result.components(separatedBy: marker).count - 1
        #expect(count == 50_000)
    }

    // MARK: - Multiple rows

    @Test("Multiple rows are comma-separated")
    func multipleRows() {
        let converter = makeConverter(columns: ["id"], columnTypes: [.integer(rawType: nil)])
        let result = converter.generateJson(rows: [["1"], ["2"], ["3"]])
        #expect(result.contains("},\n"))
        #expect(result.hasSuffix("  }\n]"))
    }

    // MARK: - Edge cases

    @Test("columnTypes shorter than columns defaults to text")
    func columnTypesShorter() {
        let converter = makeConverter(columns: ["id", "name"], columnTypes: [.integer(rawType: nil)])
        let result = converter.generateJson(rows: [["42", "hello"]])
        #expect(result.contains(": 42"))
        #expect(result.contains("\"hello\""))
    }

    @Test("Row values shorter than columns produces null for missing")
    func rowValuesShorter() {
        let converter = makeConverter(
            columns: ["a", "b", "c"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil), .text(rawType: nil)]
        )
        let result = converter.generateJson(rows: [["only_one"]])
        #expect(result.contains("\"only_one\""))
        let nullCount = result.components(separatedBy: "null").count - 1
        #expect(nullCount == 2)
    }

    // MARK: - Blob

    @Test("Blob column produces base64 encoded value")
    func blobColumn() {
        let converter = makeConverter(columns: ["data"], columnTypes: [.blob(rawType: nil)])
        let result = converter.generateJson(rows: [["hello"]])
        // "hello" in base64 is "aGVsbG8="
        #expect(result.contains("\"aGVsbG8=\""))
    }
}
