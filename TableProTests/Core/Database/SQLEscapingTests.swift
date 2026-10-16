//
//  SQLEscapingTests.swift
//  TableProTests
//
//  Tests for SQLEscaping utility functions
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

struct SQLEscapingTests {

    // MARK: - escapeStringLiteral Tests (ANSI SQL)

    @Test("Plain string unchanged")
    func testPlainStringUnchanged() {
        let input = "Hello World"
        let result = SQLEscaping.escapeStringLiteral(input)
        #expect(result == "Hello World")
    }

    @Test("Single quotes doubled")
    func testSingleQuotesDoubled() {
        let input = "O'Brien"
        let result = SQLEscaping.escapeStringLiteral(input)
        #expect(result == "O''Brien")
    }

    @Test("Backslashes preserved")
    func testBackslashesPreserved() {
        let input = "C:\\Users\\Test"
        let result = SQLEscaping.escapeStringLiteral(input)
        #expect(result == "C:\\Users\\Test")
    }

    @Test("Newlines preserved")
    func testNewlinesPreserved() {
        let input = "Line1\nLine2"
        let result = SQLEscaping.escapeStringLiteral(input)
        #expect(result == "Line1\nLine2")
    }

    @Test("Carriage returns preserved")
    func testCarriageReturnsPreserved() {
        let input = "Text\rMore"
        let result = SQLEscaping.escapeStringLiteral(input)
        #expect(result == "Text\rMore")
    }

    @Test("Tabs preserved")
    func testTabsPreserved() {
        let input = "Col1\tCol2"
        let result = SQLEscaping.escapeStringLiteral(input)
        #expect(result == "Col1\tCol2")
    }

    @Test("Null bytes stripped")
    func testNullBytesStripped() {
        let input = "Text\0End"
        let result = SQLEscaping.escapeStringLiteral(input)
        #expect(result == "TextEnd")
    }

    @Test("Backspace preserved")
    func testBackspacePreserved() {
        let input = "Text\u{08}End"
        let result = SQLEscaping.escapeStringLiteral(input)
        #expect(result == "Text\u{08}End")
    }

    @Test("Form feed preserved")
    func testFormFeedPreserved() {
        let input = "Text\u{0C}End"
        let result = SQLEscaping.escapeStringLiteral(input)
        #expect(result == "Text\u{0C}End")
    }

    @Test("EOF marker preserved")
    func testEOFMarkerPreserved() {
        let input = "Text\u{1A}End"
        let result = SQLEscaping.escapeStringLiteral(input)
        #expect(result == "Text\u{1A}End")
    }

    @Test("Combined special characters — ANSI escaping")
    func testCombinedSpecialCharacters() {
        let input = "O'Brien\\test\nline2\t\0end"
        let result = SQLEscaping.escapeStringLiteral(input)
        #expect(result == "O''Brien\\test\nline2\tend")
    }

    @Test("Empty string unchanged")
    func testEmptyStringUnchanged() {
        let input = ""
        let result = SQLEscaping.escapeStringLiteral(input)
        #expect(result == "")
    }

    @Test("Backslash and quote — ANSI escaping")
    func testBackslashQuoteEscapingOrder() {
        let input = "\\'"
        let result = SQLEscaping.escapeStringLiteral(input)
        #expect(result == "\\''")
    }

    // MARK: - quoteIdentifier Tests (ANSI SQL)

    @Test("Plain identifier wrapped in double quotes")
    func testQuoteIdentifierPlain() {
        #expect(SQLEscaping.quoteIdentifier("users") == "\"users\"")
    }

    @Test("Embedded double quote is doubled")
    func testQuoteIdentifierEmbeddedQuote() {
        #expect(SQLEscaping.quoteIdentifier("we\"ird") == "\"we\"\"ird\"")
    }

    @Test("Empty identifier yields empty quotes")
    func testQuoteIdentifierEmpty() {
        #expect(SQLEscaping.quoteIdentifier("") == "\"\"")
    }

    // MARK: - escapeLikeWildcards Tests

    @Test("LIKE plain string unchanged")
    func testLikePlainStringUnchanged() {
        let input = "test"
        let result = SQLEscaping.escapeLikeWildcards(input)
        #expect(result == "test")
    }

    @Test("LIKE percent escaped")
    func testLikePercentEscaped() {
        let input = "test%value"
        let result = SQLEscaping.escapeLikeWildcards(input)
        #expect(result == "test\\%value")
    }

    @Test("LIKE underscore escaped")
    func testLikeUnderscoreEscaped() {
        let input = "test_value"
        let result = SQLEscaping.escapeLikeWildcards(input)
        #expect(result == "test\\_value")
    }

    @Test("LIKE backslash escaped")
    func testLikeBackslashEscaped() {
        let input = "test\\value"
        let result = SQLEscaping.escapeLikeWildcards(input)
        #expect(result == "test\\\\value")
    }

    @Test("LIKE combined wildcards")
    func testLikeCombinedWildcards() {
        let input = "test%value_123\\end"
        let result = SQLEscaping.escapeLikeWildcards(input)
        #expect(result == "test\\%value\\_123\\\\end")
    }

    @Test("LIKE empty string unchanged")
    func testLikeEmptyStringUnchanged() {
        let input = ""
        let result = SQLEscaping.escapeLikeWildcards(input)
        #expect(result == "")
    }

    @Test("LIKE backslash and percent order prevents double-escaping")
    func testLikeBackslashPercentEscapingOrder() {
        let input = "\\%"
        let result = SQLEscaping.escapeLikeWildcards(input)
        #expect(result == "\\\\\\%")
    }
}
