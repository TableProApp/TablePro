//
//  CassandraBrowseStatementTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct CassandraBrowseStatementTests {
    private func filter(_ column: String, _ op: String, _ value: String, upper: String? = nil) -> PluginQueryFilter {
        PluginQueryFilter(column: column, op: op, value: value, secondValue: upper, elementScope: nil)
    }

    private func browse(
        filters: [PluginQueryFilter] = [],
        matchAll: Bool = true,
        sorted: Bool = false,
        keyspace: String? = "shop",
        limit: Int = 1_000,
        offset: Int = 0
    ) -> CassandraBrowseStatement {
        CassandraBrowseRenderer.browse(
            keyspace: keyspace, table: "users", columns: [], filters: filters, matchAll: matchAll,
            sorted: sorted, limit: limit, offset: offset
        )
    }

    @Test("A browse is plain CQL with no OFFSET, no ORDER BY and no LIMIT, whatever the page")
    func browseNeverSeeksInCQL() {
        let statement = browse(offset: 5_000)

        #expect(statement.cql == #"SELECT * FROM "shop"."users""#)
        #expect(!statement.text.contains("OFFSET"))
        #expect(!statement.text.contains("ORDER BY"))
        #expect(statement.window.offset == 5_000)
        #expect(statement.window.limit == 1_000)
        #expect(statement.window.refusal == nil)
    }

    @Test("The window rides in a leading comment, so the statement still runs as CQL anywhere else")
    func windowIsALeadingComment() {
        let text = browse(offset: 2_000).text

        #expect(text.hasPrefix("/* TablePro browse {"))
        #expect(text.hasSuffix(#" */ SELECT * FROM "shop"."users""#))
    }

    @Test("A statement round-trips through its text")
    func roundTrip() throws {
        let statement = browse(filters: [filter("v", "=", "3"), filter("n", ">", "2")], offset: 1_000)

        let parsed = try #require(CassandraBrowseStatement.parse(statement.text))

        #expect(parsed == statement)
    }

    @Test("A value holding a comment terminator cannot end the header early")
    func valueCannotCloseTheComment() throws {
        let statement = browse(filters: [filter("name", "=", "a */ DROP TABLE users; /* b")])

        let parsed = try #require(CassandraBrowseStatement.parse(statement.text))

        #expect(parsed.window.values == ["a */ DROP TABLE users; /* b"])
        #expect(parsed.cql == #"SELECT * FROM "shop"."users" WHERE "name" = ? ALLOW FILTERING"#)
    }

    @Test("Text that is not a browse statement is not parsed as one")
    func ordinaryCQLIsNotABrowse() {
        #expect(CassandraBrowseStatement.parse("SELECT * FROM users") == nil)
        #expect(CassandraBrowseStatement.parse("/* a comment */ SELECT * FROM users") == nil)
        #expect(CassandraBrowseStatement.parse("/* TablePro browse not json */ SELECT 1") == nil)
    }

    @Test("A condition binds its value and puts ALLOW FILTERING last")
    func allowFilteringComesLast() {
        let statement = browse(filters: [filter("v", "=", "3"), filter("n", "<=", "9")])

        #expect(statement.cql == #"SELECT * FROM "shop"."users" WHERE "v" = ? AND "n" <= ? ALLOW FILTERING"#)
        #expect(statement.window.values == ["3", "9"])
        #expect(statement.cql.hasSuffix("ALLOW FILTERING"))
    }

    @Test("IN binds one marker per item")
    func inBindsEachItem() {
        let statement = browse(filters: [filter("id", "IN", "1, 2 ,3")])

        #expect(statement.cql == #"SELECT * FROM "shop"."users" WHERE "id" IN (?, ?, ?) ALLOW FILTERING"#)
        #expect(statement.window.values == ["1", "2", "3"])
    }

    @Test("BETWEEN is two bounds CQL can say, read from the upper bound the app carries apart")
    func betweenIsTwoBounds() {
        let statement = browse(filters: [filter("n", "BETWEEN", "1,5", upper: "5")])

        #expect(statement.cql == #"SELECT * FROM "shop"."users" WHERE "n" >= ? AND "n" <= ? ALLOW FILTERING"#)
        #expect(statement.window.values == ["1", "5"])
    }

    @Test("Contains, starts with and ends with are LIKE patterns")
    func textMatchesAreLike() {
        let statement = browse(filters: [
            filter("a", "CONTAINS", "x"), filter("b", "STARTS WITH", "y"), filter("c", "ENDS WITH", "z")
        ])

        #expect(statement.cql.contains(#""a" LIKE ? AND "b" LIKE ? AND "c" LIKE ?"#))
        #expect(statement.window.values == ["%x%", "y%", "%z"])
    }

    @Test("A LIKE pattern matches the user's percent, underscore and backslash literally")
    func likeWildcardsAreEscaped() {
        let statement = browse(filters: [filter("s", "CONTAINS", #"100%_a\b"#)])

        #expect(statement.window.values == [#"%100\%\_a\\b%"#])
        #expect(CassandraBrowseRenderer.likeLiteral("plain") == "plain")
    }

    @Test("A browse capped for a query tab reads one row past the cap and keeps its window otherwise")
    func cappedAtReadsOnePastTheCap() {
        let statement = browse(filters: [filter("v", "=", "3")], limit: 5_000, offset: 200)

        let capped = statement.cappedAt(rowCap: 1_000)

        #expect(capped.window.limit == 1_001)
        #expect(capped.window.offset == 200)
        #expect(capped.window.values == ["3"])
        #expect(capped.cql == statement.cql)
        #expect(statement.cappedAt(rowCap: 10_000).window.limit == 5_000)
    }

    @Test("A raw filter is written as the user typed it")
    func rawFilterIsVerbatim() {
        let statement = browse(filters: [filter("__RAW__", "=", "token(id) > 0")])

        #expect(statement.cql == #"SELECT * FROM "shop"."users" WHERE token(id) > 0 ALLOW FILTERING"#)
        #expect(statement.window.values.isEmpty)
    }

    @Test("What CQL cannot say is refused by name, not sent", arguments: [
        "!=", "NOT CONTAINS", "IS NULL", "IS NOT NULL", "IS EMPTY", "IS NOT EMPTY", "NOT IN", "REGEX"
    ])
    func unsupportedOperatorIsRefused(op: String) {
        let statement = browse(filters: [filter("v", op, "1")])

        #expect(statement.window.refusal == CassandraBrowseRefusal.unsupportedOperator(op).pluginErrorMessage)
        #expect(!statement.cql.contains("WHERE"))
    }

    @Test("Match Any over several conditions is refused")
    func matchAnyIsRefused() {
        let statement = browse(filters: [filter("a", "=", "1"), filter("b", "=", "2")], matchAll: false)

        #expect(statement.window.refusal == CassandraBrowseRefusal.matchAny.pluginErrorMessage)
    }

    @Test("Match Any over a single condition is just that condition")
    func matchAnyOfOneRuns() {
        let statement = browse(filters: [filter("a", "=", "1")], matchAll: false)

        #expect(statement.window.refusal == nil)
        #expect(statement.cql.contains(#"WHERE "a" = ?"#))
    }

    @Test("A sort is refused rather than dropped")
    func sortIsRefused() {
        let statement = browse(sorted: true)

        #expect(statement.window.refusal == CassandraBrowseRefusal.sorting.pluginErrorMessage)
        #expect(!statement.cql.contains("ORDER BY"))
    }

    @Test("An empty IN list and a half-open range are refused")
    func incompleteOperandsAreRefused() {
        #expect(browse(filters: [filter("id", "IN", " , ")]).window.refusal
            == CassandraBrowseRefusal.emptyList.pluginErrorMessage)
        #expect(browse(filters: [filter("n", "BETWEEN", "1")]).window.refusal
            == CassandraBrowseRefusal.incompleteRange.pluginErrorMessage)
    }

    @Test("No keyspace leaves the table unqualified, never the system keyspace")
    func missingKeyspaceIsUnqualified() {
        #expect(browse(keyspace: nil).cql == #"SELECT * FROM "users""#)
        #expect(browse(keyspace: "").cql == #"SELECT * FROM "users""#)
    }

    @Test("Identifiers are quoted with their own quotes doubled")
    func identifiersAreQuoted() {
        let statement = CassandraBrowseRenderer.browse(
            keyspace: #"k"s"#, table: #"t"1"#, columns: ["a", #"b"c"#], filters: [], matchAll: true,
            sorted: false, limit: 10, offset: 0
        )

        #expect(statement.cql == #"SELECT "a", "b""c" FROM "k""s"."t""1""#)
    }

    @Test("A count carries the same conditions and ALLOW FILTERING, and nothing when unfiltered")
    func countRendering() throws {
        let filtered = try CassandraBrowseRenderer.count(
            keyspace: "shop", table: "users", filters: [filter("v", "=", "3")], matchAll: true
        )
        let whole = try CassandraBrowseRenderer.count(keyspace: "shop", table: "users", filters: [], matchAll: true)

        #expect(filtered.cql == #"SELECT COUNT(*) FROM "shop"."users" WHERE "v" = ? ALLOW FILTERING"#)
        #expect(filtered.values == ["3"])
        #expect(whole.cql == #"SELECT COUNT(*) FROM "shop"."users""#)
    }

    @Test("A count refuses what a browse refuses")
    func countRefusesMatchAny() {
        #expect(throws: CassandraBrowseRefusal.matchAny) {
            try CassandraBrowseRenderer.count(
                keyspace: nil, table: "users", filters: [filter("a", "=", "1"), filter("b", "=", "2")], matchAll: false
            )
        }
    }
}
