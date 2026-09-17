//
//  MySQLIndexGroupingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("MySQL index rows are grouped in the order the server sent them")
struct MySQLIndexGroupingTests {
    private func row(
        _ index: String,
        _ column: String,
        table: String = "orders",
        isNonUnique: Bool = true,
        prefixLength: Int? = nil
    ) -> MySQLIndexRow {
        MySQLIndexRow(
            table: table,
            index: index,
            column: column,
            isNonUnique: isNonUnique,
            type: "BTREE",
            prefixLength: prefixLength
        )
    }

    /// Compare & Sync reads a table twice, once to compare and once before writing the script, and
    /// refuses the script when the two reads differ. A read that listed the same indexes in a new
    /// order every time refused a table nobody had touched.
    @Test("Indexes keep the order their first row arrived in, on every read")
    func indexesKeepArrivalOrder() {
        let secondary = [
            "orders_total_idx", "orders_country_idx", "orders_created_idx", "orders_status_idx",
            "orders_customer_idx", "orders_shipped_idx", "orders_channel_idx", "orders_currency_idx"
        ]
        let rows = [row("PRIMARY", "id", isNonUnique: false)]
            + secondary.map { row($0, "total") }
            + [row("orders_total_idx", "country")]

        for _ in 0..<20 {
            #expect(MySQLIndexGrouping.group(rows)["orders"]?.map(\.name) == ["PRIMARY"] + secondary)
        }
    }

    /// `INFORMATION_SCHEMA.STATISTICS` is ordered by `INDEX_NAME` under a case-insensitive
    /// collation, so `PRIMARY` arrives between the other names rather than first.
    @Test("The primary key is listed first wherever its rows arrived")
    func primaryKeyLeads() {
        let rows = [
            row("orders_country_idx", "country"),
            row("PRIMARY", "id", isNonUnique: false),
            row("orders_total_idx", "total")
        ]

        #expect(
            MySQLIndexGrouping.group(rows)["orders"]?.map(\.name)
                == ["PRIMARY", "orders_country_idx", "orders_total_idx"]
        )
    }

    @Test("A composite index keeps its column order, prefixes and uniqueness")
    func compositeIndexKeepsItsShape() throws {
        let rows = [
            row("orders_note_idx", "region_id", isNonUnique: false),
            row("orders_note_idx", "note", isNonUnique: false, prefixLength: 32),
            row("regions_name_idx", "name", table: "regions")
        ]

        let grouped = MySQLIndexGrouping.group(rows)
        let index = try #require(grouped["orders"]?.first)
        #expect(index.columns == ["region_id", "note"])
        #expect(index.columnPrefixes == ["note": 32])
        #expect(index.isUnique)
        #expect(!index.isPrimary)
        #expect(grouped["regions"]?.map(\.name) == ["regions_name_idx"])
    }
}
