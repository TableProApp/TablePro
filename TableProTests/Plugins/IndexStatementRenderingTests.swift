//
//  IndexStatementRenderingTests.swift
//  TableProTests
//

import Foundation
import TableProMSSQLCore
import Testing

/// SQL Server's `CREATE INDEX` has to be built from catalog rows rather than read back from the
/// engine. The catalog queries themselves need a live server, so what is pinned here is the
/// rendering: given the rows those queries return, this is the SQL that goes in the dump.
struct IndexStatementRenderingTests {
    @Suite("SQL Server")
    struct SQLServer {
        private func render(_ rows: [[String?]]) -> [String] {
            MSSQLSchemaQueries.indexStatements(rows: rows, schema: "dbo", table: "orders")
        }

        @Test("A single-column nonclustered index")
        func singleColumn() {
            let sql = render([["idx_day", "NONCLUSTERED", "0", nil, "day", "0", "0"]])
            #expect(sql == ["CREATE NONCLUSTERED INDEX [idx_day] ON [dbo].[orders] ([day]);"])
        }

        @Test("Each index keeps the kind the catalog reports, so two clustered ones are never written")
        func kindComesFromTheCatalog() {
            let sql = render([
                ["idx_a", "CLUSTERED", "0", nil, "a", "0", "0"],
                ["idx_b", "NONCLUSTERED", "0", nil, "b", "0", "0"]
            ])
            #expect(sql[0].contains("CLUSTERED INDEX [idx_a]"))
            #expect(sql[1].contains("NONCLUSTERED INDEX [idx_b]"))
            #expect(sql.filter { $0.contains(" CLUSTERED INDEX") }.count == 1)
        }

        @Test("A composite key keeps its column order and its sort direction")
        func compositeKey() {
            let sql = render([
                ["idx_ab", "NONCLUSTERED", "0", nil, "a", "0", "0"],
                ["idx_ab", "NONCLUSTERED", "0", nil, "b", "0", "1"]
            ])
            #expect(sql == ["CREATE NONCLUSTERED INDEX [idx_ab] ON [dbo].[orders] ([a], [b] DESC);"])
        }

        @Test("An INCLUDE column lands in INCLUDE rather than in the key")
        func includedColumns() {
            let sql = render([
                ["idx_a", "NONCLUSTERED", "0", nil, "a", "0", "0"],
                ["idx_a", "NONCLUSTERED", "0", nil, "note", "1", "0"]
            ])
            #expect(sql == ["CREATE NONCLUSTERED INDEX [idx_a] ON [dbo].[orders] ([a]) INCLUDE ([note]);"])
        }

        @Test("A unique index says so and a filtered one keeps its predicate")
        func uniqueAndFiltered() {
            let sql = render([["idx_a", "NONCLUSTERED", "1", "([a]>(0))", "a", "0", "0"]])
            #expect(sql == [
                "CREATE UNIQUE NONCLUSTERED INDEX [idx_a] ON [dbo].[orders] ([a]) WHERE ([a]>(0));"
            ])
        }

        @Test("An index with only INCLUDE columns and no key is not written")
        func keylessIndexIsSkipped() {
            #expect(render([["idx_a", "NONCLUSTERED", "0", nil, "note", "1", "0"]]).isEmpty)
        }

        @Test("A bracket in a name is escaped")
        func bracketsAreEscaped() {
            let sql = MSSQLSchemaQueries.indexStatements(
                rows: [["idx]a", "NONCLUSTERED", "0", nil, "c]1", "0", "0"]],
                schema: "dbo", table: "orders")
            #expect(sql == ["CREATE NONCLUSTERED INDEX [idx]]a] ON [dbo].[orders] ([c]]1]);"])
        }
    }
}
