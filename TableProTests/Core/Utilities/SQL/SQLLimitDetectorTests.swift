//
//  SQLLimitDetectorTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("SQLLimitDetector")
struct SQLLimitDetectorTests {
    private func hasLimit(
        _ sql: String,
        style: AutoLimitStyle = .limit,
        dialect: SqlDialect = .generic
    ) -> Bool {
        SQLLimitDetector.hasExplicitRowLimit(sql, autoLimitStyle: style, lexicalDialect: dialect)
    }

    @Test("A bare SELECT has no explicit row limit")
    func bareSelect() {
        #expect(!hasLimit("SELECT * FROM users"))
    }

    @Test("A SELECT ending in ORDER BY has no explicit row limit")
    func orderByIsNotALimit() {
        #expect(!hasLimit("SELECT * FROM alert_events ORDER BY alert_time"))
        #expect(!hasLimit("SELECT *\nFROM alert_events ORDER BY alert_time"))
        #expect(!hasLimit("SELECT * FROM t WHERE created_at >= '2026-01-01' ORDER BY id DESC"))
        #expect(!hasLimit("SELECT * FROM t ORDER BY a, b DESC"))
    }

    @Test("Detects a top-level LIMIT")
    func topLevelLimit() {
        #expect(hasLimit("SELECT * FROM users LIMIT 10"))
        #expect(hasLimit("select * from users limit 10 offset 5"))
        #expect(hasLimit("SELECT * FROM t ORDER BY id DESC LIMIT 10"))
    }

    @Test("Detects FETCH FIRST")
    func fetchFirst() {
        #expect(hasLimit("SELECT * FROM t FETCH FIRST 5 ROWS ONLY"))
    }

    @Test("Detects TOP only under the top style")
    func topOnlyForTopStyle() {
        #expect(hasLimit("SELECT TOP 5 * FROM t", style: .top))
        #expect(!hasLimit("SELECT top FROM quotas"))
    }

    @Test("A top-level OFFSET without LIMIT is not an explicit row limit")
    func offsetWithoutLimit() {
        #expect(!hasLimit("SELECT * FROM users OFFSET 5"))
    }

    @Test("An inner LIMIT in a CTE or subquery does not bound the outer statement")
    func innerLimitDoesNotCount() {
        #expect(!hasLimit("WITH cte AS (SELECT * FROM t LIMIT 5) SELECT * FROM cte"))
        #expect(!hasLimit("SELECT * FROM (SELECT * FROM t LIMIT 5) sub"))
        #expect(!hasLimit("(SELECT a FROM t1 LIMIT 5) UNION (SELECT b FROM t2 LIMIT 5)"))
    }

    @Test("Detects a LIMIT that applies to a whole UNION")
    func unionLimit() {
        #expect(hasLimit("SELECT a FROM t1 UNION SELECT b FROM t2 LIMIT 5"))
        #expect(!hasLimit("SELECT a FROM t1 UNION ALL SELECT b FROM t2"))
    }

    @Test("Ignores LIMIT-like text inside comments")
    func ignoresComments() {
        #expect(!hasLimit("SELECT * FROM t -- fetch it all"))
        #expect(!hasLimit("SELECT * FROM t /* LIMIT 9 */"))
        #expect(!hasLimit("SELECT * FROM t # see LIMIT docs", dialect: .mysql))
    }

    @Test("Ignores LIMIT-like text inside string literals")
    func ignoresStringLiterals() {
        #expect(!hasLimit("SELECT * FROM t WHERE note = 'no LIMIT here'"))
    }

    @Test("Ignores LIMIT inside dollar-quoted bodies for PostgreSQL")
    func ignoresDollarQuotedBodies() {
        #expect(!hasLimit("SELECT $tag$LIMIT 5$tag$ FROM t", dialect: .postgres))
    }

