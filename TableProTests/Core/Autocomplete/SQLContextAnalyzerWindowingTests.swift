//
//  SQLContextAnalyzerWindowingTests.swift
//  TableProTests
//
//  Regression tests for SQLContextAnalyzer clause detection on large queries.
//  Ensures windowing optimizations preserve correct clause detection.
//

@testable import TablePro
import Testing

@Suite("SQLContextAnalyzer Windowing")
struct SQLContextAnalyzerWindowingTests {
    private let analyzer = SQLContextAnalyzer()

    // MARK: - Normal Short Queries

    @Test("Short SELECT WHERE query detects WHERE clause")
    func shortSelectWhereDetectsWhereClause() {
        let query = "SELECT * FROM users WHERE "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .where_)
    }

    @Test("Short SELECT query detects SELECT clause")
    func shortSelectDetectsSelectClause() {
        let query = "SELECT "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .select)
    }

    @Test("Short FROM query detects FROM clause")
    func shortFromDetectsFromClause() {
        let query = "SELECT id FROM "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .from)
    }

    // MARK: - Large Query with Clause at End

    @Test("Large query with WHERE at end detects WHERE clause")
    func largeQueryWhereAtEndDetectsCorrectly() {
        let padding = String(repeating: "a", count: 6_000)
        let query = "SELECT \(padding) FROM users WHERE "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .where_)
    }

    @Test("Large query with ORDER BY at end detects ORDER BY clause")
    func largeQueryOrderByAtEnd() {
        let padding = String(repeating: "x", count: 6_000)
        let query = "SELECT \(padding) FROM users ORDER BY "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .orderBy)
    }

    @Test("Large query with GROUP BY at end detects GROUP BY clause")
    func largeQueryGroupByAtEnd() {
        let padding = String(repeating: "x", count: 6_000)
        let query = "SELECT \(padding) FROM users GROUP BY "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .groupBy)
    }

    @Test("Large query with JOIN at end detects JOIN clause")
    func largeQueryJoinAtEnd() {
        let padding = String(repeating: "x", count: 6_000)
        let query = "SELECT \(padding) FROM users JOIN "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .join)
    }

    // MARK: - Large Query with INSERT Context

    @Test("Large INSERT with VALUES keyword near cursor detects values context")
    func largeQueryInsertIntoValuesAtEnd() {
        let padding = String(repeating: "x", count: 4000)
        let query = "INSERT INTO users (\(padding)) VALUES ('a', 'b'), "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .values)
    }

    // MARK: - Clause Keyword Only at Beginning (Far from Cursor)

    @Test("Large query with SELECT and many columns, cursor at end")
    func largeQuerySelectManyColumns() {
        let columns = (1...600).map { "col\($0)" }.joined(separator: ", ")
        let query = "SELECT \(columns), "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .select)
    }

    // MARK: - Edge Cases

    @Test("Empty text returns unknown clause type")
    func emptyTextReturnsUnknown() {
        let context = analyzer.analyze(query: "", cursorPosition: 0)
        #expect(context.clauseType == .unknown)
    }

    @Test("Whitespace-only text returns unknown clause type")
    func whitespaceOnlyReturnsUnknown() {
        let query = "   \t\n   "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .unknown)
    }

    @Test("Cursor at position zero returns unknown")
    func cursorAtZeroReturnsUnknown() {
        let query = "SELECT * FROM users"
        let context = analyzer.analyze(query: query, cursorPosition: 0)
        #expect(context.clauseType == .unknown)
    }

    @Test("Cursor in middle of large query detects correct clause")
    func cursorInMiddleOfLargeQuery() {
        let padding = String(repeating: "x", count: 3_000)
        let query = "SELECT * FROM users WHERE \(padding) AND "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .and)
    }

    // MARK: - Multiple Clauses in Large Query

    @Test("Large query with multiple clauses detects last clause near cursor")
    func multipleClausesDetectsLastOne() {
        let padding = String(repeating: "column_name, ", count: 400)
        let query = "SELECT \(padding)id FROM users WHERE status = 1 ORDER BY "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .orderBy)
    }

    @Test("HAVING clause after large GROUP BY expression")
    func havingAfterLargeGroupBy() {
        let columns = (1...500).map { "col\($0)" }.joined(separator: ", ")
        let query = "SELECT \(columns) FROM data GROUP BY \(columns) HAVING "
        let context = analyzer.analyze(query: query, cursorPosition: query.count)
        #expect(context.clauseType == .having)
    }
}
