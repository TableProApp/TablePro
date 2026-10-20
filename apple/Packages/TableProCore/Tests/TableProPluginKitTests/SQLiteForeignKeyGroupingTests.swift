//
//  SQLiteForeignKeyGroupingTests.swift
//  TableProPluginKitTests
//

import Foundation
import TableProPluginKit
import Testing

struct SQLiteForeignKeyGroupingTests {
    // id, seq, table, from, to, on_update, on_delete, match
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

    // The pragma numbers keys in reverse declaration order.
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

    @Test("An omitted parent column comes from the parent's primary key")
    func resolvesAnOmittedParentColumn() {
        let infos = SQLiteForeignKeyGrouping.infos(
            table: "t",
            pragmaRows: [[.text("0"), .text("0"), .text("p"), .text("pid"), .null, .text("NO ACTION"), .text("NO ACTION")]],
            createTableSQL: "CREATE TABLE t(pid INT REFERENCES p)",
            primaryKeysByTable: ["p": ["id"]]
        )
        #expect(infos.count == 1)
        #expect(infos[0].referencedColumn == "id")
    }

    @Test("A composite omitted parent key resolves in key order")
    func resolvesACompositeOmittedParentKey() {
        let infos = SQLiteForeignKeyGrouping.infos(
            table: "t",
            pragmaRows: [
                [.text("0"), .text("0"), .text("p"), .text("a"), .null, .text("NO ACTION"), .text("NO ACTION")],
                [.text("0"), .text("1"), .text("p"), .text("b"), .null, .text("NO ACTION"), .text("NO ACTION")]
            ],
            createTableSQL: nil,
            primaryKeysByTable: ["p": ["x", "y"]]
        )
        #expect(infos.map(\.referencedColumn) == ["x", "y"])
    }

    @Test("Colliding declared names fall back to the positional name")
    func fallsBackWhenDeclaredNamesCollide() {
        let infos = SQLiteForeignKeyGrouping.infos(
            table: "t",
            pragmaRows: [
                row(id: 0, seq: 0, table: "p", from: "a", to: "id"),
                row(id: 1, seq: 0, table: "p", from: "b", to: "id")
            ],
            createTableSQL: """
                CREATE TABLE t(a INT, b INT,
                  CONSTRAINT same FOREIGN KEY (a) REFERENCES p (id),
                  CONSTRAINT same FOREIGN KEY (b) REFERENCES p (id))
                """
        )
        #expect(Set(infos.map(\.name)) == ["fk_t_0", "fk_t_1"])
    }

    // b is declared second, so the pragma numbers it 0 and its positional name is the one a declares.
    @Test("A declared name equal to another key's positional name keeps the two keys apart")
    func declaredNameSpellingAPositionalName() {
        let infos = SQLiteForeignKeyGrouping.infos(
            table: "orders",
            pragmaRows: [
                row(id: 0, seq: 0, table: "p", from: "b", to: "id"),
                row(id: 1, seq: 0, table: "p", from: "a", to: "id")
            ],
            createTableSQL: """
                CREATE TABLE orders(a INT, b INT,
                  CONSTRAINT fk_orders_0 FOREIGN KEY (a) REFERENCES p (id),
                  FOREIGN KEY (b) REFERENCES p (id))
                """
        )
        #expect(infos.first { $0.column == "a" }?.name == "fk_orders_0")
        #expect(infos.first { $0.column == "b" }?.name == "fk_orders_0_2")
    }

    @Test("A positional name skips every suffix another key already uses")
    func positionalNameSkipsTakenSuffixes() {
        let infos = SQLiteForeignKeyGrouping.infos(
            table: "t",
            pragmaRows: [
                row(id: 0, seq: 0, table: "p", from: "c", to: "id"),
                row(id: 1, seq: 0, table: "p", from: "b", to: "id"),
                row(id: 2, seq: 0, table: "p", from: "a", to: "id")
            ],
            createTableSQL: """
                CREATE TABLE t(a INT, b INT, c INT,
                  CONSTRAINT fk_t_0 FOREIGN KEY (a) REFERENCES p (id),
                  CONSTRAINT fk_t_0_2 FOREIGN KEY (b) REFERENCES p (id),
                  FOREIGN KEY (c) REFERENCES p (id))
                """
        )
        #expect(infos.map(\.name) == ["fk_t_0_3", "fk_t_0_2", "fk_t_0"])
    }

    @Test("Colliding declared names fall back without taking a third key's declared name")
    func duplicateDeclaredNamesAvoidAThirdKeysName() {
        let infos = SQLiteForeignKeyGrouping.infos(
            table: "t",
            pragmaRows: [
                row(id: 0, seq: 0, table: "p", from: "c", to: "id"),
                row(id: 1, seq: 0, table: "p", from: "b", to: "id"),
                row(id: 2, seq: 0, table: "p", from: "a", to: "id")
            ],
            createTableSQL: """
                CREATE TABLE t(a INT, b INT, c INT,
                  CONSTRAINT dup FOREIGN KEY (a) REFERENCES p (id),
                  CONSTRAINT dup FOREIGN KEY (b) REFERENCES p (id),
                  CONSTRAINT fk_t_1 FOREIGN KEY (c) REFERENCES p (id))
                """
        )
        #expect(infos.first { $0.column == "c" }?.name == "fk_t_1")
        #expect(Set(infos.map(\.name)).count == 3)
    }

