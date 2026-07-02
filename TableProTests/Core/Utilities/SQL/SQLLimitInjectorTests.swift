//
//  SQLLimitInjectorTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("SQLLimitInjector appends a LIMIT only when the statement has none")
struct SQLLimitInjectorTests {
    private func inject(
        _ sql: String,
        limit: Int = 501,
        style: AutoLimitStyle = .limit,
        dialect: SqlDialect = .generic
    ) -> SQLLimitInjectionResult {
        SQLLimitInjector.inject(into: sql, limit: limit, autoLimitStyle: style, lexicalDialect: dialect)
    }

    @Test("Appends LIMIT to a bare SELECT")
    func appendsToBareSelect() {
        #expect(inject("SELECT * FROM users") == .injected("SELECT * FROM users LIMIT 501"))
    }

    @Test("Reports alreadyLimited for a top-level LIMIT")
    func detectsExistingLimit() {
        #expect(inject("SELECT * FROM users LIMIT 10") == .alreadyLimited)
        #expect(inject("select * from users limit 10 offset 5") == .alreadyLimited)
    }

    @Test("Reports alreadyLimited for FETCH FIRST")
    func detectsFetchFirst() {
        #expect(inject("SELECT * FROM t FETCH FIRST 5 ROWS ONLY") == .alreadyLimited)
    }

    @Test("Reports alreadyLimited for TOP only under the top style")
    func detectsTopOnlyForTopStyle() {
        #expect(inject("SELECT TOP 5 * FROM t", style: .top) == .alreadyLimited)
        #expect(inject("SELECT top FROM quotas") == .injected("SELECT top FROM quotas LIMIT 501"))
    }

    @Test("Reports notInjectable for a top-level OFFSET without LIMIT")
    func offsetAloneIsNotInjectable() {
        #expect(inject("SELECT * FROM users OFFSET 5") == .notInjectable)
    }

    @Test("Injects on the outer statement when a CTE has an inner LIMIT")
    func injectsOuterStatementForCte() {
        let sql = "WITH cte AS (SELECT * FROM t LIMIT 5) SELECT * FROM cte"
        #expect(inject(sql) == .injected("WITH cte AS (SELECT * FROM t LIMIT 5) SELECT * FROM cte LIMIT 501"))
    }

    @Test("Injects when only a subquery has a LIMIT")
    func injectsWhenSubqueryLimited() {
        let sql = "SELECT * FROM (SELECT * FROM t LIMIT 5) sub"
        #expect(inject(sql) == .injected("SELECT * FROM (SELECT * FROM t LIMIT 5) sub LIMIT 501"))
    }

    @Test("Inserts before a trailing line comment")
    func insertsBeforeTrailingLineComment() {
        #expect(inject("SELECT * FROM t -- fetch it all") == .injected("SELECT * FROM t LIMIT 501 -- fetch it all"))
        #expect(inject("SELECT * FROM t\n-- done") == .injected("SELECT * FROM t LIMIT 501\n-- done"))
    }

    @Test("Inserts before a trailing block comment")
    func insertsBeforeTrailingBlockComment() {
        #expect(inject("SELECT * FROM t /* LIMIT 9 */") == .injected("SELECT * FROM t LIMIT 501 /* LIMIT 9 */"))
    }

    @Test("Keeps a leading comment and injects at the end")
    func keepsLeadingComment() {
        #expect(inject("-- top users\nSELECT * FROM users") == .injected("-- top users\nSELECT * FROM users LIMIT 501"))
    }

