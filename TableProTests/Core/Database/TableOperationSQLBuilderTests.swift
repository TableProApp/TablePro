//
//  TableOperationSQLBuilderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class StubDropDriver: PluginDatabaseDriver {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}
    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }

    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}

@Suite("TableOperationSQLBuilder")
@MainActor
struct TableOperationSQLBuilderTests {
    private func makeBuilder(tables: [TableInfo]) -> TableOperationSQLBuilder {
        let connection = DatabaseConnection(name: "Test", type: .postgresql)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: StubDropDriver())
        return TableOperationSQLBuilder(
            connectionId: connection.id,
            databaseType: .postgresql,
            tableInfoProvider: { Dictionary(uniqueKeysWithValues: tables.map { ($0.name, $0) }) },
            adapterProvider: { adapter }
        )
    }

    @Test("Materialized view drops with DROP MATERIALIZED VIEW")
    func dropsMaterializedView() {
        let builder = makeBuilder(tables: [
            TableInfo(name: "daily_sales", type: .materializedView, rowCount: nil, schema: "public")
        ])
        let stmts = builder.generate(truncates: [], deletes: ["daily_sales"], options: [:], includeFKHandling: false)
        #expect(stmts == ["DROP MATERIALIZED VIEW \"public\".\"daily_sales\""])
    }

    @Test("View drops with DROP VIEW")
    func dropsView() {
        let builder = makeBuilder(tables: [TableInfo(name: "active_users", type: .view, rowCount: nil)])
        let stmts = builder.generate(truncates: [], deletes: ["active_users"], options: [:], includeFKHandling: false)
        #expect(stmts == ["DROP VIEW \"active_users\""])
    }

    @Test("Foreign table drops with DROP FOREIGN TABLE")
    func dropsForeignTable() {
        let builder = makeBuilder(tables: [TableInfo(name: "remote_orders", type: .foreignTable, rowCount: nil)])
        let stmts = builder.generate(truncates: [], deletes: ["remote_orders"], options: [:], includeFKHandling: false)
        #expect(stmts == ["DROP FOREIGN TABLE \"remote_orders\""])
    }

    @Test("Plain table drops with DROP TABLE")
    func dropsTable() {
        let builder = makeBuilder(tables: [TableInfo(name: "orders", type: .table, rowCount: nil)])
        let stmts = builder.generate(truncates: [], deletes: ["orders"], options: [:], includeFKHandling: false)
        #expect(stmts == ["DROP TABLE \"orders\""])
    }

    @Test("System table drops with DROP TABLE")
    func dropsSystemTable() {
        let builder = makeBuilder(tables: [TableInfo(name: "pg_stats", type: .systemTable, rowCount: nil)])
        let stmts = builder.generate(truncates: [], deletes: ["pg_stats"], options: [:], includeFKHandling: false)
        #expect(stmts == ["DROP TABLE \"pg_stats\""])
    }

    @Test("Unresolvable name falls back to DROP TABLE")
    func fallsBackWhenLookupMisses() {
        let builder = makeBuilder(tables: [])
        let stmts = builder.generate(truncates: [], deletes: ["ghost"], options: [:], includeFKHandling: false)
        #expect(stmts == ["DROP TABLE \"ghost\""])
    }

    @Test("Cascade applies to materialized view drops")
    func cascadeAppliesToMaterializedView() {
        let builder = makeBuilder(tables: [TableInfo(name: "daily_sales", type: .materializedView, rowCount: nil)])
        let options = ["daily_sales": TableOperationOptions(cascade: true)]
        let stmts = builder.generate(truncates: [], deletes: ["daily_sales"], options: options, includeFKHandling: false)
        #expect(stmts == ["DROP MATERIALIZED VIEW \"daily_sales\" CASCADE"])
    }

    @Test("Drop qualifies schema when TableInfo carries one")
    func qualifiesSchema() {
        let builder = makeBuilder(tables: [TableInfo(name: "orders", type: .table, rowCount: nil, schema: "sales")])
        let stmts = builder.generate(truncates: [], deletes: ["orders"], options: [:], includeFKHandling: false)
        #expect(stmts == ["DROP TABLE \"sales\".\"orders\""])
    }

    @Test("Truncate qualifies schema when TableInfo carries one")
    func truncateQualifiesSchema() {
        let builder = makeBuilder(tables: [TableInfo(name: "orders", type: .table, rowCount: nil, schema: "sales")])
        let stmts = builder.generate(truncates: ["orders"], deletes: [], options: [:], includeFKHandling: false)
        #expect(stmts == ["TRUNCATE TABLE \"sales\".\"orders\""])
    }
}
