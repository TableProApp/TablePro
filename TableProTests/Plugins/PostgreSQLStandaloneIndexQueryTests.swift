//
//  PostgreSQLStandaloneIndexQueryTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct PostgreSQLStandaloneIndexQueryTests {
    private static let sql = PostgreSQLIndexQueries.standaloneIndexQuery(schema: "shop", table: "orders")

    @Test("An index is restorable under pg_dump's rule: valid, or on a partitioned table, and ready")
    func restorableFollowsPgDump() {
        #expect(Self.sql.contains("((ix.indisvalid OR t.relkind = 'p') AND ix.indisready) AS is_restorable"))
    }

    @Test("Only an index a primary key, unique or exclusion constraint of this table owns is left to the table DDL")
    func constraintOwnershipNamesTheTableAndTheKind() {
        #expect(Self.sql.contains("con.conrelid = ix.indrelid"))
        #expect(Self.sql.contains("con.conindid = ix.indexrelid"))
        #expect(Self.sql.contains("con.contype IN ('p', 'u', 'x')"))
    }

    @Test("The read is scoped to one table in one schema and ordered by name")
    func scopedToOneTable() {
        #expect(Self.sql.contains("WHERE n.nspname = 'shop'"))
        #expect(Self.sql.contains("AND t.relname = 'orders'"))
        #expect(Self.sql.contains("pg_catalog.pg_get_indexdef(ix.indexrelid) AS definition"))
        #expect(Self.sql.hasSuffix("ORDER BY i.relname"))
    }

    @Test("Restorable definitions are kept in order and invalid indexes are named apart")
    func rowsSplitByRestorability() {
        let indexes = PostgreSQLIndexQueries.standaloneIndexes(rows: [
            [.text("orders_code_idx"), .text("CREATE INDEX orders_code_idx ON shop.orders USING btree (code)"), .text("t")],
            [.text("orders_code_key"), .text("CREATE UNIQUE INDEX orders_code_key ON shop.orders USING btree (code)"), .text("f")],
            [.text("orders_day_idx"), .text("CREATE INDEX orders_day_idx ON shop.orders USING btree (day)"), .text("t")],
            [.text("orders_code_idx_ccnew"), .text("CREATE INDEX orders_code_idx_ccnew ON shop.orders USING btree (code)"), .text("f")]
        ])
        #expect(indexes.definitions == [
            "CREATE INDEX orders_code_idx ON shop.orders USING btree (code)",
            "CREATE INDEX orders_day_idx ON shop.orders USING btree (day)"
        ])
        #expect(indexes.invalidNames == ["orders_code_key", "orders_code_idx_ccnew"])
    }

    @Test("A row with no name or no definition is skipped")
    func incompleteRowsAreSkipped() {
        let indexes = PostgreSQLIndexQueries.standaloneIndexes(rows: [
            [.null, .text("CREATE INDEX a ON shop.orders USING btree (a)"), .text("t")],
            [.text("b"), .null, .text("f")],
            [.text("c"), .text(""), .text("t")]
        ])
        #expect(indexes.definitions.isEmpty)
        #expect(indexes.invalidNames.isEmpty)
    }
}

struct PostgreSQLTableDDLConstraintsQueryTests {
    @Test("Exclusion constraints are written with the table, beside primary key, unique and check constraints")
    func exclusionConstraintsAreIncluded() {
        let sql = PostgreSQLSchemaQueries.tableDDLConstraintsQuery(schema: "shop", table: "bookings")
        #expect(sql.contains("con.contype IN ('p', 'u', 'c', 'x')"))
        #expect(sql.contains("CASE con.contype WHEN 'p' THEN 0 WHEN 'u' THEN 1 WHEN 'c' THEN 2 ELSE 3 END"))
        #expect(sql.contains("c.relname = 'bookings'"))
        #expect(sql.contains("n.nspname = 'shop'"))
    }
}
