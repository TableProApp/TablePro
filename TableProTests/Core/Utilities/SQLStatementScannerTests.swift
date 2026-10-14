//
//  SQLStatementScannerTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSQLGrammar
import Testing

struct SQLStatementScannerTests {
    // MARK: - allStatements

    @Test
    func emptyInput() {
        #expect(SQLStatementScanner.allStatements(in: "") == [])
    }

    @Test
    func singleStatement() {
        #expect(SQLStatementScanner.allStatements(in: "SELECT 1") == ["SELECT 1"])
    }

    @Test
    func singleStatementWithTrailingSemicolon() {
        #expect(SQLStatementScanner.allStatements(in: "SELECT 1;") == ["SELECT 1"])
    }

    @Test
    func multipleStatements() {
        let sql = "SELECT 1; SELECT 2; SELECT 3"
        #expect(SQLStatementScanner.allStatements(in: sql) == ["SELECT 1", "SELECT 2", "SELECT 3"])
    }

    @Test
    func semicolonInsideSingleQuotes() {
        let sql = "SELECT 'a;b'; SELECT 2"
        #expect(SQLStatementScanner.allStatements(in: sql) == ["SELECT 'a;b'", "SELECT 2"])
    }

    @Test
    func semicolonInsideDoubleQuotes() {
        let sql = "SELECT \"a;b\"; SELECT 2"
        #expect(SQLStatementScanner.allStatements(in: sql) == ["SELECT \"a;b\"", "SELECT 2"])
    }

    @Test
    func semicolonInsideBackticks() {
        let sql = "SELECT `a;b`; SELECT 2"
        #expect(SQLStatementScanner.allStatements(in: sql, grammar: TestGrammar.mysql) == ["SELECT `a;b`", "SELECT 2"])
    }

    @Test
    func semicolonInsideLineComment() {
        let sql = "SELECT 1 -- comment; still comment\n; SELECT 2"
        #expect(SQLStatementScanner.allStatements(in: sql) == ["SELECT 1 -- comment; still comment", "SELECT 2"])
    }

    @Test
    func semicolonInsideBlockComment() {
        let sql = "SELECT 1 /* comment; */ ; SELECT 2"
        #expect(SQLStatementScanner.allStatements(in: sql) == ["SELECT 1 /* comment; */", "SELECT 2"])
    }

    @Test
    func backslashEscape() {
        let sql = "SELECT 'it\\'s'; SELECT 2"
        #expect(SQLStatementScanner.allStatements(in: sql, grammar: TestGrammar.mysql) == ["SELECT 'it\\'s'", "SELECT 2"])
    }

    @Test
    func doubledQuoteEscape() {
        let sql = "SELECT 'it''s'; SELECT 2"
        #expect(SQLStatementScanner.allStatements(in: sql) == ["SELECT 'it''s'", "SELECT 2"])
    }

    @Test
    func whitespaceOnlyStatements() {
        let sql = "SELECT 1;   ;  \n ; SELECT 2"
        #expect(SQLStatementScanner.allStatements(in: sql) == ["SELECT 1", "SELECT 2"])
    }

    @Test
    func nestedBlockComment() {
        // SQL block comments don't nest — first */ closes
        let sql = "SELECT 1 /* outer /* inner */ ; SELECT 2"
        #expect(SQLStatementScanner.allStatements(in: sql) == ["SELECT 1 /* outer /* inner */", "SELECT 2"])
    }

    // MARK: - Comment-Only Segments

    @Test
    func trailingLineCommentAfterSemicolonIsDropped() {
        #expect(SQLStatementScanner.allStatements(in: "SELECT 1; -- note") == ["SELECT 1"])
    }

    @Test
    func trailingBlockCommentAfterSemicolonIsDropped() {
        #expect(SQLStatementScanner.allStatements(in: "SELECT 1; /* note */") == ["SELECT 1"])
    }

    @Test
    func middleCommentOnlySegmentIsDropped() {
        #expect(SQLStatementScanner.allStatements(in: "SELECT 1; /* x */; SELECT 2") == ["SELECT 1", "SELECT 2"])
    }

