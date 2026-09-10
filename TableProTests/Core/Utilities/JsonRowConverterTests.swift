//
//  JsonRowConverterTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit

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

    @Test("Integer literals outside Int64 preserve their exact JSON number")
    func integerOutsideInt64() {
        let converter = makeConverter(
            columns: ["uint64", "belowInt64", "uint128"],
            columnTypes: Array(repeating: ColumnType.integer(rawType: nil), count: 3)
        )

        let result = converter.generateJson(rows: [[
            "18446744073709551615",
            "-9223372036854775809",
            "340282366920938463463374607431768211455",
        ]])

        #expect(result == """
        [
          {
            "uint64": 18446744073709551615,
            "belowInt64": -9223372036854775809,
            "uint128": 340282366920938463463374607431768211455
          }
        ]
        """)
    }

    @Test("Integral decimal and exponent spellings still normalize")
    func integerIntegralSpellings() {
        let converter = makeConverter(
            columns: [
                "decimal", "exponent", "signedExponent", "shiftedDecimal",
                "negativeExponent", "trailingPoint", "leadingPoint",
            ],
            columnTypes: Array(repeating: ColumnType.integer(rawType: nil), count: 7)
        )

        let result = converter.generateJson(rows: [[
            "42.0", "1e3", "+1e3", "1.2e1", "1000e-3", "1.", "-.0",
        ]])

        #expect(result == """
        [
          {
            "decimal": 42,
            "exponent": 1000,
            "signedExponent": 1000,
            "shiftedDecimal": 12,
            "negativeExponent": 1,
            "trailingPoint": 1,
            "leadingPoint": 0
          }
        ]
        """)
    }

    @Test("Integral spellings outside Int64 stay numbers and only fractions become strings")
    func integerWideSpellings() {
        let converter = makeConverter(
            columns: ["decimal", "exponent", "negative", "fraction"],
            columnTypes: Array(repeating: ColumnType.integer(rawType: nil), count: 4)
        )

        let result = converter.generateJson(rows: [[
            "9223372036854775808.0",
            "9.223372036854776e18",
            "-9223372036854775809.0",
            "42.0000000000000000001",
        ]])

        #expect(result == """
        [
          {
            "decimal": 9223372036854775808,
            "exponent": 9223372036854776000,
            "negative": -9223372036854775809,
            "fraction": "42.0000000000000000001"
          }
        ]
        """)
    }

    @Test("A wide integer serializes the same whichever spelling the driver used")
    func integerSpellingDoesNotChangeTheJsonType() {
        let converter = makeConverter(
            columns: ["plain", "trailingZero", "exponent", "paddedExponent"],
            columnTypes: Array(repeating: ColumnType.integer(rawType: nil), count: 4)
        )

        let result = converter.generateJson(rows: [[
            "18446744073709551615",
            "18446744073709551615.0",
            "1844674407370955.1615e4",
            "184467440737095516150e-1",
        ]])

        #expect(result == """
        [
          {
            "plain": 18446744073709551615,
            "trailingZero": 18446744073709551615,
            "exponent": 18446744073709551615,
            "paddedExponent": 18446744073709551615
          }
        ]
        """)
    }

    @Test("Large integral decimal spellings normalize without rounding")
    func integerLargeDecimalSpelling() {
        let converter = makeConverter(columns: ["id"], columnTypes: [.integer(rawType: nil)])

        let result = converter.generateJson(rows: [["9007199254740993.0"]])

        #expect(result == """
        [
          {
            "id": 9007199254740993
          }
        ]
        """)
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

    @Test("Decimal spellings JSON rejects keep every digit instead of narrowing")
    func decimalNonJsonSpellingsKeepPrecision() {
        let converter = makeConverter(
            columns: ["leadingPlus", "leadingPoint", "trailingPoint", "paddedScale"],
            columnTypes: Array(repeating: ColumnType.decimal(rawType: nil), count: 4)
        )

        let result = converter.generateJson(rows: [[
            "+12345678901234567890.12345",
            ".123456789012345678901234567890",
            "9.",
            "007.5000",
        ]])

        #expect(result == """
        [
          {
            "leadingPlus": 12345678901234567890.12345,
            "leadingPoint": 0.123456789012345678901234567890,
            "trailingPoint": 9,
            "paddedScale": 7.5000
          }
        ]
        """)
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
        let result = converter.generateJson(rows: [[.text(jsonValue)]])
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
        let rows = Array(repeating: [PluginCellValue.text(marker)], count: 50_001)
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

    @Test("Binary cell produces base64 encoded value regardless of column type")
    func binaryCellProducesBase64() {
        let converter = makeConverter(columns: ["data"], columnTypes: [.blob(rawType: nil)])
        let bytes = Data("hello".utf8)
        let result = converter.generateJson(rows: [[.bytes(bytes)]])
        #expect(result.contains("\"aGVsbG8=\""))
    }

    @Test("Issue #1188 binary cell base64-encodes correctly")
    func issue1188BinaryCellBase64() {
        let converter = makeConverter(columns: ["payload"], columnTypes: [.blob(rawType: "BYTEA")])
        let bytes = Data([0xD3, 0x8C, 0xE5, 0x66])
        let result = converter.generateJson(rows: [[.bytes(bytes)]])
        let expected = bytes.base64EncodedString()
        #expect(result.contains("\"\(expected)\""))
        #expect(!result.contains("null"))
    }

    // MARK: - Default-value marker

    /// A pending inserted row carries the default marker for columns the server fills in. The grid
    /// draws it as a placeholder, so JSON has to agree instead of printing the internal token.
    @Test("The default-value marker renders as null, not as literal text")
    func defaultMarkerRendersAsNull() {
        let converter = makeConverter(
            columns: ["id", "name"],
            columnTypes: [.integer(rawType: nil), .text(rawType: nil)]
        )
        let result = converter.generateJson(
            rows: [[.text(PluginCellValue.defaultMarkerText), .text("Ada")]]
        )

        #expect(!result.contains(PluginCellValue.defaultMarkerText))
        #expect(result.contains("\"id\": null"))
        #expect(result.contains("\"Ada\""))
    }

    @Test("A value that merely resembles the marker is untouched")
    func markerLookalikeIsPreserved() {
        let converter = makeConverter(columns: ["name"], columnTypes: [.text(rawType: nil)])
        let result = converter.generateJson(rows: [[.text("__DEFAULT")]])

        #expect(result.contains("\"__DEFAULT\""))
    }
}
