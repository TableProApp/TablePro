//
//  PluginDriverAdapterTableTypeMappingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class StubTableTypeDriver: PluginDatabaseDriver {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    var stubbedTables: [PluginTableInfo] = []

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        stubbedTables
    }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}
    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

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

@Suite("PluginDriverAdapter table type mapping")
struct PluginDriverAdapterTableTypeMappingTests {
    private func makeAdapter(driver: StubTableTypeDriver) -> PluginDriverAdapter {
        let connection = DatabaseConnection(name: "Test", type: .postgresql)
        return PluginDriverAdapter(connection: connection, pluginDriver: driver)
    }

    @Test("Maps TABLE/BASE TABLE/PREFIX strings to .table")
    func mapsTableVariants() async throws {
        let driver = StubTableTypeDriver()
        driver.stubbedTables = [
            PluginTableInfo(name: "users", type: "TABLE"),
            PluginTableInfo(name: "orders", type: "BASE TABLE"),
            PluginTableInfo(name: "PREFIX", type: "prefix")
        ]
        let adapter = makeAdapter(driver: driver)
        let tables = try await adapter.fetchTables()
        #expect(tables.count == 3)
        #expect(tables.allSatisfy { $0.type == .table })
    }

    @Test("Maps VIEW string to .view")
    func mapsView() async throws {
        let driver = StubTableTypeDriver()
        driver.stubbedTables = [PluginTableInfo(name: "user_summary", type: "VIEW")]
        let adapter = makeAdapter(driver: driver)
        let tables = try await adapter.fetchTables()
        #expect(tables.first?.type == .view)
    }

    @Test("Maps MATERIALIZED VIEW string to .materializedView")
    func mapsMaterializedView() async throws {
        let driver = StubTableTypeDriver()
        driver.stubbedTables = [PluginTableInfo(name: "daily_sales", type: "MATERIALIZED VIEW")]
        let adapter = makeAdapter(driver: driver)
        let tables = try await adapter.fetchTables()
        #expect(tables.first?.type == .materializedView)
    }

    @Test("Maps materialized_view variant to .materializedView")
    func mapsMaterializedViewUnderscore() async throws {
        let driver = StubTableTypeDriver()
        driver.stubbedTables = [PluginTableInfo(name: "daily_sales", type: "materialized_view")]
        let adapter = makeAdapter(driver: driver)
        let tables = try await adapter.fetchTables()
        #expect(tables.first?.type == .materializedView)
    }

    @Test("Maps FOREIGN TABLE string to .foreignTable")
    func mapsForeignTable() async throws {
        let driver = StubTableTypeDriver()
        driver.stubbedTables = [PluginTableInfo(name: "remote_users", type: "FOREIGN TABLE")]
        let adapter = makeAdapter(driver: driver)
        let tables = try await adapter.fetchTables()
        #expect(tables.first?.type == .foreignTable)
    }

    @Test("Maps foreign_table variant to .foreignTable")
    func mapsForeignTableUnderscore() async throws {
        let driver = StubTableTypeDriver()
        driver.stubbedTables = [PluginTableInfo(name: "remote_users", type: "foreign_table")]
        let adapter = makeAdapter(driver: driver)
        let tables = try await adapter.fetchTables()
        #expect(tables.first?.type == .foreignTable)
    }

    @Test("Maps system table variants to .systemTable")
    func mapsSystemTable() async throws {
        let driver = StubTableTypeDriver()
        driver.stubbedTables = [
            PluginTableInfo(name: "pg_class", type: "SYSTEM TABLE"),
            PluginTableInfo(name: "sqlite_master", type: "system base table"),
            PluginTableInfo(name: "sys_views", type: "system view")
        ]
        let adapter = makeAdapter(driver: driver)
        let tables = try await adapter.fetchTables()
        #expect(tables.count == 3)
        #expect(tables.allSatisfy { $0.type == .systemTable })
    }

    @Test("Maps unknown type to .table with warning")
    func mapsUnknownToTable() async throws {
        let driver = StubTableTypeDriver()
        driver.stubbedTables = [PluginTableInfo(name: "thing", type: "GIBBERISH")]
        let adapter = makeAdapter(driver: driver)
        let tables = try await adapter.fetchTables()
        #expect(tables.first?.type == .table)
    }

    @Test("Type matching is case-insensitive")
    func caseInsensitiveMatching() async throws {
        let driver = StubTableTypeDriver()
        driver.stubbedTables = [
            PluginTableInfo(name: "t1", type: "table"),
            PluginTableInfo(name: "v1", type: "View"),
            PluginTableInfo(name: "m1", type: "Materialized View"),
            PluginTableInfo(name: "f1", type: "Foreign Table")
        ]
        let adapter = makeAdapter(driver: driver)
        let tables = try await adapter.fetchTables()
        #expect(tables[0].type == .table)
        #expect(tables[1].type == .view)
        #expect(tables[2].type == .materializedView)
        #expect(tables[3].type == .foreignTable)
    }

    @Test("TableType raw value round-trip for new cases")
    func rawValueRoundTrip() {
        #expect(TableInfo.TableType.materializedView.rawValue == "MATERIALIZED VIEW")
        #expect(TableInfo.TableType.foreignTable.rawValue == "FOREIGN TABLE")
        #expect(TableInfo.TableType(rawValue: "MATERIALIZED VIEW") == .materializedView)
        #expect(TableInfo.TableType(rawValue: "FOREIGN TABLE") == .foreignTable)
    }
}
