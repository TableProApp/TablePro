//
//  SQLExportPluginTests.swift
//  TableProTests
//

#if canImport(SQLExport)
import Foundation
import TableProPluginKit
import Testing

@testable import SQLExport

@MainActor
@Suite("SQLExportPlugin emits round-trippable Postgres dumps")
struct SQLExportPluginTests {
    private static func runExport(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        plugin: SQLExportPlugin = SQLExportPlugin()
    ) async throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sql")
        defer { try? FileManager.default.removeItem(at: url) }
        let progress = PluginExportProgress(progress: Progress())
        plugin.settings = SQLExportOptions()
        _ = try await plugin.export(
            tables: tables, dataSource: dataSource, destination: url, progress: progress)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func table(
        _ name: String, type: String = "table", schema: String = "public"
    ) -> PluginExportTable {
        PluginExportTable(name: name, databaseName: schema, tableType: type, optionValues: [true, true, true])
    }

    @Test("Identity column emits OVERRIDING SYSTEM VALUE and setval")
    func identity_always_emits_overriding_and_setval() async throws {
        let source = MockExportDataSource(
            columns: [
                "users": [
                    PluginColumnInfo(name: "id", dataType: "BIGINT", identityKind: .always),
                    PluginColumnInfo(name: "email", dataType: "TEXT")
                ]
            ],
            ddl: ["users": "CREATE TABLE \"public\".\"users\" (\n  id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,\n  email text NOT NULL,\n  PRIMARY KEY (id)\n);"],
            rows: ["users": [["1", "alice@example.com"], ["2", "bob@example.com"]]],
            rowHeaders: ["users": (["id", "email"], ["bigint", "text"])]
        )
        let dump = try await Self.runExport(tables: [Self.table("users")], dataSource: source)
        #expect(dump.contains("OVERRIDING SYSTEM VALUE"))
        #expect(dump.contains("pg_catalog.setval"))
        #expect(dump.contains("pg_catalog.pg_get_serial_sequence"))
    }

    @Test("BY DEFAULT identity emits no OVERRIDING clause")
    func identity_by_default_no_overriding() async throws {
        let source = MockExportDataSource(
            columns: [
                "items": [
                    PluginColumnInfo(name: "id", dataType: "BIGINT", identityKind: .byDefault),
                    PluginColumnInfo(name: "name", dataType: "TEXT")
                ]
            ],
            rowHeaders: ["items": (["id", "name"], ["bigint", "text"])],
            rows: ["items": [["1", "a"]]]
        )
        let dump = try await Self.runExport(tables: [Self.table("items")], dataSource: source)
        #expect(!dump.contains("OVERRIDING SYSTEM VALUE"))
        #expect(dump.contains("pg_catalog.setval"))
    }

    @Test("Generated STORED columns are dropped from INSERT column list")
    func generated_columns_skipped_from_insert() async throws {
        let source = MockExportDataSource(
            columns: [
                "lines": [
                    PluginColumnInfo(name: "id", dataType: "BIGINT", identityKind: .always),
                    PluginColumnInfo(name: "qty", dataType: "INT"),
                    PluginColumnInfo(name: "price", dataType: "NUMERIC"),
                    PluginColumnInfo(name: "total", dataType: "NUMERIC", isGenerated: true)
                ]
            ],
            rowHeaders: ["lines": (["id", "qty", "price", "total"], ["bigint", "int", "numeric", "numeric"])],
            rows: ["lines": [["1", "2", "5.00", "10.00"]]]
        )
        let dump = try await Self.runExport(tables: [Self.table("lines")], dataSource: source)
        #expect(dump.contains("(\"id\", \"qty\", \"price\")"))
        #expect(!dump.contains("\"total\""))
    }