    @Test("Treats hash comments as comments only for MySQL")
    func hashCommentsAreDialectGated() {
        #expect(inject("SELECT * FROM t # note", dialect: .mysql) == .injected("SELECT * FROM t LIMIT 501 # note"))
        #expect(inject("SELECT * FROM t # see LIMIT docs", dialect: .mysql)
            == .injected("SELECT * FROM t LIMIT 501 # see LIMIT docs"))
        #expect(inject("SELECT 1 # 2", dialect: .postgres) == .injected("SELECT 1 # 2 LIMIT 501"))
    }

    @Test("Reports notInjectable for Cassandra ALLOW FILTERING")
    func allowFilteringIsNotInjectable() {
        #expect(inject("SELECT * FROM t WHERE x = 1 ALLOW FILTERING") == .notInjectable)
    }

    @Test("Appends once after a UNION without a top-level LIMIT")
    func appendsAfterUnion() {
        let sql = "SELECT a FROM t1 UNION ALL SELECT b FROM t2"
        #expect(inject(sql) == .injected("SELECT a FROM t1 UNION ALL SELECT b FROM t2 LIMIT 501"))
    }

    @Test("Reports alreadyLimited when a LIMIT applies to the whole UNION")
    func detectsUnionTopLevelLimit() {
        #expect(inject("SELECT a FROM t1 UNION SELECT b FROM t2 LIMIT 5") == .alreadyLimited)
    }

    @Test("Appends after a parenthesized UNION whose branches have inner LIMITs")
    func appendsAfterParenthesizedUnion() {
        let sql = "(SELECT a FROM t1 LIMIT 5) UNION (SELECT b FROM t2 LIMIT 5)"
        #expect(inject(sql) == .injected("(SELECT a FROM t1 LIMIT 5) UNION (SELECT b FROM t2 LIMIT 5) LIMIT 501"))
    }

    @Test("Preserves a trailing semicolon after the injected clause")
    func preservesTrailingSemicolon() {
        #expect(inject("SELECT * FROM t;") == .injected("SELECT * FROM t LIMIT 501;"))
        #expect(inject("SELECT * FROM t; -- done") == .injected("SELECT * FROM t LIMIT 501; -- done"))
    }

    @Test("Ignores LIMIT-like text inside string literals")
    func ignoresLimitInsideStrings() {
        #expect(inject("SELECT * FROM t WHERE note = 'no LIMIT here'")
            == .injected("SELECT * FROM t WHERE note = 'no LIMIT here' LIMIT 501"))
    }

    @Test("Ignores LIMIT inside dollar-quoted bodies for PostgreSQL")
    func ignoresLimitInsideDollarQuotes() {
        let sql = "SELECT $tag$LIMIT 5$tag$ FROM t"
        #expect(inject(sql, dialect: .postgres) == .injected("SELECT $tag$LIMIT 5$tag$ FROM t LIMIT 501"))
    }

    @Test("Does not mistake identifiers containing limit for a LIMIT clause")
    func ignoresLimitLikeIdentifiers() {
        #expect(inject("SELECT limit_used FROM quotas") == .injected("SELECT limit_used FROM quotas LIMIT 501"))
        #expect(inject("SELECT `limit` FROM quotas") == .injected("SELECT `limit` FROM quotas LIMIT 501"))
    }

    @Test("Reports notInjectable for trailing clauses that must not precede LIMIT")
    func trailingClausesAreNotInjectable() {
        #expect(inject("SELECT * FROM t FOR UPDATE") == .notInjectable)
        #expect(inject("SELECT * FROM t LOCK IN SHARE MODE") == .notInjectable)
        #expect(inject("SELECT * INTO backup FROM t") == .notInjectable)
        #expect(inject("SELECT * FROM t FORMAT JSON") == .notInjectable)
        #expect(inject("SELECT * FROM t SETTINGS max_threads = 1") == .notInjectable)
    }

    @Test("Reports notInjectable for non-limit dialect styles")
    func nonLimitStylesAreNotInjectable() {
        #expect(inject("SELECT * FROM t", style: .top) == .notInjectable)
        #expect(inject("SELECT * FROM t", style: .fetchFirst) == .notInjectable)
        #expect(inject("SELECT * FROM t", style: AutoLimitStyle.none) == .notInjectable)
    }

    @Test("Detects an existing constraint even for non-limit dialect styles")
    func detectsConstraintForNonLimitStyles() {
        #expect(inject("SELECT * FROM t FETCH FIRST 5 ROWS ONLY", style: .fetchFirst) == .alreadyLimited)
    }

    @Test("Reports notInjectable for non-positive limits, empty input, and unbalanced statements")
    func invalidInputIsNotInjectable() {
        #expect(inject("SELECT * FROM t", limit: 0) == .notInjectable)
        #expect(inject("") == .notInjectable)
        #expect(inject("   ") == .notInjectable)
        #expect(inject("-- only a comment") == .notInjectable)
        #expect(inject("SELECT * FROM (t") == .notInjectable)
        #expect(inject("SELECT 'unterminated FROM t") == .notInjectable)
    }

    @Test("Reports notInjectable when code follows a top-level semicolon")
    func multiStatementInputIsNotInjectable() {
        #expect(inject("SELECT 1; SELECT 2") == .notInjectable)
    }

    @Test("Handles escaped quotes inside string literals")
    func handlesEscapedQuotes() {
        #expect(inject("SELECT * FROM t WHERE name = 'it''s'")
            == .injected("SELECT * FROM t WHERE name = 'it''s' LIMIT 501"))
    }
}
