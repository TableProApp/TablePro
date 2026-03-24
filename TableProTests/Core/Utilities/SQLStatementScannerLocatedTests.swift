//
//  SQLStatementScannerLocatedTests.swift
//  TableProTests
//
//  Focused tests on locatedStatementAtCursor, the key function
//  powering the current statement highlighter.
//

import Foundation
import Testing
@testable import TablePro

@Suite("SQL Statement Scanner — locatedStatementAtCursor")
struct SQLStatementScannerLocatedTests {

    // MARK: - Offset correctness

    @Test("Returns correct offset for each statement in multi-statement string")
    func correctOffsetsForMultipleStatements() {
        let sql = "SELECT 1; UPDATE t SET x=1; DELETE FROM t"
        //         0123456789...

        let first = SQLStatementScanner.locatedStatementAtCursor(in: sql, cursorPosition: 0)
        #expect(first.offset == 0)
        #expect(first.sql == "SELECT 1;")

        let second = SQLStatementScanner.locatedStatementAtCursor(in: sql, cursorPosition: 12)
        #expect(second.offset == 9)
        #expect(second.sql == " UPDATE t SET x=1;")

        let third = SQLStatementScanner.locatedStatementAtCursor(in: sql, cursorPosition: 30)
        #expect(third.offset == 27)
        #expect(third.sql == " DELETE FROM t")
    }

    @Test("offset + sql.count covers the full statement range")
    func offsetPlusSqlLengthCoversRange() {
        let sql = "INSERT INTO t VALUES(1); SELECT * FROM t; DROP TABLE t"

        let first = SQLStatementScanner.locatedStatementAtCursor(in: sql, cursorPosition: 5)
        let firstEnd = first.offset + (first.sql as NSString).length
        #expect(firstEnd == 24) // "INSERT INTO t VALUES(1);" is 24 chars

        let second = SQLStatementScanner.locatedStatementAtCursor(in: sql, cursorPosition: 30)
        let secondEnd = second.offset + (second.sql as NSString).length
        #expect(secondEnd == 41) // up to and including the second semicolon

        let third = SQLStatementScanner.locatedStatementAtCursor(in: sql, cursorPosition: 50)
        let thirdEnd = third.offset + (third.sql as NSString).length
        #expect(thirdEnd == (sql as NSString).length)
    }

    // MARK: - Leading whitespace handling

    @Test("Offset accounts for leading whitespace between statements")
    func leadingWhitespaceIncludedInOffset() {
        let sql = "SELECT 1;   SELECT 2"
        //                   ^ offset 9, then "   SELECT 2" starts at 9
        let located = SQLStatementScanner.locatedStatementAtCursor(in: sql, cursorPosition: 15)
        #expect(located.offset == 9)
        // The raw SQL includes the leading spaces
        #expect(located.sql.hasPrefix(" "))
    }

    @Test("Offset accounts for newlines between statements")
    func newlinesBetweenStatements() {
        let sql = "SELECT 1;\n\nSELECT 2"
        let located = SQLStatementScanner.locatedStatementAtCursor(in: sql, cursorPosition: 15)
        #expect(located.offset == 9)
        #expect(located.sql == "\n\nSELECT 2")
    }

    // MARK: - Trailing whitespace handling

    @Test("Trailing whitespace before semicolon is included in statement")
    func trailingWhitespaceBeforeSemicolon() {
        let sql = "SELECT 1   ; SELECT 2"
        let located = SQLStatementScanner.locatedStatementAtCursor(in: sql, cursorPosition: 5)
        #expect(located.sql == "SELECT 1   ;")
    }

    // MARK: - Comment styles

    @Test("Works with line comments containing semicolons")
    func lineCommentWithSemicolon() {
        let sql = "SELECT 1 -- drop; table\n; SELECT 2"
        let first = SQLStatementScanner.locatedStatementAtCursor(in: sql, cursorPosition: 0)
        // The semicolon in the comment is not a delimiter
        #expect(first.sql == "SELECT 1 -- drop; table\n;")
        #expect(first.offset == 0)
    }