    @Test("FK constraints land in finalization phase, not CREATE TABLE body")
    func foreign_keys_emitted_after_data() async throws {
        let source = MockExportDataSource(
            columns: [
                "customers": [PluginColumnInfo(name: "id", dataType: "BIGINT", identityKind: .always)],
                "orders": [
                    PluginColumnInfo(name: "id", dataType: "BIGINT", identityKind: .always),
                    PluginColumnInfo(name: "customer_id", dataType: "BIGINT")
                ]
            ],
            ddl: [
                "customers": "CREATE TABLE \"public\".\"customers\" (id bigint GENERATED ALWAYS AS IDENTITY NOT NULL, PRIMARY KEY (id));",
                "orders": "CREATE TABLE \"public\".\"orders\" (id bigint GENERATED ALWAYS AS IDENTITY NOT NULL, customer_id bigint, PRIMARY KEY (id));"
            ],
            rowHeaders: [
                "customers": (["id"], ["bigint"]),
                "orders": (["id", "customer_id"], ["bigint", "bigint"])
            ],
            rows: ["customers": [["1"]], "orders": [["1", "1"]]],
            foreignKeys: [
                "orders": [PluginForeignKeyInfo(
                    name: "orders_customer_id_fkey", column: "customer_id",
                    referencedTable: "customers", referencedColumn: "id",
                    referencedSchema: "public")]
            ]
        )
        let dump = try await Self.runExport(
            tables: [Self.table("orders"), Self.table("customers")], dataSource: source)

        guard let createOrders = dump.range(of: "CREATE TABLE \"public\".\"orders\""),
              let alterFK = dump.range(of: "ALTER TABLE") else {
            Issue.record("Missing CREATE TABLE or ALTER TABLE in export")
            return
        }
        #expect(createOrders.lowerBound < alterFK.lowerBound)
        #expect(!dump.contains("FOREIGN KEY (\"customer_id\") REFERENCES \"public\".\"customers\" (\"id\")\n);"))
        #expect(dump.contains("ALTER TABLE \"public\".\"orders\" ADD CONSTRAINT"))
    }

    @Test("Topological sort places parent before child in CREATE phase")
    func topo_sort_parents_before_children() async throws {
        let source = MockExportDataSource(
            columns: [
                "customers": [PluginColumnInfo(name: "id", dataType: "BIGINT")],
                "orders": [PluginColumnInfo(name: "id", dataType: "BIGINT"),
                           PluginColumnInfo(name: "customer_id", dataType: "BIGINT")]
            ],
            ddl: [
                "customers": "CREATE TABLE \"public\".\"customers\" (id bigint);",
                "orders": "CREATE TABLE \"public\".\"orders\" (id bigint, customer_id bigint);"
            ],
            rowHeaders: ["customers": ([], []), "orders": ([], [])],
            foreignKeys: [
                "orders": [PluginForeignKeyInfo(
                    name: "fk_orders_customers", column: "customer_id",
                    referencedTable: "customers", referencedColumn: "id")]
            ]
        )
        let dump = try await Self.runExport(
            tables: [Self.table("orders"), Self.table("customers")], dataSource: source)
        guard let createCustomers = dump.range(of: "CREATE TABLE \"public\".\"customers\"")?.lowerBound,
              let createOrders = dump.range(of: "CREATE TABLE \"public\".\"orders\"")?.lowerBound else {
            Issue.record("Missing CREATE TABLE statements in dump")
            return
        }
        #expect(createCustomers < createOrders)
    }

    @Test("Composite FK aggregates into one ADD CONSTRAINT statement")
    func composite_fk_single_alter_statement() async throws {
        let source = MockExportDataSource(
            columns: [
                "parent": [PluginColumnInfo(name: "a", dataType: "INT"), PluginColumnInfo(name: "b", dataType: "INT")],
                "child": [
                    PluginColumnInfo(name: "id", dataType: "INT"),
                    PluginColumnInfo(name: "pa", dataType: "INT"),
                    PluginColumnInfo(name: "pb", dataType: "INT")
                ]
            ],
            ddl: [
                "parent": "CREATE TABLE \"public\".\"parent\" (a int, b int);",
                "child": "CREATE TABLE \"public\".\"child\" (id int, pa int, pb int);"
            ],
            rowHeaders: ["parent": ([], []), "child": ([], [])],
            foreignKeys: [
                "child": [
                    PluginForeignKeyInfo(name: "child_parent_fk", column: "pa",
                                         referencedTable: "parent", referencedColumn: "a"),
                    PluginForeignKeyInfo(name: "child_parent_fk", column: "pb",
                                         referencedTable: "parent", referencedColumn: "b")
                ]
            ]
        )
        let dump = try await Self.runExport(
            tables: [Self.table("parent"), Self.table("child")], dataSource: source)
        let alterCount = dump.components(separatedBy: "ALTER TABLE").count - 1
        #expect(alterCount == 1)
        #expect(dump.contains("(\"pa\", \"pb\")"))
        #expect(dump.contains("(\"a\", \"b\")"))
    }

