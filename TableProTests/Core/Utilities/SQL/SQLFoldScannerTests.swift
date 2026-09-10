//
//  SQLFoldScannerTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("SQL Fold Scanner")
struct SQLFoldScannerTests {

    private func regions(_ sql: String, dialect: SqlDialect = .generic) -> [SQLFoldRegion] {
        SQLFoldScanner.scan(sql as NSString, dialect: dialect).regions
    }

    // MARK: - Nothing to fold

    @Test("Empty document yields no regions")
    func emptyDocument() {
        #expect(regions("").isEmpty)
    }

    @Test("Single line statement is not foldable")
    func singleLineStatement() {
        #expect(regions("SELECT 1;").isEmpty)
    }

    @Test("Parentheses that open and close on one line are not foldable")
    func singleLineParens() {
        #expect(regions("SELECT count(*) FROM t WHERE id IN (1, 2, 3);").isEmpty)
    }

    @Test("Single line block comment is not foldable")
    func singleLineBlockComment() {
        #expect(regions("/* note */ SELECT 1;").isEmpty)
    }

    // MARK: - Statements

    @Test("Multi-line statement folds, and the opening line stays visible")
    func multiLineStatement() {
        let sql = """
        CREATE SEQUENCE order_id
            START WITH 1
            INCREMENT BY 1;
        """
        let found = regions(sql)
        #expect(found.count == 1)

        let statement = try! #require(found.first)
        #expect(statement.kind == .statement)
        #expect(statement.depth == 1)
        #expect(statement.startLine == 0)
        #expect(statement.endLine == 2)

        let prefix = (sql as NSString).substring(to: statement.range.lowerBound)
        #expect(prefix == "CREATE SEQUENCE order_id")
    }

    @Test("Each statement in a script gets its own region")
    func multipleStatements() {
        let sql = """
        CREATE SEQUENCE a
            START WITH 1;
        CREATE SEQUENCE b
            START WITH 2;
        """
        let statements = regions(sql).filter { $0.kind == .statement }
        #expect(statements.count == 2)
        #expect(statements.allSatisfy { $0.depth == 1 })
    }

    // MARK: - Nested blocks

    @Test("A table body nests one level under its statement")
    func tableBodyNestsUnderStatement() {
        let sql = """
        CREATE TABLE users (
            id BIGSERIAL,
            name TEXT
        );
        """
        let found = regions(sql)
        #expect(found.contains { $0.kind == .statement && $0.depth == 1 })

        let body = try! #require(found.first { $0.kind == .parenGroup })
        #expect(body.depth == 2)
        #expect(body.startLine == 0)
        #expect(body.endLine == 3)

        let prefix = (sql as NSString).substring(to: body.range.lowerBound)
        #expect(prefix == "CREATE TABLE users (")
    }

    @Test("A subquery nests under the enclosing parentheses")
    func nestedSubquery() {
        let sql = """
        SELECT *
        FROM (
            SELECT id
            FROM (
                SELECT 1
            ) inner_t
        ) outer_t;
        """
        let depths = regions(sql).filter { $0.kind == .parenGroup }.map(\.depth).sorted()
        #expect(depths == [2, 3])
    }

    @Test("A CTE body needs no special handling")
    func commonTableExpression() {
        let sql = """
        WITH recent AS (
            SELECT id
            FROM orders
        )
        SELECT * FROM recent;
        """
        #expect(regions(sql).contains { $0.kind == .parenGroup && $0.depth == 2 })
    }

    // MARK: - Keyword blocks

    @Test("BEGIN and END delimit a foldable block")
    func beginEndBlock() {
        let sql = """
        CREATE TRIGGER t BEGIN
            SELECT 1;
            SELECT 2;
        END;
        """
        #expect(regions(sql).contains { $0.kind == .keywordBlock })
    }

    @Test("A CASE nested in a BEGIN block does not close the outer block early")
    func caseNestedInBegin() {
        let sql = """
        BEGIN
            SELECT CASE
                WHEN x THEN 1
                ELSE 2
            END;
            SELECT 3;
        END;
        """
        let blocks = regions(sql).filter { $0.kind == .keywordBlock }
        #expect(blocks.count == 2)

        let outer = try! #require(blocks.min(by: { $0.depth < $1.depth }))
        #expect(outer.startLine == 0)
        #expect(outer.endLine == 6)
    }

    @Test("END IF and END LOOP do not close the enclosing BEGIN block")
    func controlFlowEndDoesNotClose() {
        let sql = """
        BEGIN
            IF x THEN
                SELECT 1;
            END IF;
            FOR r IN c LOOP
                SELECT 2;
            END LOOP;
            SELECT 3;
        END;
        """
        let blocks = regions(sql).filter { $0.kind == .keywordBlock }
        #expect(blocks.count == 1)

        let block = try! #require(blocks.first)
        #expect(block.startLine == 0)
        #expect(block.endLine == 8)
    }

    // MARK: - Comments and literals

    @Test("Multi-line block comment folds")
    func multiLineBlockComment() {
        let sql = """
        /* Orders table
           spans two lines */
        SELECT 1;
        """
        let comment = try! #require(regions(sql).first { $0.kind == .blockComment })
        #expect(comment.startLine == 0)
        #expect(comment.endLine == 1)
    }

