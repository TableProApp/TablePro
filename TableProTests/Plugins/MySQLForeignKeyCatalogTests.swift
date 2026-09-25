//
//  MySQLForeignKeyCatalogTests.swift
//  TableProTests
//
//  The merge that replaced a server-side join of KEY_COLUMN_USAGE and REFERENTIAL_CONSTRAINTS.
//

import Foundation
import TableProPluginKit
import Testing

struct MySQLForeignKeyCatalogTests {
    private func column(
        _ table: String,
        _ constraint: String,
        _ column: String,
        referencedSchema: String? = "db1",
        referencedTable: String = "t_parent",
        referencedColumn: String
    ) -> MySQLForeignKeyCatalog.ColumnRow {
        MySQLForeignKeyCatalog.ColumnRow(
            table: table,
            constraint: constraint,
            column: column,
            referencedSchema: referencedSchema,
            referencedTable: referencedTable,
            referencedColumn: referencedColumn
        )
    }

    private func action(
        _ table: String,
        _ constraint: String,
        onDelete: String,
        onUpdate: String
    ) -> MySQLForeignKeyCatalog.ActionRow {
        MySQLForeignKeyCatalog.ActionRow(
            table: table, constraint: constraint, onDelete: onDelete, onUpdate: onUpdate
        )
    }

    /// The read orders by `ORDINAL_POSITION`, and the merge must not reorder what it was handed.
    /// Measured on MariaDB 11.4.13: ordering by `CONSTRAINT_NAME` alone answers a two-column key
    /// as `p_tenant` then `p_id`, which is the order the declaration does not have.
    @Test("Column order is the order the rows arrived in")
    func keepsRowOrder() {
        let grouped = MySQLForeignKeyCatalog.group(
            columnRows: [
                column("t_child", "fk", "p_id", referencedColumn: "id"),
                column("t_child", "fk", "p_tenant", referencedColumn: "tenant")
            ],
            actionRows: [action("t_child", "fk", onDelete: "CASCADE", onUpdate: "SET NULL")],
            defaultAction: "NO ACTION"
        )

        #expect(grouped["t_child"]?.map(\.column) == ["p_id", "p_tenant"])
        #expect(grouped["t_child"]?.map(\.referencedColumn) == ["id", "tenant"])
        #expect(grouped["t_child"]?.allSatisfy { $0.onDelete == "CASCADE" && $0.onUpdate == "SET NULL" } == true)
    }

    @Test("Two constraints on one table stay separate")
    func twoConstraintsOnOneTable() {
        let grouped = MySQLForeignKeyCatalog.group(
            columnRows: [
                column("t_child", "fk_parent", "p_id", referencedColumn: "id"),
                column("t_child", "fk_remote", "remote_code", referencedTable: "t_remote", referencedColumn: "code")
            ],
            actionRows: [
                action("t_child", "fk_parent", onDelete: "CASCADE", onUpdate: "CASCADE"),
                action("t_child", "fk_remote", onDelete: "SET NULL", onUpdate: "RESTRICT")
            ],
            defaultAction: "NO ACTION"
        )

        #expect(grouped["t_child"]?.map(\.name) == ["fk_parent", "fk_remote"])
        #expect(grouped["t_child"]?.map(\.onDelete) == ["CASCADE", "SET NULL"])
    }

    /// The inner join this replaced dropped such a row entirely. Every server measured answers both
    /// catalogs or neither, so this only differs on a proxy that answers one of them.
    @Test("A column row with no action row keeps its key and takes the default")
    func missingActionRowKeepsTheKey() {
        let grouped = MySQLForeignKeyCatalog.group(
            columnRows: [column("t_child", "fk", "p_id", referencedColumn: "id")],
            actionRows: [],
            defaultAction: "RESTRICT"
        )

        #expect(grouped["t_child"]?.map(\.name) == ["fk"])
        #expect(grouped["t_child"]?.first?.onDelete == "RESTRICT")
        #expect(grouped["t_child"]?.first?.onUpdate == "RESTRICT")
    }

