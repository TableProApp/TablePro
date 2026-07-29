//
//  DerivedTableParserTests.swift
//  TableProTests
//
//  Tests for derived-table and CTE column extraction.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Derived Table Parser")
struct DerivedTableParserTests {
    let parser = DerivedTableParser()

    private func table(_ tables: [DerivedTable], alias: String) -> DerivedTable? {
        tables.first { $0.alias.caseInsensitiveCompare(alias) == .orderedSame }
    }

    @Test("Resolves the reported derived-table join")
    func resolvesReportedQuery() {
        let query = """
        SELECT YEAR, hs.country, happiness_score, ahs.avg_happiness_score
        FROM happiness_scores hs
        LEFT JOIN (
          SELECT country, AVG(happiness_score) AS avg_happiness_score
          FROM happiness_scores
          GROUP BY country
        ) ahs
          ON hs.country = ahs.country;
        """
        let ahs = table(parser.parse(query), alias: "ahs")
        #expect(ahs?.columns == ["country", "avg_happiness_score"])
    }

    @Test("Derived table in FROM clause")
    func derivedTableInFrom() {
        let query = "SELECT * FROM (SELECT id, name FROM users) u"
        #expect(table(parser.parse(query), alias: "u")?.columns == ["id", "name"])
    }

    @Test("Derived table with AS keyword before alias")
    func derivedTableWithAsAlias() {
        let query = "SELECT * FROM (SELECT id FROM users) AS u"
        #expect(table(parser.parse(query), alias: "u")?.columns == ["id"])
    }

    @Test("Derived table in a comma-separated FROM list")
    func derivedTableInFromList() {
        let query = "SELECT * FROM orders o, (SELECT total FROM payments) p"
        #expect(table(parser.parse(query), alias: "p")?.columns == ["total"])
    }

    @Test("Qualified column keeps only the trailing identifier")
    func qualifiedColumn() {
        let query = "SELECT * FROM (SELECT u.id, u.email FROM users u) d"
        #expect(table(parser.parse(query), alias: "d")?.columns == ["id", "email"])
    }

    @Test("SELECT star yields no resolvable columns")
    func selectStarYieldsNoColumns() {
        let query = "SELECT * FROM (SELECT * FROM users) d"
        #expect(table(parser.parse(query), alias: "d")?.columns.isEmpty == true)
    }

    @Test("Qualified star is skipped")
    func qualifiedStarSkipped() {
        let query = "SELECT * FROM (SELECT u.*, u.id FROM users u) d"
        #expect(table(parser.parse(query), alias: "d")?.columns == ["id"])
    }

    @Test("Unaliased expressions are skipped")
    func unaliasedExpressionSkipped() {
        let query = "SELECT * FROM (SELECT name, COUNT(*) FROM users GROUP BY name) d"
        #expect(table(parser.parse(query), alias: "d")?.columns == ["name"])
    }

    @Test("Nested subquery exposes only the outer alias")
    func nestedSubquery() {
        let query = "SELECT * FROM (SELECT a FROM (SELECT id AS a FROM t) inner_q) outer_q"
        let tables = parser.parse(query)
        #expect(table(tables, alias: "outer_q")?.columns == ["a"])
        #expect(table(tables, alias: "inner_q") == nil)
    }

    @Test("CTE columns come from its SELECT list")
    func cteColumns() {
        let query = "WITH totals AS (SELECT country, SUM(score) AS total FROM s GROUP BY country) SELECT * FROM totals"
        #expect(table(parser.parse(query), alias: "totals")?.columns == ["country", "total"])
    }

    @Test("CTE explicit column list overrides the SELECT list")
    func cteExplicitColumnList() {
        let query = "WITH totals (region, amount) AS (SELECT country, SUM(score) FROM s GROUP BY country) SELECT * FROM totals"
        #expect(table(parser.parse(query), alias: "totals")?.columns == ["region", "amount"])
    }

    @Test("Multiple CTEs are each resolved")
    func multipleCtes() {
        let query = """
        WITH a AS (SELECT x FROM t1),
             b AS (SELECT y, z FROM t2)
        SELECT * FROM a JOIN b ON a.x = b.y
        """
        let tables = parser.parse(query)
        #expect(table(tables, alias: "a")?.columns == ["x"])
        #expect(table(tables, alias: "b")?.columns == ["y", "z"])
    }

    @Test("Quoted alias is unquoted")
    func quotedAlias() {
        let query = "SELECT * FROM (SELECT AVG(score) AS `avg_score` FROM s) d"
        #expect(table(parser.parse(query), alias: "d")?.columns == ["avg_score"])
    }

    @Test("Subquery in WHERE IN is not a derived table")
    func subqueryInWhereIsNotDerived() {
        let query = "SELECT * FROM users WHERE id IN (SELECT user_id FROM orders)"
        #expect(parser.parse(query).isEmpty)
    }

    @Test("Function call parentheses are not derived tables")
    func functionCallNotDerived() {
        let query = "SELECT COUNT(id), AVG(score) FROM users"
        #expect(parser.parse(query).isEmpty)
    }

    @Test("Distinct in a derived select list is ignored")
    func distinctIgnored() {
        let query = "SELECT * FROM (SELECT DISTINCT country FROM s) d"
        #expect(table(parser.parse(query), alias: "d")?.columns == ["country"])
    }

    @Test("Commas inside function arguments do not split columns")
    func commasInFunctionArgs() {
        let query = "SELECT * FROM (SELECT COALESCE(a, b) AS first_set, c FROM t) d"
        #expect(table(parser.parse(query), alias: "d")?.columns == ["first_set", "c"])
    }
}
