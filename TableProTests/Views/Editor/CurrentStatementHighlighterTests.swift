//
//  CurrentStatementHighlighterTests.swift
//  TableProTests
//
//  Tests for the current statement highlighting feature.
//  Since CurrentStatementHighlighter depends on TextViewController (CESS),
//  we test the core logic indirectly through SQLStatementScanner which
//  powers the highlighting, plus verify threshold constants.
//

import Foundation
import Testing
@testable import TablePro

@Suite("Current Statement Highlighter Logic")
struct CurrentStatementHighlighterTests {

    // MARK: - Multi-statement cursor detection

    @Test("Cursor at beginning of first statement returns first statement")
    func cursorAtBeginningOfFirstStatement() {
        let sql = "SELECT 1; SELECT 2; SELECT 3"
        let located = SQLStatementScanner.locatedStatementAtCursor(in: sql, cursorPosition: 0)
        #expect(located.offset == 0)
        #expect(located.sql == "SELECT 1;")
    }

    @Test("Cursor in middle of second statement returns second statement")
    func cursorInMiddleOfSecondStatement() {
        let sql = "SELECT 1; SELECT 2; SELECT 3"
        // Position 13 is inside " SELECT 2"
        let located = SQLStatementScanner.locatedStatementAtCursor(in: sql, cursorPosition: 13)
        #expect(located.offset == 9)
        #expect(located.sql == " SELECT 2;")
    }

    @Test("Cursor at end of last statement returns last statement")
    func cursorAtEndOfLastStatement() {
        let sql = "SELECT 1; SELECT 2; SELECT 3"
        let located = SQLStatementScanner.locatedStatementAtCursor(
            in: sql,
            cursorPosition: (sql as NSString).length
        )
        #expect(located.offset == 19)
        #expect(located.sql == " SELECT 3")
    }

    @Test("Cursor after final semicolon returns trailing content")
    func cursorAfterFinalSemicolon() {
        let sql = "SELECT 1; SELECT 2;\n"
        let located = SQLStatementScanner.locatedStatementAtCursor(
            in: sql,
            cursorPosition: 20
        )
        // After the last semicolon, the remaining text is "\n"
        #expect(located.offset == 19)
        #expect(located.sql == "\n")
    }

    @Test("Single statement without semicolon returns entire text via fast path")
    func singleStatementNoSemicolon() {
        let sql = "SELECT * FROM users"
        let located = SQLStatementScanner.locatedStatementAtCursor(in: sql, cursorPosition: 5)
        // The scanner's fast path returns the whole string when no semicolons
        #expect(located.sql == sql)
        #expect(located.offset == 0)
    }

    @Test("Empty string returns empty located statement")
    func emptyString() {
        let located = SQLStatementScanner.locatedStatementAtCursor(in: "", cursorPosition: 0)
        #expect(located.sql == "")
        #expect(located.offset == 0)
    }

    // MARK: - Strings containing semicolons

    @Test("Semicolons inside single-quoted strings do not split statements")
    func semicolonInSingleQuotedString() {
        let sql = "SELECT 'a;b'; SELECT 2"
        let located = SQLStatementScanner.locatedStatementAtCursor(in: sql, cursorPosition: 5)
        #expect(located.sql == "SELECT 'a;b';")
        #expect(located.offset == 0)
    }

    @Test("Semicolons inside double-quoted strings do not split statements")
    func semicolonInDoubleQuotedString() {
        let sql = "SELECT \"a;b\"; SELECT 2"
        let located = SQLStatementScanner.locatedStatementAtCursor(in: sql, cursorPosition: 5)
        #expect(located.sql == "SELECT \"a;b\";")
        #expect(located.offset == 0)
    }

    // MARK: - Comments containing semicolons

    @Test("Semicolons inside line comments do not split statements")
    func semicolonInLineComment() {
        let sql = "SELECT 1 -- comment; not a split\n; SELECT 2"
        let located = SQLStatementScanner.locatedStatementAtCursor(in: sql, cursorPosition: 0)
        #expect(located.sql == "SELECT 1 -- comment; not a split\n;")
        #expect(located.offset == 0)
    }

    @Test("Semicolons inside block comments do not split statements")
    func semicolonInBlockComment() {
        let sql = "SELECT 1 /* ; */ ; SELECT 2"
        let located = SQLStatementScanner.locatedStatementAtCursor(in: sql, cursorPosition: 0)
        #expect(located.sql == "SELECT 1 /* ; */ ;")
        #expect(located.offset == 0)
    }
}
