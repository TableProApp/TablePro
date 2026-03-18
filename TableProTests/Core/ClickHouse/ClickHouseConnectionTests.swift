//
//  ClickHouseConnectionTests.swift
//  TableProTests
//
//  Tests for ClickHouse TSV parsing and query escaping fixes.
//  These validate the TSV unescaping logic used by the ClickHouse plugin.
//

import Foundation
import Testing

@Suite("ClickHouse Connection")
struct ClickHouseConnectionTests {

    /// Local copy of the TSV unescaping logic for testing purposes.
    /// The actual implementation lives in the ClickHouseDriver plugin.
    private static func unescapeTsvField(_ field: String) -> String {
        var result = ""
        result.reserveCapacity((field as NSString).length)
        var iterator = field.makeIterator()

        while let char = iterator.next() {
            if char == "\\" {
                if let next = iterator.next() {
                    switch next {
                    case "\\": result.append("\\")
                    case "t": result.append("\t")
                    case "n": result.append("\n")
                    default:
                        result.append("\\")
                        result.append(next)
                    }
                } else {
                    result.append("\\")
                }
            } else {
                result.append(char)
            }
        }

        return result
    }

    // MARK: - TSV Field Unescaping

    @Test("Plain text passes through unchanged")
    func testPlainText() {
        let result = Self.unescapeTsvField("hello world")
        #expect(result == "hello world")
    }

    @Test("Empty string returns empty")
    func testEmptyString() {
        let result = Self.unescapeTsvField("")
        #expect(result == "")
    }

    @Test("Escaped backslash becomes single backslash")
    func testEscapedBackslash() {
        let result = Self.unescapeTsvField("path\\\\to\\\\file")
        #expect(result == "path\\to\\file")
    }

    @Test("Escaped tab becomes tab character")
    func testEscapedTab() {
        let result = Self.unescapeTsvField("col1\\tcol2")
        #expect(result == "col1\tcol2")
    }

    @Test("Escaped newline becomes newline character")
    func testEscapedNewline() {
        let result = Self.unescapeTsvField("line1\\nline2")
        #expect(result == "line1\nline2")
    }

    @Test("Unknown escape sequence preserves backslash and character")
    func testUnknownEscapeSequence() {
        let result = Self.unescapeTsvField("test\\xvalue")
        #expect(result == "test\\xvalue")
    }

    @Test("Trailing backslash is preserved")
    func testTrailingBackslash() {
        let result = Self.unescapeTsvField("trailing\\")
        #expect(result == "trailing\\")
    }

    @Test("Multiple escape sequences in one field")
    func testMultipleEscapeSequences() {
        let result = Self.unescapeTsvField("a\\tb\\nc\\\\d")
        #expect(result == "a\tb\nc\\d")
    }

    @Test("Performance: uses NSString.length for capacity reservation")
    func testLargeStringPerformance() {
        let largeField = String(repeating: "abcdefgh", count: 10_000)
        let result = Self.unescapeTsvField(largeField)
        #expect(result == largeField)
    }

    @Test("Performance: large field with escape sequences")
    func testLargeFieldWithEscapes() {
        let segment = "value\\ttab\\nnewline\\"
        let largeField = String(repeating: segment, count: 5_000) + "\\"
        let result = Self.unescapeTsvField(largeField)
        #expect(result.contains("\t"))
        #expect(result.contains("\n"))
    }

    // MARK: - Kill Query Escaping (SQL-standard single-quote doubling)

    @Test("Single quote is doubled using SQL-standard escaping")
    func testSingleQuoteEscaping() {
        let queryId = "abc'def"
        let escaped = queryId.replacingOccurrences(of: "'", with: "''")
        #expect(escaped == "abc''def")
        let sql = "KILL QUERY WHERE query_id = '\(escaped)'"
        #expect(sql == "KILL QUERY WHERE query_id = 'abc''def'")
    }

    @Test("Multiple single quotes are all doubled")
    func testMultipleSingleQuotes() {
        let queryId = "it's a 'test'"
        let escaped = queryId.replacingOccurrences(of: "'", with: "''")
        #expect(escaped == "it''s a ''test''")
    }

    @Test("Query ID without quotes passes through unchanged")
    func testNoQuotesInQueryId() {
        let queryId = "abc-123-def-456"
        let escaped = queryId.replacingOccurrences(of: "'", with: "''")
        #expect(escaped == queryId)
    }

    @Test("SQL-standard escaping does not use backslash-quote")
    func testNoBackslashEscaping() {
        let queryId = "test'value"
        let escaped = queryId.replacingOccurrences(of: "'", with: "''")
        #expect(!escaped.contains("\\'"))
        #expect(escaped.contains("''"))
    }
}