    @Test("Two keys from one column to different parent columns keep their own names")
    func matchesOnExplicitParentColumns() {
        let infos = SQLiteForeignKeyGrouping.infos(
            table: "t",
            pragmaRows: [
                row(id: 0, seq: 0, table: "p", from: "x", to: "b"),
                row(id: 1, seq: 0, table: "p", from: "x", to: "a")
            ],
            createTableSQL: """
                CREATE TABLE t(x INT,
                  CONSTRAINT to_a FOREIGN KEY (x) REFERENCES p (a),
                  CONSTRAINT to_b FOREIGN KEY (x) REFERENCES p (b))
                """
        )
        #expect(infos.first { $0.referencedColumn == "a" }?.name == "to_a")
        #expect(infos.first { $0.referencedColumn == "b" }?.name == "to_b")
    }

    // The pragma reports the two in reverse, so matching on the relationship alone swapped the names.
    @Test("Two keys on one relationship with different actions keep their own names")
    func matchesOnActions() {
        let infos = SQLiteForeignKeyGrouping.infos(
            table: "t",
            pragmaRows: [
                row(id: 0, seq: 0, table: "p", from: "x", to: "id", onDelete: "CASCADE"),
                row(id: 1, seq: 0, table: "p", from: "x", to: "id", onDelete: "RESTRICT")
            ],
            createTableSQL: """
                CREATE TABLE t(x INT,
                  CONSTRAINT restrict_key FOREIGN KEY (x) REFERENCES p (id) ON DELETE RESTRICT,
                  CONSTRAINT cascade_key FOREIGN KEY (x) REFERENCES p (id) ON DELETE CASCADE)
                """
        )
        #expect(infos.first { $0.onDelete == "RESTRICT" }?.name == "restrict_key")
        #expect(infos.first { $0.onDelete == "CASCADE" }?.name == "cascade_key")
    }

    @Test("Keys the DDL cannot tell apart keep positional names")
    func indistinguishableKeysStayPositional() {
        let infos = SQLiteForeignKeyGrouping.infos(
            table: "t",
            pragmaRows: [
                row(id: 0, seq: 0, table: "p", from: "x", to: "id"),
                row(id: 1, seq: 0, table: "p", from: "x", to: "id")
            ],
            createTableSQL: """
                CREATE TABLE t(x INT,
                  CONSTRAINT first_key FOREIGN KEY (x) REFERENCES p (id),
                  CONSTRAINT second_key FOREIGN KEY (x) REFERENCES p (id))
                """
        )
        #expect(infos.map(\.name) == ["fk_t_0", "fk_t_1"])
    }

    // The shorthand clause fits both keys, the explicit one only its own, so taking the explicit first settles both.
    @Test("A clause that fits several keys is settled once the others are taken")
    func eliminatesAmbiguousClauses() {
        let infos = SQLiteForeignKeyGrouping.infos(
            table: "t",
            pragmaRows: [
                row(id: 0, seq: 0, table: "p", from: "x", to: "id"),
                row(id: 1, seq: 0, table: "p", from: "x", to: "code")
            ],
            createTableSQL: """
                CREATE TABLE t(x INT,
                  CONSTRAINT to_code FOREIGN KEY (x) REFERENCES p (code),
                  CONSTRAINT to_key FOREIGN KEY (x) REFERENCES p)
                """
        )
        #expect(infos.first { $0.referencedColumn == "code" }?.name == "to_code")
        #expect(infos.first { $0.referencedColumn == "id" }?.name == "to_key")
    }

    @Test("A table with no foreign keys reports none")
    func handlesNoKeys() {
        #expect(
            SQLiteForeignKeyGrouping.infos(table: "t", pragmaRows: [], createTableSQL: nil).isEmpty
        )
    }

    // table, then the pragma row, then the DDL on the table's first row only.
    private func listRow(table: String, _ pragma: [PluginCellValue], sql: String? = nil) -> [PluginCellValue] {
        [.text(table)] + pragma + [sql.map(PluginCellValue.text) ?? .null]
    }

    @Test("List rows group by table and read each table's DDL from its first row")
    func groupsListRowsByTable() {
        let rows = [
            listRow(
                table: "orders",
                row(id: 0, seq: 0, table: "customers", from: "customer_id", to: "id"),
                sql: """
                    CREATE TABLE orders(customer_id INT,
                      CONSTRAINT fk_orders_customer FOREIGN KEY (customer_id) REFERENCES customers (id))
                    """
            ),
            listRow(table: "items", row(id: 0, seq: 0, table: "p", from: "a", to: "x"), sql: "CREATE TABLE items(a, b)"),
            listRow(table: "items", row(id: 0, seq: 1, table: "p", from: "b", to: "y"))
        ]

        let byTable = SQLiteForeignKeyGrouping.foreignKeysByTable(fromRows: rows)

        #expect(byTable["orders"]?.map(\.name) == ["fk_orders_customer"])
        #expect(byTable["items"]?.map(\.name) == ["fk_items_0", "fk_items_0"])
        #expect(byTable["items"]?.map(\.referencedColumn) == ["x", "y"])
    }

    @Test("A single table's rows carry no table name and take the one asked for")
    func readsOneTablesRows() {
        let rows = [
            row(id: 0, seq: 0, table: "p", from: "a", to: "x") + [.text("CREATE TABLE t(a, b)")],
            row(id: 0, seq: 1, table: "p", from: "b", to: "y") + [.null]
        ]

        let keys = SQLiteForeignKeyGrouping.foreignKeys(table: "t", fromRows: rows)

        #expect(keys.map(\.name) == ["fk_t_0", "fk_t_0"])
        #expect(keys.map(\.referencedColumn) == ["x", "y"])
    }

    @Test("Short list rows are skipped")
    func skipsShortListRows() {
        #expect(SQLiteForeignKeyGrouping.foreignKeys(table: "t", fromRows: [[.text("0"), .text("0")]]).isEmpty)
        #expect(SQLiteForeignKeyGrouping.foreignKeysByTable(fromRows: [[.text("t"), .text("0")]]).isEmpty)
    }
}
