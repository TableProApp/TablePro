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

    @Test("A copy within one engine runs exactly as it did")
    func sameEngineIsUntouched() {
        let tables = [Self.table("orders", ["user_id"]), Self.table("reviews", ["user_id"])]
        #expect(Self.placed(tables, from: .postgresql, to: .postgresql) == tables)
        #expect(Self.placed(tables, from: .sqlite, to: .sqlite) == tables)
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