    @Test("Does not mistake identifiers containing limit for a LIMIT clause")
    func identifiersContainingLimit() {
        #expect(!hasLimit("SELECT limit_used FROM quotas"))
        #expect(!hasLimit("SELECT `limit` FROM quotas"))
    }

    @Test("Detects a LIMIT after a trailing semicolon is stripped")
    func trailingSemicolon() {
        #expect(hasLimit("SELECT * FROM t LIMIT 5;"))
        #expect(!hasLimit("SELECT * FROM t;"))
    }

    @Test("firstRowLimitClauseOffset points at the top-level LIMIT, OFFSET or FETCH")
    func clauseOffsetFindsTopLevelClause() throws {
        let sql = "SELECT * FROM orders LIMIT 100"
        let offset = try #require(SQLLimitDetector.firstRowLimitClauseOffset(sql, lexicalDialect: .postgres))
        #expect(offset == 21)
        let clause = (sql as NSString).substring(from: offset)
        #expect(clause == "LIMIT 100")
    }

    @Test("firstRowLimitClauseOffset finds a bare OFFSET with no LIMIT")
    func clauseOffsetFindsBareOffset() {
        let offset = SQLLimitDetector.firstRowLimitClauseOffset(
            "SELECT * FROM orders OFFSET 20", lexicalDialect: .postgres
        )
        #expect(offset == 21)
    }

    @Test("firstRowLimitClauseOffset finds an ANSI FETCH clause")
    func clauseOffsetFindsFetch() {
        let sql = "SELECT * FROM orders OFFSET 5 ROWS FETCH NEXT 10 ROWS ONLY"
        let offset = SQLLimitDetector.firstRowLimitClauseOffset(sql, lexicalDialect: .postgres)
        #expect(offset == 21)
    }

    @Test("firstRowLimitClauseOffset ignores a LIMIT inside a subquery or a string")
    func clauseOffsetIgnoresNested() {
        #expect(SQLLimitDetector.firstRowLimitClauseOffset(
            "SELECT * FROM (SELECT * FROM t LIMIT 5) s", lexicalDialect: .postgres
        ) == nil)
        #expect(SQLLimitDetector.firstRowLimitClauseOffset(
            "SELECT * FROM t WHERE note = 'no LIMIT here'", lexicalDialect: .postgres
        ) == nil)
    }

    @Test("firstRowLimitClauseOffset ignores TOP, which is not a trailing clause")
    func clauseOffsetIgnoresTop() {
        #expect(SQLLimitDetector.firstRowLimitClauseOffset(
            "SELECT TOP 10 * FROM t", lexicalDialect: .generic
        ) == nil)
    }

    @Test("firstRowLimitClauseOffset ignores OFFSET and FETCH used as column names")
    func clauseOffsetIgnoresIdentifiers() {
        #expect(SQLLimitDetector.firstRowLimitClauseOffset(
            "SELECT offset, name FROM events", lexicalDialect: .mysql
        ) == nil)
        #expect(SQLLimitDetector.firstRowLimitClauseOffset(
            "SELECT fetch FROM t", lexicalDialect: .mysql
        ) == nil)
        #expect(SQLLimitDetector.firstRowLimitClauseOffset(
            "SELECT offset FROM t ORDER BY offset", lexicalDialect: .mysql
        ) == nil)
    }

    @Test("firstRowLimitClauseOffset accepts a placeholder row count")
    func clauseOffsetAcceptsPlaceholders() {
        #expect(SQLLimitDetector.firstRowLimitClauseOffset(
            "SELECT * FROM t LIMIT ?", lexicalDialect: .mysql
        ) != nil)
        #expect(SQLLimitDetector.firstRowLimitClauseOffset(
            "SELECT * FROM t LIMIT $1", lexicalDialect: .postgres
        ) != nil)
        #expect(SQLLimitDetector.firstRowLimitClauseOffset(
            "SELECT * FROM t LIMIT ALL", lexicalDialect: .postgres
        ) != nil)
    }
}