    @Test
    func commentOnlyWholeInputReturnsNoStatements() {
        #expect(SQLStatementScanner.allStatements(in: "-- note") == [])
        #expect(SQLStatementScanner.allStatements(in: "/* note */") == [])
    }

    @Test
    func mixedCommentAndWhitespaceMultilineSegmentIsDropped() {
        let sql = "SELECT 1;\n  -- first\n  /* second */  \n; SELECT 2"
        #expect(SQLStatementScanner.allStatements(in: sql) == ["SELECT 1", "SELECT 2"])
    }

    @Test
    func consecutiveSemicolonsStillDropped() {
        #expect(SQLStatementScanner.allStatements(in: "SELECT 1;;") == ["SELECT 1"])
    }

    @Test
    func unclosedTrailingBlockCommentIsDropped() {
        #expect(SQLStatementScanner.allStatements(in: "SELECT 1; /* note") == ["SELECT 1"])
    }

    @Test
    func lineCommentAtEndOfInputIsDropped() {
        #expect(SQLStatementScanner.allStatements(in: "SELECT 1; --") == ["SELECT 1"])
    }

    @Test
    func mySQLVersionedCommentSegmentIsKept() {
        #expect(SQLStatementScanner.allStatements(in: "/*!40101 SET @OLD=1 */; SELECT 1", grammar: TestGrammar.mysql) == ["/*!40101 SET @OLD=1 */", "SELECT 1"])
    }

    /// `/*! */` is SQL MySQL runs and a comment everywhere else, so what it is depends on the engine.
    @Test
    func versionedCommentRunsOnMySQLAndIsACommentElsewhere() {
        #expect(SQLStatementScanner.allStatements(in: "/*!40101 SET @OLD=1 */;", grammar: TestGrammar.mysql) == ["/*!40101 SET @OLD=1 */"])
        #expect(SQLStatementScanner.allStatements(in: "/*!40101 SET @OLD=1 */;", grammar: TestGrammar.standard) == [])
    }

    @Test
    func inStatementCommentsArePreserved() {
        #expect(SQLStatementScanner.allStatements(in: "SELECT 1 -- hint\n; SELECT 2 /* keep */") == ["SELECT 1 -- hint", "SELECT 2 /* keep */"])
    }

    @Test
    func preservingSemicolonsDropsCommentOnlySegment() {
        #expect(SQLStatementScanner.allStatementsPreservingSemicolons(in: "SELECT 1; -- note") == ["SELECT 1;"])
    }

    // MARK: - Dollar Quoting (PostgreSQL)

    @Test
    func dollarQuotedDoBlockKeepsInternalSemicolons() {
        let sql = "DO $$ BEGIN PERFORM 1; PERFORM 2; END $$; SELECT 1;"
        #expect(SQLStatementScanner.allStatements(in: sql, grammar: TestGrammar.postgres) == ["DO $$ BEGIN PERFORM 1; PERFORM 2; END $$", "SELECT 1"])
    }