    @Test("Syntax inside a string literal is ignored")
    func syntaxInsideStringIsIgnored() {
        let sql = """
        INSERT INTO t VALUES
            ('a ( b BEGIN ; /* c'),
            ('d');
        """
        #expect(regions(sql).allSatisfy { $0.kind != .keywordBlock })

        let parens = regions(sql).filter { $0.kind == .parenGroup }
        #expect(parens.isEmpty)
    }

    @Test("Syntax inside a line comment is ignored")
    func syntaxInsideLineCommentIsIgnored() {
        let sql = """
        SELECT 1
        -- ( BEGIN ;
        , 2;
        """
        #expect(regions(sql).filter { $0.kind == .statement }.count == 1)
        #expect(regions(sql).allSatisfy { $0.kind != .parenGroup })
    }

    @Test("An identifier quoted with backticks does not open a block")
    func backtickIdentifier() {
        let sql = """
        SELECT `a ( b`,
               `c`
        FROM t;
        """
        #expect(regions(sql).allSatisfy { $0.kind != .parenGroup })
    }

    // MARK: - Dialects

    @Test("A dollar quoted body folds as one opaque region on Postgres")
    func dollarQuotedBody() {
        let sql = """
        CREATE FUNCTION f() RETURNS int AS $$
            BEGIN
                RETURN ( 1;
            END;
        $$ LANGUAGE plpgsql;
        """
        let found = regions(sql, dialect: .postgres)
        #expect(found.contains { $0.kind == .quotedBody })
        #expect(found.allSatisfy { $0.kind != .keywordBlock })
        #expect(found.allSatisfy { $0.kind != .parenGroup })
    }

    @Test("A hash line comment is only a comment on MySQL")
    func hashLineComment() {
        let sql = """
        SELECT 1
        # ( comment
        , 2;
        """
        #expect(regions(sql, dialect: .mysql).allSatisfy { $0.kind != .parenGroup })
        #expect(regions(sql, dialect: .postgres).contains { $0.kind == .parenGroup })
    }

    @Test("A backslash escape inside a MySQL string does not end it")
    func mysqlBackslashEscape() {
        let sql = """
        INSERT INTO t VALUES
            ('a\\' ( b'),
            ('c');
        """
        #expect(regions(sql, dialect: .mysql).allSatisfy { $0.kind != .parenGroup })
    }

    // MARK: - Malformed input

    @Test("An unterminated string does not hang or crash")
    func unterminatedString() {
        _ = regions("SELECT 'abc\nFROM t")
    }

    @Test("An unterminated block comment does not hang or crash")
    func unterminatedBlockComment() {
        _ = regions("SELECT 1;\n/* abc\ndef")
    }

    @Test("An unclosed parenthesis still folds to the end of the document")
    func unclosedParen() {
        let sql = """
        CREATE TABLE t (
            id INT,
            name TEXT
        """
        #expect(regions(sql).contains { $0.kind == .parenGroup })
    }

    @Test("An unterminated dollar quote does not hang or crash")
    func unterminatedDollarQuote() {
        _ = regions("SELECT $$abc\ndef", dialect: .postgres)
    }
}

@Suite("SQL fold event ordering")
struct SQLFoldEventOrderingTests {

    private func structure(_ sql: String, dialect: SqlDialect = .generic) -> SQLFoldStructure {
        SQLFoldScanner.scan(sql as NSString, dialect: dialect)
    }

    @Test("A parent opening on the same line as its child is reported before the child")
    func parentStartsBeforeChildOnSharedLine() {
        let sql = """
        SELECT foo(
            1
        );
        """
        let starts = try! #require(structure(sql).startsByLine[0])
        #expect(starts.count == 2)
        #expect(starts.map(\.depth) == [1, 2])
    }

    @Test("A child closing on the same line as its parent is reported before the parent")
    func childEndsBeforeParentOnSharedLine() {
        let sql = """
        SELECT foo(
            1
        );
        """
        let ends = try! #require(structure(sql).endsByLine[2])
        #expect(ends.map(\.depth) == [2, 1])
    }

    @Test("A table body and its statement both survive when they open on one line")
    func tableBodyAndStatementBothSurvive() {
        let sql = """
        CREATE TABLE users (
            id BIGSERIAL
        );
        """
        let starts = try! #require(structure(sql).startsByLine[0])
        #expect(starts.map(\.kind) == [.statement, .parenGroup])
    }

    @Test("A stray closing parenthesis does not close an unrelated open block")
    func strayCloserLeavesOtherFramesOpen() {
        let sql = """
        SELECT SUM(
            CASE WHEN x THEN 1 EN
        )
        , 2;
        """
        let block = try! #require(structure(sql).regions.first { $0.kind == .keywordBlock })
        #expect(block.endLine == 3, "The parenthesis on line 2 closed the CASE block")
    }

    @Test("A block left open by a stray closer still folds to the end of the document")
    func unclosedBlockFoldsToDocumentEnd() {
        let sql = """
        BEGIN
            SELECT 1;
            SELECT 2;
        """
        let block = try! #require(structure(sql).regions.first { $0.kind == .keywordBlock })
        #expect(block.startLine == 0)
        #expect(block.endLine == 2)
    }
}
