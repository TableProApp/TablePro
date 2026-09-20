//
//  SQLiteForeignKeyParentsTests.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

/// `PRAGMA foreign_key_list` reports a null target column for a shorthand `REFERENCES parent`, so
/// the parent's own primary key has to be fetched before the rows can be grouped. The single-table
/// read asked for it and the bulk read did not, and nothing made the two agree. Both now name the
/// parents through this.
@Suite("SQLite Foreign Key Parents")
struct SQLiteForeignKeyParentsTests {
    /// A `PRAGMA foreign_key_list` row with the table name already stripped: id, seq, table, from,
    /// to, on_update, on_delete.
    private func row(table: String, from: String, to: PluginCellValue = .null) -> [PluginCellValue] {
        [.text("0"), .text("0"), .text(table), .text(from), to, .text("NO ACTION"), .text("NO ACTION")]
    }

    @Test("Every referenced table is named")
    func namesEveryReferencedTable() {
        let rows = [row(table: "parent", from: "pid"), row(table: "other", from: "oid")]
        #expect(SQLiteForeignKeyParents.referencedTables(in: rows) == ["parent", "other"])
    }

    /// The same parent twice is two keys pointing at it, and the caller turns the list into a set
    /// before it queries, so repeats cost nothing and dropping them here would hide a real row.
    @Test("A parent referenced twice is named twice")
    func repeatsAreKept() {
        let rows = [row(table: "parent", from: "a"), row(table: "parent", from: "b")]
        #expect(SQLiteForeignKeyParents.referencedTables(in: rows) == ["parent", "parent"])
    }

    @Test("A row with no referenced table is skipped rather than answered as empty")
    func malformedRowIsSkipped() {
        let short: [PluginCellValue] = [.text("0"), .text("0")]
        #expect(SQLiteForeignKeyParents.referencedTables(in: [short]).isEmpty)
        #expect(SQLiteForeignKeyParents.referencedTables(in: [[]]).isEmpty)
    }

    @Test("A table with no foreign keys names no parent")
    func noRowsNameNoParents() {
        #expect(SQLiteForeignKeyParents.referencedTables(in: [[PluginCellValue]]()).isEmpty)
    }

    /// The bulk read groups its rows by child table first, and every parent across the whole
    /// database has to reach the one query it runs.
    @Test("The bulk shape names the parents of every child table")
    func bulkShapeNamesEveryParent() {
        let rowsByTable = [
            "orders": [row(table: "customer", from: "customer_id")],
            "items": [row(table: "orders", from: "order_id"), row(table: "product", from: "product_id")],
        ]
        #expect(
            Set(SQLiteForeignKeyParents.referencedTables(in: rowsByTable))
                == ["customer", "orders", "product"]
        )
    }

    @Test("A database with no foreign keys names no parent")
    func emptyBulkShapeNamesNoParents() {
        #expect(SQLiteForeignKeyParents.referencedTables(in: [String: [[PluginCellValue]]]()).isEmpty)
    }

    /// The end the fix exists for: the parent column the grouping resolves is the parent's primary
    /// key, and it only gets there when the caller named the parent first.
    @Test("The named parents resolve the target column the pragma left null")
    func namedParentsResolveTheTargetColumn() {
        let rows = [row(table: "alimenti", from: "alimento_id")]
        let parents = SQLiteForeignKeyParents.referencedTables(in: rows)
        let infos = SQLiteForeignKeyGrouping.infos(
            table: "prezzi",
            pragmaRows: rows,
            createTableSQL: nil,
            primaryKeysByTable: Dictionary(uniqueKeysWithValues: parents.map { ($0, ["id"]) })
        )
        #expect(infos.map(\.referencedColumn) == ["id"])

        let unresolved = SQLiteForeignKeyGrouping.infos(
            table: "prezzi",
            pragmaRows: rows,
            createTableSQL: nil
        )
        #expect(unresolved.map(\.referencedColumn) == ["alimento_id"])
    }
}
