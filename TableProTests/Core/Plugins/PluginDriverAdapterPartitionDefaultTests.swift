//
//  PluginDriverAdapterPartitionDefaultTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class PartitionUnawareDriver: PluginDatabaseDriver {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }

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

@Suite("Partition support stays optional for plugins")
struct PluginDriverAdapterPartitionDefaultTests {
    @Test("A driver that never implements fetchPartitions still resolves through the protocol default")
    func unimplementedFetchPartitionsReturnsEmpty() async throws {
        let connection = DatabaseConnection(name: "Test", type: .postgresql)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: PartitionUnawareDriver())
        let partitions = try await adapter.fetchPartitions(table: "orders", schema: "public")
        #expect(partitions.isEmpty)
    }
}
