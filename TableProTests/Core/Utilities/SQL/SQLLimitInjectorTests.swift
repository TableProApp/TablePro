//
//  SQLLimitInjectorTests.swift
//  TableProTests
//

import Foundation
import Testing
import TableProPluginKit
@testable import TablePro

@Suite("SQLLimitInjector appends a LIMIT only when the statement has none")
struct SQLLimitInjectorTests {
    private func inject(
        _ sql: String,
        limit: Int = 501,
        style: AutoLimitStyle = .limit,
        dialect: SqlDialect = .generic
    ) -> String? {
        SQLLimitInjector.inject(into: sql, limit: limit, autoLimitStyle: style, lexicalDialect: dialect)
    }

    @Test("Appends LIMIT to a bare SELECT")
    func appendsToBareSelect() {
        #expect(inject("SELECT * FROM users") == "SELECT * FROM users LIMIT 501")
    }

    @Test("Returns nil when a top-level LIMIT already exists")
    func skipsExistingLimit() {
        #expect(inject("SELECT * FROM users LIMIT 10") == nil)
        #expect(inject("select * from users limit 10 offset 5") == nil)
    }

    @Test("Returns nil when a top-level OFFSET exists without LIMIT")
    func skipsExistingOffset() {
        #expect(inject("SELECT * FROM users OFFSET 5") == nil)
    }

    @Test("Injects on the outer statement when a CTE has an inner LIMIT")
    func injectsOuterStatementForCte() {
        let sql = "WITH cte AS (SELECT * FROM t LIMIT 5) SELECT * FROM cte"
        #expect(inject(sql) == "WITH cte AS (SELECT * FROM t LIMIT 5) SELECT * FROM cte LIMIT 501")
    }

    @Test("Injects when only a subquery has a LIMIT")
    func injectsWhenSubqueryLimited() {
        let sql = "SELECT * FROM (SELECT * FROM t LIMIT 5) sub"
        #expect(inject(sql) == "SELECT * FROM (SELECT * FROM t LIMIT 5) sub LIMIT 501")
    }

    @Test("Inserts before a trailing line comment")
    func insertsBeforeTrailingLineComment() {
        #expect(inject("SELECT * FROM t -- fetch it all") == "SELECT * FROM t LIMIT 501 -- fetch it all")
        #expect(inject("SELECT * FROM t\n-- done") == "SELECT * FROM t LIMIT 501\n-- done")
    }

    @Test("Inserts before a trailing block comment")
    func insertsBeforeTrailingBlockComment() {
        #expect(inject("SELECT * FROM t /* LIMIT 9 */") == "SELECT * FROM t LIMIT 501 /* LIMIT 9 */")
    }

    @Test("Keeps a leading comment and injects at the end")
    func keepsLeadingComment() {
        #expect(inject("-- top users\nSELECT * FROM users") == "-- top users\nSELECT * FROM users LIMIT 501")
    }

    @Test("Appends once after a UNION without a top-level LIMIT")
    func appendsAfterUnion() {
        let sql = "SELECT a FROM t1 UNION ALL SELECT b FROM t2"
        #expect(inject(sql) == "SELECT a FROM t1 UNION ALL SELECT b FROM t2 LIMIT 501")
    }

    @Test("Returns nil when a LIMIT applies to the whole UNION")
    func skipsUnionWithTopLevelLimit() {
        #expect(inject("SELECT a FROM t1 UNION SELECT b FROM t2 LIMIT 5") == nil)
    }

    @Test("Appends after a parenthesized UNION whose branches have inner LIMITs")
    func appendsAfterParenthesizedUnion() {
        let sql = "(SELECT a FROM t1 LIMIT 5) UNION (SELECT b FROM t2 LIMIT 5)"
        #expect(inject(sql) == "(SELECT a FROM t1 LIMIT 5) UNION (SELECT b FROM t2 LIMIT 5) LIMIT 501")
    }

    @Test("Preserves a trailing semicolon after the injected clause")
    func preservesTrailingSemicolon() {
        #expect(inject("SELECT * FROM t;") == "SELECT * FROM t LIMIT 501;")
        #expect(inject("SELECT * FROM t; -- done") == "SELECT * FROM t LIMIT 501; -- done")
    }

    @Test("Ignores LIMIT-like text inside string literals")
    func ignoresLimitInsideStrings() {
        #expect(inject("SELECT * FROM t WHERE note = 'no LIMIT here'")
            == "SELECT * FROM t WHERE note = 'no LIMIT here' LIMIT 501")
    }

    @Test("Ignores LIMIT inside dollar-quoted bodies for PostgreSQL")
    func ignoresLimitInsideDollarQuotes() {
        let sql = "SELECT $tag$LIMIT 5$tag$ FROM t"
        #expect(inject(sql, dialect: .postgres) == "SELECT $tag$LIMIT 5$tag$ FROM t LIMIT 501")
    }

    @Test("Does not mistake identifiers containing limit for a LIMIT clause")
    func ignoresLimitLikeIdentifiers() {
        #expect(inject("SELECT limit_used FROM quotas") == "SELECT limit_used FROM quotas LIMIT 501")
        #expect(inject("SELECT `limit` FROM quotas") == "SELECT `limit` FROM quotas LIMIT 501")
    }

    @Test("Returns nil for trailing clauses that must not precede LIMIT")
    func skipsUnsupportedTrailingClauses() {
        #expect(inject("SELECT * FROM t FOR UPDATE") == nil)
        #expect(inject("SELECT * FROM t LOCK IN SHARE MODE") == nil)
        #expect(inject("SELECT * INTO backup FROM t") == nil)
        #expect(inject("SELECT * FROM t FORMAT JSON") == nil)
        #expect(inject("SELECT * FROM t SETTINGS max_threads = 1") == nil)
    }

    @Test("Returns nil when the statement already uses FETCH FIRST")
    func skipsFetchFirst() {
        #expect(inject("SELECT * FROM t FETCH FIRST 5 ROWS ONLY") == nil)
    }

    @Test("Returns nil for non-limit dialect styles")
    func skipsNonLimitStyles() {
        #expect(inject("SELECT * FROM t", style: .top) == nil)
        #expect(inject("SELECT * FROM t", style: .fetchFirst) == nil)
        #expect(inject("SELECT * FROM t", style: .none) == nil)
    }

    @Test("Returns nil for non-positive limits, empty input, and unbalanced statements")
    func skipsInvalidInput() {
        #expect(inject("SELECT * FROM t", limit: 0) == nil)
        #expect(inject("") == nil)
        #expect(inject("   ") == nil)
        #expect(inject("-- only a comment") == nil)
        #expect(inject("SELECT * FROM (t") == nil)
        #expect(inject("SELECT 'unterminated FROM t") == nil)
    }

    @Test("Returns nil when code follows a top-level semicolon")
    func skipsMultiStatementInput() {
        #expect(inject("SELECT 1; SELECT 2") == nil)
    }

    @Test("Handles escaped quotes inside string literals")
    func handlesEscapedQuotes() {
        #expect(inject("SELECT * FROM t WHERE name = 'it''s'")
            == "SELECT * FROM t WHERE name = 'it''s' LIMIT 501")
    }
}