    @Test
    func taggedDollarQuoteKeepsInternalSemicolons() {
        let sql = "CREATE FUNCTION f() RETURNS int AS $body$ BEGIN RETURN 1; END $body$ LANGUAGE plpgsql; SELECT f();"
        #expect(SQLStatementScanner.allStatements(in: sql, grammar: TestGrammar.postgres) == [
                "CREATE FUNCTION f() RETURNS int AS $body$ BEGIN RETURN 1; END $body$ LANGUAGE plpgsql",
                "SELECT f()"
            ])
    }

    @Test
    func nestedDifferentDollarTags() {
        let sql = "DO $outer$ SELECT $inner$ a;b $inner$; END $outer$; SELECT 1;"
        #expect(SQLStatementScanner.allStatements(in: sql, grammar: TestGrammar.postgres) == ["DO $outer$ SELECT $inner$ a;b $inner$; END $outer$", "SELECT 1"])
    }

    @Test
    func positionalParameterIsNotDollarQuote() {
        let sql = "SELECT $1; SELECT $2;"
        #expect(SQLStatementScanner.allStatements(in: sql, grammar: TestGrammar.postgres) == ["SELECT $1", "SELECT $2"])
    }

    @Test
    func dollarPairInsideIdentifierIsNotOpener() {
        let sql = "SELECT 1 AS a$$; SELECT 2;"
        #expect(SQLStatementScanner.allStatements(in: sql, grammar: TestGrammar.postgres) == ["SELECT 1 AS a$$", "SELECT 2"])
    }

    @Test
    func genericDialectIgnoresDollarQuotes() {
        let sql = "DO $$ SELECT 1; SELECT 2 $$;"
        #expect(SQLStatementScanner.allStatements(in: sql, grammar: TestGrammar.standard) == ["DO $$ SELECT 1", "SELECT 2 $$"])
    }

    @Test
    func cursorInsideDollarBodyReturnsWholeStatement() {
        let sql = "DO $$ BEGIN PERFORM 1; END $$; SELECT 1;"
        #expect(SQLStatementScanner.statementAtCursor(in: sql, cursorPosition: 20, grammar: TestGrammar.postgres) == "DO $$ BEGIN PERFORM 1; END $$")
    }

    // MARK: - allStatementsPreservingSemicolons

    @Test
    func preservingSemicolons() {
        let sql = "SELECT 1; SELECT 2; SELECT 3"
        #expect(SQLStatementScanner.allStatementsPreservingSemicolons(in: sql) == ["SELECT 1;", "SELECT 2;", "SELECT 3"])
    }

    @Test
    func preservingSemicolonsFiltersEmpty() {
        let sql = "SELECT 1;   ;  \n ; SELECT 2"
        #expect(SQLStatementScanner.allStatementsPreservingSemicolons(in: sql) == ["SELECT 1;", "SELECT 2"])
    }

    // MARK: - statementAtCursor

    @Test
    func cursorInFirstStatement() {
        let sql = "SELECT 1; SELECT 2"
        #expect(SQLStatementScanner.statementAtCursor(in: sql, cursorPosition: 3) == "SELECT 1")
    }

    @Test
    func cursorInSecondStatement() {
        let sql = "SELECT 1; SELECT 2"
        #expect(SQLStatementScanner.statementAtCursor(in: sql, cursorPosition: 10) == "SELECT 2")
    }

    @Test
    func cursorInLastStatementNoSemicolon() {
        let sql = "SELECT 1; SELECT 2"
        #expect(SQLStatementScanner.statementAtCursor(in: sql, cursorPosition: 15) == "SELECT 2")
    }

    @Test
    func cursorAtSemicolon() {
        let sql = "SELECT 1; SELECT 2"
        #expect(SQLStatementScanner.statementAtCursor(in: sql, cursorPosition: 8) == "SELECT 1")
    }

    @Test
    func cursorAtZero() {
        let sql = "SELECT 1; SELECT 2"
        #expect(SQLStatementScanner.statementAtCursor(in: sql, cursorPosition: 0) == "SELECT 1")
    }

    @Test
    func cursorBeyondEnd() {
        let sql = "SELECT 1; SELECT 2"
        #expect(SQLStatementScanner.statementAtCursor(in: sql, cursorPosition: 999) == "SELECT 2")
    }

    @Test
    func noSemicolonsWholeInputIsOneStatement() {
        let sql = "SELECT * FROM users"
        #expect(SQLStatementScanner.statementAtCursor(in: sql, cursorPosition: 5) == "SELECT * FROM users")
    }

    // MARK: - locatedStatementAtCursor

    @Test
    func locatedStatementOffset() {
        let sql = "SELECT 1; SELECT 2"
        let located = SQLStatementScanner.locatedStatementAtCursor(in: sql, cursorPosition: 3)
        #expect(located.sql == "SELECT 1;")
        #expect(located.offset == 0)
    }

    @Test
    func locatedStatementOffsetSecondStatement() {
        let sql = "SELECT 1; SELECT 2"
        let located = SQLStatementScanner.locatedStatementAtCursor(in: sql, cursorPosition: 12)
        #expect(located.sql == " SELECT 2")
        #expect(located.offset == 9)
    }
}
