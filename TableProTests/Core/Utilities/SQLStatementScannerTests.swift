//
//  SQLStatementScannerTests.swift
//  TableProTests
//

@testable import TablePro
import TableProPluginKit
import XCTest

final class SQLStatementScannerTests: XCTestCase {
    // MARK: - allStatements

    func testEmptyInput() {
        XCTAssertEqual(SQLStatementScanner.allStatements(in: ""), [])
    }

    func testSingleStatement() {
        XCTAssertEqual(
            SQLStatementScanner.allStatements(in: "SELECT 1"),
            ["SELECT 1"]
        )
    }

    func testSingleStatementWithTrailingSemicolon() {
        XCTAssertEqual(
            SQLStatementScanner.allStatements(in: "SELECT 1;"),
            ["SELECT 1"]
        )
    }

    func testMultipleStatements() {
        let sql = "SELECT 1; SELECT 2; SELECT 3"
        XCTAssertEqual(
            SQLStatementScanner.allStatements(in: sql),
            ["SELECT 1", "SELECT 2", "SELECT 3"]
        )
    }

    func testSemicolonInsideSingleQuotes() {
        let sql = "SELECT 'a;b'; SELECT 2"
        XCTAssertEqual(
            SQLStatementScanner.allStatements(in: sql),
            ["SELECT 'a;b'", "SELECT 2"]
        )
    }

    func testSemicolonInsideDoubleQuotes() {
        let sql = "SELECT \"a;b\"; SELECT 2"
        XCTAssertEqual(
            SQLStatementScanner.allStatements(in: sql),
            ["SELECT \"a;b\"", "SELECT 2"]
        )
    }

    func testSemicolonInsideBackticks() {
        let sql = "SELECT `a;b`; SELECT 2"
        XCTAssertEqual(
            SQLStatementScanner.allStatements(in: sql),
            ["SELECT `a;b`", "SELECT 2"]
        )
    }

    func testSemicolonInsideLineComment() {
        let sql = "SELECT 1 -- comment; still comment\n; SELECT 2"
        XCTAssertEqual(
            SQLStatementScanner.allStatements(in: sql),
            ["SELECT 1 -- comment; still comment", "SELECT 2"]
        )
    }

    func testSemicolonInsideBlockComment() {
        let sql = "SELECT 1 /* comment; */ ; SELECT 2"
        XCTAssertEqual(
            SQLStatementScanner.allStatements(in: sql),
            ["SELECT 1 /* comment; */", "SELECT 2"]
        )
    }

    func testBackslashEscape() {
        let sql = "SELECT 'it\\'s'; SELECT 2"
        XCTAssertEqual(
            SQLStatementScanner.allStatements(in: sql),
            ["SELECT 'it\\'s'", "SELECT 2"]
        )
    }

    func testDoubledQuoteEscape() {
        let sql = "SELECT 'it''s'; SELECT 2"
        XCTAssertEqual(
            SQLStatementScanner.allStatements(in: sql),
            ["SELECT 'it''s'", "SELECT 2"]
        )
    }

    func testWhitespaceOnlyStatements() {
        let sql = "SELECT 1;   ;  \n ; SELECT 2"
        XCTAssertEqual(
            SQLStatementScanner.allStatements(in: sql),
            ["SELECT 1", "SELECT 2"]
        )
    }

    func testNestedBlockComment() {
        // SQL block comments don't nest — first */ closes
        let sql = "SELECT 1 /* outer /* inner */ ; SELECT 2"
        XCTAssertEqual(
            SQLStatementScanner.allStatements(in: sql),
            ["SELECT 1 /* outer /* inner */", "SELECT 2"]
        )
    }

    // MARK: - Dollar Quoting (PostgreSQL)

    func testDollarQuotedDoBlockKeepsInternalSemicolons() {
        let sql = "DO $$ BEGIN PERFORM 1; PERFORM 2; END $$; SELECT 1;"
        XCTAssertEqual(
            SQLStatementScanner.allStatements(in: sql, dialect: .postgres),
            ["DO $$ BEGIN PERFORM 1; PERFORM 2; END $$", "SELECT 1"]
        )
    }

    func testTaggedDollarQuoteKeepsInternalSemicolons() {
        let sql = "CREATE FUNCTION f() RETURNS int AS $body$ BEGIN RETURN 1; END $body$ LANGUAGE plpgsql; SELECT f();"
        XCTAssertEqual(
            SQLStatementScanner.allStatements(in: sql, dialect: .postgres),
            [
                "CREATE FUNCTION f() RETURNS int AS $body$ BEGIN RETURN 1; END $body$ LANGUAGE plpgsql",
                "SELECT f()"
            ]
        )
    }