    @Test("Works with block comments containing semicolons")
    func blockCommentWithSemicolon() {
        let sql = "SELECT /* ; */ 1; SELECT 2"
        let first = SQLStatementScanner.locatedStatementAtCursor(in: sql, cursorPosition: 0)
        #expect(first.sql == "SELECT /* ; */ 1;")
        #expect(first.offset == 0)
    }

    @Test("Works with mixed comment styles")
    func mixedComments() {
        // Semicolons inside comments are ignored; real delimiter is at pos 31
        let sql = "SELECT 1 /* block; */ -- line;\n; SELECT 2"
        let first = SQLStatementScanner.locatedStatementAtCursor(in: sql, cursorPosition: 0)
        #expect(first.offset == 0)
        #expect(first.sql.contains("SELECT 1"))

        let second = SQLStatementScanner.locatedStatementAtCursor(in: sql, cursorPosition: 38)
        #expect(second.sql.contains("SELECT 2"))
    }

    // MARK: - Backtick-quoted identifiers

    @Test("Backtick-quoted identifiers containing semicolons do not split")
    func backtickWithSemicolon() {
        let sql = "SELECT `col;name`; SELECT 2"
        let first = SQLStatementScanner.locatedStatementAtCursor(in: sql, cursorPosition: 5)
        #expect(first.sql == "SELECT `col;name`;")
        #expect(first.offset == 0)
    }

    // MARK: - Edge cases

    @Test("Cursor at exact semicolon position belongs to current statement")
    func cursorAtSemicolon() {
        let sql = "SELECT 1; SELECT 2"
        // Position 8 is the semicolon character
        let located = SQLStatementScanner.locatedStatementAtCursor(in: sql, cursorPosition: 8)
        #expect(located.offset == 0)
        #expect(located.sql == "SELECT 1;")
    }

    @Test("Cursor beyond end of string is clamped")
    func cursorBeyondEnd() {
        let sql = "SELECT 1; SELECT 2"
        let located = SQLStatementScanner.locatedStatementAtCursor(in: sql, cursorPosition: 9999)
        #expect(located.offset == 9)
        #expect(located.sql == " SELECT 2")
    }

    @Test("Handles very large input without crashing")
    func largeInput() {
        var parts: [String] = []
        for i in 0..<200 {
            parts.append("SELECT \(i) FROM very_long_table_name_for_testing;")
        }
        let sql = parts.joined(separator: " ")
        let nsSQL = sql as NSString
        #expect(nsSQL.length > 10_000)

        let midpoint = nsSQL.length / 2
        let located = SQLStatementScanner.locatedStatementAtCursor(in: sql, cursorPosition: midpoint)
        #expect(!located.sql.isEmpty)
        #expect(located.offset >= 0)
        #expect(located.offset < nsSQL.length)
    }

    @Test("Multiple consecutive semicolons produce empty-ish segments")
    func consecutiveSemicolons() {
        let sql = "SELECT 1;;; SELECT 2"
        let first = SQLStatementScanner.locatedStatementAtCursor(in: sql, cursorPosition: 0)
        #expect(first.sql == "SELECT 1;")
        #expect(first.offset == 0)
    }

    @Test("Escaped quote inside string does not break parsing")
    func escapedQuoteInString() {
        let sql = "SELECT 'it\\'s here'; SELECT 2"
        let first = SQLStatementScanner.locatedStatementAtCursor(in: sql, cursorPosition: 0)
        #expect(first.sql == "SELECT 'it\\'s here';")
        #expect(first.offset == 0)
    }

    @Test("Doubled quote escape inside string does not break parsing")
    func doubledQuoteInString() {
        let sql = "SELECT 'it''s here'; SELECT 2"
        let first = SQLStatementScanner.locatedStatementAtCursor(in: sql, cursorPosition: 0)
        #expect(first.sql == "SELECT 'it''s here';")
        #expect(first.offset == 0)
    }
}