    @Test("A cross-database reference keeps the schema the catalog named")
    func crossDatabaseReference() {
        let grouped = MySQLForeignKeyCatalog.group(
            columnRows: [
                column(
                    "t_child", "fk_remote", "remote_code",
                    referencedSchema: "db2", referencedTable: "t_remote", referencedColumn: "code"
                )
            ],
            actionRows: [action("t_child", "fk_remote", onDelete: "SET NULL", onUpdate: "CASCADE")],
            defaultAction: "NO ACTION"
        )

        #expect(grouped["t_child"]?.first?.referencedSchema == "db2")
        #expect(grouped["t_child"]?.first?.referencedTable == "t_remote")
    }

    /// A constraint name is unique per database, not per table, but the pair is what names one key
    /// on both sides, so the same name on two tables cannot take the other's actions.
    @Test("The same constraint name on two tables is two keys")
    func sameNameOnTwoTables() {
        let grouped = MySQLForeignKeyCatalog.group(
            columnRows: [
                column("orders", "fk", "customer_id", referencedColumn: "id"),
                column("invoices", "fk", "customer_id", referencedColumn: "id")
            ],
            actionRows: [
                action("orders", "fk", onDelete: "CASCADE", onUpdate: "CASCADE"),
                action("invoices", "fk", onDelete: "SET NULL", onUpdate: "SET NULL")
            ],
            defaultAction: "NO ACTION"
        )

        #expect(grouped["orders"]?.first?.onDelete == "CASCADE")
        #expect(grouped["invoices"]?.first?.onDelete == "SET NULL")
    }

    // MARK: - One table out of the grouped answer

    /// Measured on MySQL 8.4.11 and MariaDB 11.4.13 with `lower_case_table_names = 1`: a table
    /// created as `OrderLines` is stored as `orderlines`, and `KEY_COLUMN_USAGE` asked for
    /// `TABLE_NAME = 'OrderLines'` answers rows carrying `orderlines`. `SHOW FULL COLUMNS` and
    /// `SHOW INDEX` both answer the caller's spelling, so the keys were the only thing lost.
    @Test("A table the server spells differently still finds its keys")
    func caseFoldedTableStillResolves() {
        let grouped = MySQLForeignKeyCatalog.group(
            columnRows: [column("orderlines", "fk_ol", "order_id", referencedColumn: "id")],
            actionRows: [action("orderlines", "fk_ol", onDelete: "CASCADE", onUpdate: "CASCADE")],
            defaultAction: "NO ACTION"
        )

        #expect(MySQLForeignKeyCatalog.keys(for: "OrderLines", in: grouped).map(\.name) == ["fk_ol"])
        #expect(MySQLForeignKeyCatalog.keys(for: "orderlines", in: grouped).map(\.name) == ["fk_ol"])
    }

    /// The single group is taken because the read named one table. An answer holding two tables is
    /// not that read, so a name it does not carry gets nothing rather than another table's keys.
    @Test("A miss across several tables answers nothing")
    func severalGroupsNeverGuess() {
        let grouped = MySQLForeignKeyCatalog.group(
            columnRows: [
                column("orders", "fk_o", "customer_id", referencedColumn: "id"),
                column("invoices", "fk_i", "customer_id", referencedColumn: "id")
            ],
            actionRows: [],
            defaultAction: "NO ACTION"
        )

        #expect(MySQLForeignKeyCatalog.keys(for: "OrderLines", in: grouped).isEmpty)
        #expect(MySQLForeignKeyCatalog.keys(for: "orders", in: grouped).map(\.name) == ["fk_o"])
    }

    @Test("A table with no keys answers nothing")
    func emptyAnswerStaysEmpty() {
        #expect(MySQLForeignKeyCatalog.keys(for: "orders", in: [:]).isEmpty)
    }
}
