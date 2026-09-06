//
//  IndexStatementRenderingTests.swift
//  TableProTests
//

import Foundation
import TableProMSSQLCore
import Testing

/// The four engines whose `CREATE INDEX` has to be built from catalog rows rather than read back
/// from the engine. The catalog queries themselves need a live server, so what is pinned here is
/// the rendering: given the rows those queries return, this is the SQL that goes in the dump.
@Suite("Index statement rendering")
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

    @Suite("Oracle")
    struct Oracle {
        private func render(_ rows: [[String?]]) -> [String] {
            OracleIndexStatements.render(
                rows: rows, schema: "APP", table: "ORDERS", quote: { "\"\($0)\"" })
        }

        @Test("A single-column index")
        func singleColumn() {
            let sql = render([["IDX_DAY", "NONUNIQUE", "NORMAL", "DAY", "ASC"]])
            #expect(sql == ["CREATE INDEX \"APP\".\"IDX_DAY\" ON \"APP\".\"ORDERS\" (\"DAY\");"])
        }

        @Test("A unique index says UNIQUE and a bitmap one says BITMAP")
        func uniquenessAndKind() {
            let sql = render([
                ["IDX_U", "UNIQUE", "NORMAL", "A", "ASC"],
                ["IDX_B", "NONUNIQUE", "BITMAP", "B", "ASC"]
            ])
            #expect(sql[0].contains("CREATE UNIQUE INDEX"))
            #expect(sql[1].contains("CREATE BITMAP INDEX"))
        }

        @Test("A composite key keeps its order and a descending column keeps DESC")
        func compositeKey() {
            let sql = render([
                ["IDX_AB", "NONUNIQUE", "NORMAL", "A", "ASC"],
                ["IDX_AB", "NONUNIQUE", "NORMAL", "B", "DESC"]
            ])
            #expect(sql == ["CREATE INDEX \"APP\".\"IDX_AB\" ON \"APP\".\"ORDERS\" (\"A\", \"B\" DESC);"])
        }

        @Test("A row with no column name contributes nothing")
        func missingColumnIsSkipped() {
            #expect(render([["IDX_A", "NONUNIQUE", "NORMAL", nil, "ASC"]]).isEmpty)
        }
    }

    @Suite("Dameng")
    struct Dameng {
        private func render(_ rows: [[String?]]) -> [String] {
            DamengIndexStatements.render(
                rows: rows, schema: "APP", table: "ORDERS", quote: { "\"\($0)\"" })
        }

        @Test("A single-column index")
        func singleColumn() {
            let sql = render([["IDX_DAY", "NONUNIQUE", "DAY"]])
            #expect(sql == ["CREATE INDEX \"APP\".\"IDX_DAY\" ON \"APP\".\"ORDERS\" (\"DAY\");"])
        }

        @Test("A unique index says UNIQUE and a composite one keeps its column order")
        func uniqueAndComposite() {
            let sql = render([
                ["IDX_AB", "UNIQUE", "A"],
                ["IDX_AB", "UNIQUE", "B"]
            ])
            #expect(sql == ["CREATE UNIQUE INDEX \"APP\".\"IDX_AB\" ON \"APP\".\"ORDERS\" (\"A\", \"B\");"])
        }
    }

    @Suite("Cassandra")
    struct Cassandra {
        private func render(_ rows: [[String?]]) -> [String] {
            CassandraIndexStatements.render(
                rows: rows, keyspace: "app", table: "orders", quote: { "\"\($0)\"" })
        }

        @Test("A custom index is left out, because its options are not reproduced")
        func customIsSkipped() {
            let rows = [["sasi_idx", "CUSTOM", "{class_name: org.apache.cassandra.index.sasi.SASIIndex, target: day}"]]
            #expect(render(rows).isEmpty)
        }

        @Test("A collection target keeps the wrapper as a keyword and quotes the column inside it")
        func collectionTarget() {
            let sql = render([["orders_tags_idx", "COMPOSITES", "{target: keys(tags)}"]])
            #expect(sql == ["CREATE INDEX \"orders_tags_idx\" ON \"app\".\"orders\" (keys(\"tags\"));"])
        }

        @Test("A plain column target is quoted")
        func plainTargetIsQuoted() {
            let sql = render([["orders_day_idx", "COMPOSITES", "{target: day}"]])
            #expect(sql == ["CREATE INDEX \"orders_day_idx\" ON \"app\".\"orders\" (\"day\");"])
        }

        @Test("A target carrying a statement terminator stays inside its quotes")
        func hostileTargetCannotEndTheStatement() {
            let sql = render([["idx", "COMPOSITES", "{target: a); DROP KEYSPACE app; --}"]])
            let statement = try? #require(sql.first)
            #expect(sql.count == 1)
            #expect(statement?.contains("DROP KEYSPACE") == true)
            #expect(statement?.hasSuffix(");") == true)
            #expect(statement?.contains("(\"a); DROP KEYSPACE app; --\")") == true)
        }

        @Test("A double quote inside a target is doubled rather than closing the identifier")
        func quoteInTargetIsEscaped() {
            let quoted = CassandraIndexStatements.quotedTarget(
                "a\"b", quote: { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" })
            #expect(quoted == "\"a\"\"b\"")
        }

        @Test("A target read out of a multi-entry options map stops at the entry separator")
        func targetStopsAtTheSeparator() {
            #expect(CassandraIndexStatements.target(fromOptions: "{target: day, other: x}") == "day")
        }

        @Test("An index with no target is left out")
        func missingTargetIsSkipped() {
            #expect(render([["orders_idx", "COMPOSITES", "{}"]]).isEmpty)
        }
    }
}