    @Test("Cyclic FK between two tables falls back to alphabetical and emits both ALTERs")
    func cyclic_fk_falls_back_to_alpha() async throws {
        let source = MockExportDataSource(
            columns: [
                "a_table": [PluginColumnInfo(name: "id", dataType: "INT"),
                            PluginColumnInfo(name: "b_id", dataType: "INT")],
                "b_table": [PluginColumnInfo(name: "id", dataType: "INT"),
                            PluginColumnInfo(name: "a_id", dataType: "INT")]
            ],
            ddl: [
                "a_table": "CREATE TABLE \"public\".\"a_table\" (id int, b_id int);",
                "b_table": "CREATE TABLE \"public\".\"b_table\" (id int, a_id int);"
            ],
            rowHeaders: ["a_table": ([], []), "b_table": ([], [])],
            foreignKeys: [
                "a_table": [PluginForeignKeyInfo(
                    name: "a_b_fk", column: "b_id",
                    referencedTable: "b_table", referencedColumn: "id")],
                "b_table": [PluginForeignKeyInfo(
                    name: "b_a_fk", column: "a_id",
                    referencedTable: "a_table", referencedColumn: "id")]
            ]
        )
        let dump = try await Self.runExport(
            tables: [Self.table("b_table"), Self.table("a_table")], dataSource: source)
        let alterCount = dump.components(separatedBy: "ALTER TABLE").count - 1
        #expect(alterCount == 2)
    }

    @Test("Views are skipped from INSERT phase")
    func views_skipped_from_inserts() async throws {
        let source = MockExportDataSource(
            columns: [
                "active_users": [PluginColumnInfo(name: "id", dataType: "BIGINT")]
            ],
            ddl: ["active_users": "CREATE OR REPLACE VIEW \"public\".\"active_users\" AS SELECT 1;"],
            rowHeaders: ["active_users": ([], [])]
        )
        let dump = try await Self.runExport(
            tables: [Self.table("active_users", type: "view")], dataSource: source)
        #expect(dump.contains("CREATE OR REPLACE VIEW"))
        #expect(!dump.contains("INSERT INTO"))
    }
}

// MARK: - Mock

private final class MockExportDataSource: PluginExportDataSource, @unchecked Sendable {
    let databaseTypeId: String
    let columns: [String: [PluginColumnInfo]]
    let ddl: [String: String]
    let rows: [String: [[String?]]]
    let rowHeaders: [String: (columns: [String], typeNames: [String])]
    let foreignKeys: [String: [PluginForeignKeyInfo]]

    init(
        databaseTypeId: String = "PostgreSQL",
        columns: [String: [PluginColumnInfo]] = [:],
        ddl: [String: String] = [:],
        rowHeaders: [String: (columns: [String], typeNames: [String])] = [:],
        rows: [String: [[String?]]] = [:],
        foreignKeys: [String: [PluginForeignKeyInfo]] = [:]
    ) {
        self.databaseTypeId = databaseTypeId
        self.columns = columns
        self.ddl = ddl
        self.rows = rows
        self.rowHeaders = rowHeaders
        self.foreignKeys = foreignKeys
    }

    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let header = rowHeaders[table] ?? ([], [])
        let tableRows = rows[table] ?? []
        return AsyncThrowingStream { continuation in
            continuation.yield(.header(PluginStreamHeader(
                columns: header.columns,
                columnTypeNames: header.typeNames,
                estimatedRowCount: nil)))
            if !tableRows.isEmpty {
                continuation.yield(.rows(tableRows))
            }
            continuation.finish()
        }
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String {
        ddl[table] ?? "CREATE TABLE \"\(databaseName)\".\"\(table)\" ()"
    }

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func quoteIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    func escapeStringLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? {
        rows[table]?.count
    }

    func fetchColumns(table: String, databaseName: String) async throws -> [PluginColumnInfo] {
        columns[table] ?? []
    }

    func fetchAllColumns(databaseName: String) async throws -> [String: [PluginColumnInfo]] {
        columns
    }

    func fetchForeignKeys(table: String, databaseName: String) async throws -> [PluginForeignKeyInfo] {
        foreignKeys[table] ?? []
    }

    func fetchAllForeignKeys(databaseName: String) async throws -> [String: [PluginForeignKeyInfo]] {
        foreignKeys
    }
}
#endif
