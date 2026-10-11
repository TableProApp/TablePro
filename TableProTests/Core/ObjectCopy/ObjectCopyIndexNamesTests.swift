//
//  ObjectCopyIndexNamesTests.swift
//  TableProTests
//
//  The names a copy gives the indexes it creates, where the target keeps one namespace of index
//  names per schema and the source kept one per table.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct ObjectCopyIndexNamesTests {
    private static func index(_ name: String, primary: Bool = false) -> EditableIndexDefinition {
        EditableIndexDefinition(
            id: UUID(), name: name, columns: ["user_id"], type: .btree, isUnique: false, isPrimary: primary,
            comment: nil, columnPrefixes: [:], whereClause: nil
        )
    }

    private static func table(_ name: String, _ indexes: [String]) -> TableStructureSnapshot {
        TableStructureSnapshot(
            name: name,
            columns: [EditableColumnDefinition(
                id: UUID(), name: "user_id", dataType: "INT", isNullable: true, defaultValue: nil,
                autoIncrement: false, unsigned: false, comment: nil, collation: nil, onUpdate: nil,
                charset: nil, extra: nil, isPrimaryKey: false
            )],
            indexes: indexes.map { index($0) }
        )
    }

    private static func placed(
        _ tables: [TableStructureSnapshot],
        besides existing: [String] = [],
        from source: DatabaseType,
        to target: DatabaseType
    ) -> [TableStructureSnapshot] {
        var taken = NewTableNaming.comparisonKeys(for: existing)
        return ObjectCopyIndexNames.placed(tables, avoiding: &taken, from: source, to: target)
    }

    private static func names(_ tables: [TableStructureSnapshot]) -> [[String]] {
        tables.map { $0.indexes.map(\.name) }
    }

    @Test("MariaDB's per-table user_id indexes get a name each in one PostgreSQL schema")
    func perTableNamesBecomeUniqueInPostgres() {
        let placed = Self.placed(
            [
                Self.table("activity_log", ["user_id"]),
                Self.table("orders", ["user_id"]),
                Self.table("reviews", ["user_id", "product_id"])
            ],
            from: .mariadb,
            to: .postgresql
        )
        #expect(Self.names(placed) == [
            ["activity_log_user_id"], ["orders_user_id"], ["reviews_user_id", "reviews_product_id"]
        ])
    }

    @Test("A table copied alone gets the same index name it gets beside the others")
    func nameDoesNotDependOnTheOtherTables() {
        let alone = Self.placed([Self.table("orders", ["user_id"])], from: .mysql, to: .postgresql)
        #expect(Self.names(alone) == [["orders_user_id"]])
    }

    @Test("An index that already names its table keeps its name")
    func nameThatSaysItsTableIsKept() {
        let placed = Self.placed(
            [Self.table("orders", ["idx_orders_created_at", "orders_user_id", "by_user_orders", "ordersx"])],
            from: .mysql,
            to: .postgresql
        )
        #expect(Self.names(placed) == [
            ["idx_orders_created_at", "orders_user_id", "by_user_orders", "orders_ordersx"]
        ])
    }

    @Test("SQLite, DuckDB and Oracle share the schema-wide rule; SQL Server and MySQL targets keep names")
    func targetsFollowTheirOwnScope() {
        let tables = [Self.table("orders", ["user_id"]), Self.table("reviews", ["user_id"])]
        for target in [DatabaseType.sqlite, .duckdb, .oracle, .pglite] {
            #expect(Self.names(Self.placed(tables, from: .mysql, to: target))
                == [["orders_user_id"], ["reviews_user_id"]])
        }
        for target in [DatabaseType.mssql, .mysql, .cockroachdb, .clickhouse] {
            #expect(Self.placed(tables, from: .mariadb, to: target) == tables)
        }
    }

    @Test("SQL Server and CockroachDB scope index names to the table too")
    func otherPerTableSourcesArePrefixed() {
        let tables = [Self.table("orders", ["user_id"]), Self.table("reviews", ["user_id"])]
        for source in [DatabaseType.mssql, .cockroachdb] {
            #expect(Self.names(Self.placed(tables, from: source, to: .postgresql))
                == [["orders_user_id"], ["reviews_user_id"]])
        }
    }

    @Test("A copy within one engine keeps every name the target schema does not hold")
    func sameEngineKeepsItsNames() {
        let tables = [
            Self.table("orders", ["orders_user_id_idx"]),
            Self.table("reviews", ["reviews_user_id_idx"])
        ]
        #expect(Self.placed(tables, from: .postgresql, to: .postgresql) == tables)
        #expect(Self.placed(tables, from: .sqlite, to: .sqlite) == tables)
        #expect(Self.placed(tables, from: .mysql, to: .mysql) == tables)
    }

    @Test("A copy within one engine renames an index the target schema already holds on another table")
    func sameEngineAvoidsAnExistingIndex() {
        var taken = ObjectCopyIndexNames.kept(["orders_2023": ["orders_user_id_idx"]], droppingFirst: [])
        let placed = ObjectCopyIndexNames.placed(
            [Self.table("orders", ["orders_user_id_idx"])], avoiding: &taken, from: .postgresql, to: .postgresql
        )
        #expect(Self.names(placed) == [["orders_user_id_idx_2"]])
    }

    @Test("Two schemas of one PostgreSQL database copied into one schema keep their indexes apart")
    func sameEngineScopesLandingInOneSchemaShareTheirNames() {
        var taken = Set<String>()
        let sales = ObjectCopyIndexNames.placed(
            [Self.table("orders", ["user_id"])], avoiding: &taken, from: .postgresql, to: .postgresql
        )
        let crm = ObjectCopyIndexNames.placed(
            [Self.table("contacts", ["user_id"])], avoiding: &taken, from: .postgresql, to: .postgresql
        )
        #expect(Self.names(sales) == [["user_id"]])
        #expect(Self.names(crm) == [["user_id_2"]])
    }

    @Test("A copy within Oracle keeps a name past the 30 bytes a made-up name is cut to")
    func sameEngineKeepsTheLengthTheSourceAccepted() {
        let long = "IDX_CUSTOMER_SUBSCRIPTION_BILLING_HISTORY"
        let tables = [Self.table("CUSTOMER_SUBSCRIPTIONS", [long])]
        #expect(Self.names(Self.placed(tables, from: .oracle, to: .oracle)) == [[long]])
    }

    @Test("A source whose names are already schema-wide keeps them, unless one is named like a table")
    func schemaWideSourceIsOnlyDisambiguated() {
        let placed = Self.placed(
            [Self.table("ORDER_ITEMS", ["ORDERS", "ITEMS_BY_USER"])],
            besides: ["ORDERS"],
            from: .oracle,
            to: .postgresql
        )
        #expect(Self.names(placed) == [["ORDERS_2", "ITEMS_BY_USER"]])
    }

    @Test("A name the target schema already holds is not given to an index")
    func existingTargetObjectIsAvoided() {
        let placed = Self.placed(
            [Self.table("orders", ["user_id"])], besides: ["Orders_User_Id"], from: .mysql, to: .postgresql
        )
        #expect(Self.names(placed) == [["orders_user_id_2"]])
    }

    @Test("An index on a target table outside the copy keeps its name, and the copy's takes a number")
    func existingIndexOnAnotherTableIsAvoided() {
        var taken = ObjectCopyIndexNames.kept(
            ["orders_2023": ["Orders_User_Id", "orders_2023_pkey"], "reviews_old": ["reviews_product_id"]],
            droppingFirst: []
        )
        let placed = ObjectCopyIndexNames.placed(
            [Self.table("orders", ["user_id"]), Self.table("reviews", ["product_id"])],
            avoiding: &taken,
            from: .mysql,
            to: .postgresql
        )
        #expect(Self.names(placed) == [["orders_user_id_2"], ["reviews_product_id_2"]])
    }

    @Test("An index on a table the copy replaces does not cost the new table its name")
    func indexOnAReplacedTableIsFree() {
        let existing = ["orders": ["orders_user_id"], "Orders_Archive": ["orders_archive_user_id"]]
        #expect(ObjectCopyIndexNames.kept(existing, droppingFirst: ["orders"]) == ["orders_archive_user_id"])

        var taken = ObjectCopyIndexNames.kept(existing, droppingFirst: ["orders"])
        let placed = ObjectCopyIndexNames.placed(
            [Self.table("orders", ["user_id"])], avoiding: &taken, from: .mysql, to: .postgresql
        )
        #expect(Self.names(placed) == [["orders_user_id"]])
    }

    @Test("A table is dropped by its exact name, so a same-named table in another case keeps its indexes")
    func droppedTableMatchesExactly() {
        let existing = ["Orders": ["orders_user_id"]]
        #expect(ObjectCopyIndexNames.kept(existing, droppingFirst: ["orders"]) == ["orders_user_id"])
    }

    @Test("Tables, views and sequences block an index name on PostgreSQL and SQLite; routines and triggers never do")
    func occupiedNamesFollowTheTargetNamespace() {
        let objects = [
            ObjectCopySelection(kind: .table, name: "Orders", schema: "public"),
            ObjectCopySelection(kind: .view, name: "order_totals", schema: "public"),
            ObjectCopySelection(kind: .materializedView, name: "daily_sales", schema: "public"),
            ObjectCopySelection(kind: .sequence, name: "orders_id_seq", schema: "public"),
            ObjectCopySelection(kind: .function, name: "audit", schema: "public", signature: ""),
            ObjectCopySelection(kind: .procedure, name: "archive", schema: "public", signature: ""),
            ObjectCopySelection(kind: .trigger, name: "orders_audit", schema: "public", owner: "orders")
        ]
        let relations: Set<String> = ["orders", "order_totals", "daily_sales", "orders_id_seq"]
        #expect(ObjectCopyIndexNames.occupied(by: objects, in: .postgresql) == relations)
        #expect(ObjectCopyIndexNames.occupied(by: objects, in: .sqlite) == relations)
        #expect(ObjectCopyIndexNames.occupied(by: objects, in: .duckdb).isEmpty)
        #expect(ObjectCopyIndexNames.occupied(by: objects, in: .oracle).isEmpty)
        #expect(ObjectCopyIndexNames.occupied(by: objects, in: .mysql).isEmpty)
    }

    @Test("DuckDB and Oracle let an index share a table's name; PostgreSQL and SQLite do not")
    func indexNamedLikeATableInTheCopy() {
        let tables = [Self.table("orders", ["user_id"]), Self.table("orders_user_id", [])]
        for target in [DatabaseType.duckdb, .oracle] {
            #expect(Self.names(Self.placed(tables, from: .mysql, to: target)) == [["orders_user_id"], []])
        }
        for target in [DatabaseType.postgresql, .sqlite] {
            #expect(Self.names(Self.placed(tables, from: .mysql, to: target)) == [["orders_user_id_2"], []])
        }
    }

    @Test("Two source schemas copied into one target schema share the names they have used")
    func scopesLandingInOneSchemaShareTheirNames() {
        var taken = Set<String>()
        let sales = ObjectCopyIndexNames.placed(
            [Self.table("a_b", ["c"])], avoiding: &taken, from: .mssql, to: .postgresql
        )
        let dbo = ObjectCopyIndexNames.placed(
            [Self.table("a", ["b_c"])], avoiding: &taken, from: .mssql, to: .postgresql
        )
        #expect(Self.names(sales) == [["a_b_c"]])
        #expect(Self.names(dbo) == [["a_b_c_2"]])
    }

    @Test("A name past PostgreSQL's 63 bytes is cut and kept unique rather than truncated by the server")
    func longNamesFitTheLimit() throws {
        let table = "customer_subscription_billing_history"
        let placed = Self.placed(
            [Self.table(table, ["idx_subscription_customer_id", "idx_subscription_customer_id_2"])],
            from: .mysql,
            to: .postgresql
        )
        let names = try #require(placed.first).indexes.map(\.name)
        #expect(names.allSatisfy { $0.utf8.count <= 63 })
        #expect(Set(names.map { $0.lowercased() }).count == 2)
        #expect(names.allSatisfy { $0.hasPrefix(table + "_") })
    }

    @Test("Names differing only in case count as one, and the primary key is left alone")
    func caseFoldedCollisionsAndPrimaryKey() {
        var orders = Self.table("orders", ["Status"])
        orders = TableStructureSnapshot(
            name: orders.name,
            columns: orders.columns,
            indexes: [Self.index("PRIMARY", primary: true)] + orders.indexes
        )
        let placed = Self.placed(
            [orders, Self.table("ORDERS_status", [])],
            from: .mysql,
            to: .postgresql
        )
        #expect(Self.names(placed) == [["PRIMARY", "orders_Status_2"], []])
    }
}