    func testNestedDifferentDollarTags() {
        let sql = "DO $outer$ SELECT $inner$ a;b $inner$; END $outer$; SELECT 1;"
        XCTAssertEqual(
            SQLStatementScanner.allStatements(in: sql, dialect: .postgres),
            ["DO $outer$ SELECT $inner$ a;b $inner$; END $outer$", "SELECT 1"]
        )
    }

    func testPositionalParameterIsNotDollarQuote() {
        let sql = "SELECT $1; SELECT $2;"
        XCTAssertEqual(
            SQLStatementScanner.allStatements(in: sql, dialect: .postgres),
            ["SELECT $1", "SELECT $2"]
        )
    }

    func testDollarPairInsideIdentifierIsNotOpener() {
        let sql = "SELECT 1 AS a$$; SELECT 2;"
        XCTAssertEqual(
            SQLStatementScanner.allStatements(in: sql, dialect: .postgres),
            ["SELECT 1 AS a$$", "SELECT 2"]
        )
    }

    func testGenericDialectIgnoresDollarQuotes() {
        let sql = "DO $$ SELECT 1; SELECT 2 $$;"
        XCTAssertEqual(
            SQLStatementScanner.allStatements(in: sql, dialect: .generic),
            ["DO $$ SELECT 1", "SELECT 2 $$"]
        )
    }

    func testCursorInsideDollarBodyReturnsWholeStatement() {
        let sql = "DO $$ BEGIN PERFORM 1; END $$; SELECT 1;"
        XCTAssertEqual(
            SQLStatementScanner.statementAtCursor(in: sql, cursorPosition: 20, dialect: .postgres),
            "DO $$ BEGIN PERFORM 1; END $$"
        )
    }

    // MARK: - allStatementsPreservingSemicolons

    func testPreservingSemicolons() {
        let sql = "SELECT 1; SELECT 2; SELECT 3"
        XCTAssertEqual(
            SQLStatementScanner.allStatementsPreservingSemicolons(in: sql),
            ["SELECT 1;", "SELECT 2;", "SELECT 3"]
        )
    }

    func testPreservingSemicolonsFiltersEmpty() {
        let sql = "SELECT 1;   ;  \n ; SELECT 2"
        XCTAssertEqual(
            SQLStatementScanner.allStatementsPreservingSemicolons(in: sql),
            ["SELECT 1;", "SELECT 2"]
        )
    }

    // MARK: - statementAtCursor

    func testCursorInFirstStatement() {
        let sql = "SELECT 1; SELECT 2"
        XCTAssertEqual(
            SQLStatementScanner.statementAtCursor(in: sql, cursorPosition: 3),
            "SELECT 1"
        )
    }

    func testCursorInSecondStatement() {
        let sql = "SELECT 1; SELECT 2"
        XCTAssertEqual(
            SQLStatementScanner.statementAtCursor(in: sql, cursorPosition: 10),
            "SELECT 2"
        )
    }

    func testCursorInLastStatementNoSemicolon() {
        let sql = "SELECT 1; SELECT 2"
        XCTAssertEqual(
            SQLStatementScanner.statementAtCursor(in: sql, cursorPosition: 15),
            "SELECT 2"
        )
    }

    func testCursorAtSemicolon() {
        let sql = "SELECT 1; SELECT 2"
        XCTAssertEqual(
            SQLStatementScanner.statementAtCursor(in: sql, cursorPosition: 8),
            "SELECT 1"
        )
    }

    func testCursorAtZero() {
        let sql = "SELECT 1; SELECT 2"
        XCTAssertEqual(
            SQLStatementScanner.statementAtCursor(in: sql, cursorPosition: 0),
            "SELECT 1"
        )
    }

    func testCursorBeyondEnd() {
        let sql = "SELECT 1; SELECT 2"
        XCTAssertEqual(
            SQLStatementScanner.statementAtCursor(in: sql, cursorPosition: 999),
            "SELECT 2"
        )
    }

    func testNoSemicolonsFastPath() {
        let sql = "SELECT * FROM users"
        XCTAssertEqual(
            SQLStatementScanner.statementAtCursor(in: sql, cursorPosition: 5),
            "SELECT * FROM users"
        )
    }

    // MARK: - locatedStatementAtCursor

    func testLocatedStatementOffset() {
        let sql = "SELECT 1; SELECT 2"
        let located = SQLStatementScanner.locatedStatementAtCursor(in: sql, cursorPosition: 3)
        XCTAssertEqual(located.sql, "SELECT 1;")
        XCTAssertEqual(located.offset, 0)
    }

    func testLocatedStatementOffsetSecondStatement() {
        let sql = "SELECT 1; SELECT 2"
        let located = SQLStatementScanner.locatedStatementAtCursor(in: sql, cursorPosition: 12)
        XCTAssertEqual(located.sql, " SELECT 2")
        XCTAssertEqual(located.offset, 9)
    }
}
