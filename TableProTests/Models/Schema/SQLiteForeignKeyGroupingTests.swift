//
//  SQLiteForeignKeyGroupingTests.swift
//  TablePro
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

/// `PRAGMA foreign_key_list` reports no constraint name, so a key declared as
/// `CONSTRAINT fk_orders_customer …` used to read back as the positional `fk_orders_0` and the name
/// the user typed was lost on the next read. The name comes from the stored `CREATE TABLE` text and
/// the resolved columns come from the pragma, matched on the relationship each describes.
@Suite("SQLite Foreign Key Grouping")
struct SQLiteForeignKeyGroupingTests {
    /// A `PRAGMA foreign_key_list` row: id, seq, table, from, to, on_update, on_delete, match.
    private func row(
        id: Int, seq: Int, table: String, from: String, to: String,
        onUpdate: String = "NO ACTION", onDelete: String = "NO ACTION"
    ) -> [PluginCellValue] {
        [
            .text("\(id)"), .text("\(seq)"), .text(table), .text(from), .text(to),
            .text(onUpdate), .text(onDelete), .text("NONE")
        ]
    }

    @Test("A named key reports the name the DDL gave it")
    func recoversTheDeclaredName() {
        let infos = SQLiteForeignKeyGrouping.infos(
            table: "orders",
            pragmaRows: [row(id: 0, seq: 0, table: "customers", from: "customer_id", to: "id")],
            createTableSQL: """
                CREATE TABLE orders(id INTEGER PRIMARY KEY, customer_id INTEGER,
                  CONSTRAINT fk_orders_customer FOREIGN KEY (customer_id) REFERENCES customers (id))
                """
        )
        #expect(infos.count == 1)
        #expect(infos[0].name == "fk_orders_customer")
        #expect(infos[0].column == "customer_id")
        #expect(infos[0].referencedTable == "customers")
    }

    /// An unnamed key still needs a stable identifier for the editor to group and address it by, so
    /// the positional one is kept for exactly that case.
    @Test("An unnamed key keeps the positional name")
    func fallsBackToThePositionalName() {
        let infos = SQLiteForeignKeyGrouping.infos(
            table: "orders",
            pragmaRows: [row(id: 3, seq: 0, table: "customers", from: "customer_id", to: "id")],
            createTableSQL: "CREATE TABLE orders(customer_id INTEGER REFERENCES customers(id))"
        )
        #expect(infos[0].name == "fk_orders_3")
    }

    @Test("A table whose DDL could not be read still reports its keys")
    func worksWithoutTheStoredStatement() {
        let infos = SQLiteForeignKeyGrouping.infos(
            table: "orders",
            pragmaRows: [row(id: 0, seq: 0, table: "customers", from: "customer_id", to: "id")],
            createTableSQL: nil
        )
        #expect(infos.count == 1)
        #expect(infos[0].name == "fk_orders_0")
    }

    /// A composite key is several pragma rows sharing one id. They have to come back under one name
    /// or the editor shows them as separate single-column keys.
    @Test("A composite key comes back as one key with every column pair")
    func groupsACompositeKey() {
        let infos = SQLiteForeignKeyGrouping.infos(
            table: "t",
            pragmaRows: [
                row(id: 0, seq: 0, table: "p", from: "a", to: "x"),
                row(id: 0, seq: 1, table: "p", from: "b", to: "y")
            ],
            createTableSQL: """
                CREATE TABLE t(a INT, b INT, CONSTRAINT composite FOREIGN KEY (a, b) REFERENCES p (x, y))
                """
        )
        #expect(infos.count == 2)
        #expect(Set(infos.map(\.name)) == ["composite"])
        #expect(infos.map(\.column) == ["a", "b"])
        #expect(infos.map(\.referencedColumn) == ["x", "y"])
    }

    /// Measured on 3.54: the pragma numbers keys in reverse declaration order, so matching by
    /// position would give each key the other's name.
    @Test("Names are matched on the relationship, not on declaration order")
    func matchesByRelationshipNotPosition() {
        let infos = SQLiteForeignKeyGrouping.infos(
            table: "t",
            pragmaRows: [
                row(id: 0, seq: 0, table: "second", from: "b", to: "id"),
                row(id: 1, seq: 0, table: "first", from: "a", to: "id")
            ],
            createTableSQL: """
                CREATE TABLE t(
                  a INT, b INT,
                  CONSTRAINT to_first FOREIGN KEY (a) REFERENCES first (id),
                  CONSTRAINT to_second FOREIGN KEY (b) REFERENCES second (id)
                )
                """
        )
        #expect(infos.first { $0.column == "a" }?.name == "to_first")
        #expect(infos.first { $0.column == "b" }?.name == "to_second")
    }

    /// The DDL may omit the parent columns and the pragma always resolves them, so requiring them
    /// to agree would fail exactly the keys written in the shorter form.
    @Test("A reference with no column list still gets its name")
    func matchesAnImplicitParentKey() {
        let infos = SQLiteForeignKeyGrouping.infos(
            table: "t",
            pragmaRows: [row(id: 0, seq: 0, table: "p", from: "pid", to: "id")],
            createTableSQL: "CREATE TABLE t(pid INT CONSTRAINT implicit REFERENCES p)"
        )
        #expect(infos[0].name == "implicit")
        #expect(infos[0].referencedColumn == "id")
    }

    @Test("The referential actions come from the pragma")
    func readsActions() {
        let infos = SQLiteForeignKeyGrouping.infos(
            table: "t",
            pragmaRows: [
                row(id: 0, seq: 0, table: "p", from: "pid", to: "id", onUpdate: "CASCADE", onDelete: "SET NULL")
            ],
            createTableSQL: nil
        )
        #expect(infos[0].onUpdate == "CASCADE")
        #expect(infos[0].onDelete == "SET NULL")
    }

    @Test("A table with no foreign keys reports none")
    func handlesNoKeys() {
        #expect(
            SQLiteForeignKeyGrouping.infos(table: "t", pragmaRows: [], createTableSQL: nil).isEmpty
        )
    }
}
