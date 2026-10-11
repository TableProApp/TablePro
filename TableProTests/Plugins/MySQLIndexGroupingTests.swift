//
//  MySQLIndexGroupingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

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
            key: MySQLIndexKey(part: .column(column, prefixLength: prefixLength), isDescending: false),
            isNonUnique: isNonUnique,
            type: "BTREE"
        )
    }

    private func catalogRow(
        _ index: String,
        column: String?,
        expression: String? = nil,
        collation: String? = "A",
        type: String = "BTREE"
    ) -> MySQLIndexRow? {
        MySQLIndexRow(
            table: "t",
            index: index,
            column: column,
            catalogExpression: expression,
            prefixLength: nil,
            collation: collation,
            isNonUnique: index != "PRIMARY",
            type: type
        )
    }

    private func grouped(_ rows: [MySQLIndexRow?]) -> [String: PluginIndexInfo] {
        let indexes = MySQLIndexGrouping.group(rows.compactMap { $0 })["t"] ?? []
        return Dictionary(uniqueKeysWithValues: indexes.map { ($0.name, $0) })
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

    @Test("A functional key part is read from its expression, beside the plain columns")
    func functionalKeyPartsAreRead() throws {
        let indexes = grouped([
            catalogRow("PRIMARY", column: "id"),
            catalogRow("i_fn", column: nil, expression: "lower(`v`)", collation: "D"),
            catalogRow("i_mix", column: "id"),
            catalogRow("i_mix", column: nil, expression: "coalesce(`a`,`b`)")
        ])

        let function = try #require(indexes["i_fn"])
        #expect(function.columns == ["lower(`v`)"])
        #expect(function.expressions == ["lower(`v`)"])

        let mixed = try #require(indexes["i_mix"])
        #expect(mixed.columns == ["id", "coalesce(`a`,`b`)"])
        #expect(mixed.expressions == ["coalesce(`a`,`b`)"])
        #expect(mixed.ddlMethodAndKeys == nil)
    }

    @Test("The catalog's escaping is taken off an expression, which then reads as SHOW CREATE TABLE writes it")
    func catalogEscapingIsRemoved() throws {
        let raw = #"concat(`a`,_utf8mb4\'it\\\'s\',_utf8mb4\'\\\\n\',_utf8mb4\'x\\ny\')"#
        let index = try #require(grouped([catalogRow("i_q", column: nil, expression: raw)])["i_q"])
        #expect(index.expressions == [#"concat(`a`,_utf8mb4'it\'s',_utf8mb4'\\n',_utf8mb4'x\ny')"#])
    }

    @Test("A row with neither a column nor an expression is not a key part")
    func unreadableRowIsDropped() {
        #expect(catalogRow("i_fn", column: nil, expression: nil) == nil)
    }

    @Test("A descending key part is kept in the server's own key spelling")
    func descendingKeysAreSpelled() throws {
        let indexes = grouped([
            catalogRow("i_desc", column: "v", collation: "D"),
            catalogRow("i_desc", column: "id"),
            catalogRow("i_fn", column: nil, expression: "lower(`v`)", collation: "D"),
            catalogRow("i_ft", column: "body", collation: nil, type: "FULLTEXT")
        ])

        #expect(indexes["i_desc"]?.ddlMethodAndKeys == "(`v` DESC, `id`) USING BTREE")
        #expect(indexes["i_fn"]?.ddlMethodAndKeys == "((lower(`v`)) DESC) USING BTREE")
        #expect(indexes["i_ft"]?.ddlMethodAndKeys == nil)
    }
}
