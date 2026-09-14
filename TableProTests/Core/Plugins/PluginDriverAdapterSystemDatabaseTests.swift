//
//  PluginDriverAdapterSystemDatabaseTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class StubDatabaseMetadataDriver: PluginDatabaseDriver, @unchecked Sendable {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    let metadata: [PluginDatabaseMetadata]

    init(metadata: [PluginDatabaseMetadata]) {
        self.metadata = metadata
    }

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

    func fetchDatabases() async throws -> [String] { metadata.map(\.name) }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        metadata.first { $0.name == database } ?? PluginDatabaseMetadata(name: database)
    }

    func fetchAllDatabaseMetadata() async throws -> [PluginDatabaseMetadata] { metadata }
}

/// SQL Server and ClickHouse never set `isSystemDatabase`, so the switcher's metadata pass listed
/// `master`, `model`, `msdb` and `tempdb` as ordinary databases once it landed, while the sidebar,
/// classifying by the connection type's own list, kept them apart.
@Suite("PluginDriverAdapter system databases")
struct PluginDriverAdapterSystemDatabaseTests {
    private func makeAdapter(type: DatabaseType, metadata: [PluginDatabaseMetadata]) -> PluginDriverAdapter {
        PluginDriverAdapter(
            connection: DatabaseConnection(name: "Test", type: type),
            pluginDriver: StubDatabaseMetadataDriver(metadata: metadata)
        )
    }

    @Test("The connection type's system list classifies databases the driver did not flag")
    func curatedNamesClassifyUnflaggedDatabases() async throws {
        let adapter = makeAdapter(type: .mssql, metadata: [
            PluginDatabaseMetadata(name: "master"),
            PluginDatabaseMetadata(name: "sales"),
            PluginDatabaseMetadata(name: "tempdb")
        ])

        let result = try await adapter.fetchAllDatabaseMetadata()

        #expect(result.filter(\.isSystemDatabase).map(\.name) == ["master", "tempdb"])
        #expect(result.first { $0.name == "master" }?.icon == "gearshape.fill")
        #expect(result.first { $0.name == "sales" }?.icon == "cylinder.fill")
    }

    @Test("A database the driver flags stays a system database even when the type's list omits it")
    func driverFlagIsKept() async throws {
        let adapter = makeAdapter(type: .mssql, metadata: [
            PluginDatabaseMetadata(name: "ssisdb", isSystemDatabase: true)
        ])

        let result = try await adapter.fetchAllDatabaseMetadata()

        #expect(result.first?.isSystemDatabase == true)
    }

    @Test("Metadata for a single database is classified the same way")
    func singleDatabaseMetadataIsClassified() async throws {
        let adapter = makeAdapter(type: .mssql, metadata: [PluginDatabaseMetadata(name: "msdb")])

        let result = try await adapter.fetchDatabaseMetadata("msdb")

        #expect(result.isSystemDatabase)
    }

    @Test("A MySQL connection counts TiDB's capitalised system databases, but not a name MySQL lets users create")
    func mysqlConnectionClassifiesTiDBSpellings() async throws {
        let adapter = makeAdapter(type: .mysql, metadata: [
            PluginDatabaseMetadata(name: "INFORMATION_SCHEMA"),
            PluginDatabaseMetadata(name: "METRICS_SCHEMA"),
            PluginDatabaseMetadata(name: "PERFORMANCE_SCHEMA"),
            PluginDatabaseMetadata(name: "app")
        ])

        let result = try await adapter.fetchAllDatabaseMetadata()

        #expect(result.filter(\.isSystemDatabase).map(\.name) == ["INFORMATION_SCHEMA", "PERFORMANCE_SCHEMA"])
    }

    @Test("A user database is never classified as a system database")
    func userDatabaseStaysUser() {
        let result = PluginDriverAdapter.databaseMetadata(
            PluginDatabaseMetadata(name: "analytics"),
            systemDatabaseNames: ["mysql", "sys"]
        )

        #expect(result.isSystemDatabase == false)
    }
}
