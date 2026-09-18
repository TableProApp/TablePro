//
//  PluginDriverAdapterTransactionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private class TransactionDriverBase: @unchecked Sendable {
    private(set) var executedQueries: [String] = []

    func connect() async throws {}
    func disconnect() {}

    func execute(query: String) async throws -> PluginQueryResult {
        executedQueries.append(query)
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
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

private final class LegacyTransactionDriver: TransactionDriverBase, PluginDatabaseDriver, @unchecked Sendable {}

private final class ModeAwareTransactionDriver: TransactionDriverBase, PluginDatabaseDriver, @unchecked Sendable {
    private(set) var receivedModes: [PluginTransactionAccessMode] = []

    func beginTransaction(mode: PluginTransactionAccessMode) async throws {
        receivedModes.append(mode)
    }
}

@Suite("PluginDriverAdapter transaction access mode")
struct PluginDriverAdapterTransactionTests {
    private func connection() -> DatabaseConnection {
        DatabaseConnection(
            name: "Transaction Test",
            host: "127.0.0.1",
            port: 3_306,
            database: "test",
            username: "root",
            type: .mysql
        )
    }

    @Test("The adapter forwards the requested access mode to the plugin driver")
    func forwardsAccessMode() async throws {
        let driver = ModeAwareTransactionDriver()
        let adapter = PluginDriverAdapter(connection: connection(), pluginDriver: driver)

        try await adapter.beginTransaction(mode: .readWrite)

        #expect(driver.receivedModes == [.readWrite])
        #expect(driver.executedQueries.isEmpty)
    }

    @Test("A plugin built before the access mode existed still opens a transaction")
    func fallsBackForDriversWithoutAccessModeSupport() async throws {
        let driver = LegacyTransactionDriver()
        let adapter = PluginDriverAdapter(connection: connection(), pluginDriver: driver)

        try await adapter.beginTransaction(mode: .readWrite)

        #expect(driver.executedQueries == ["BEGIN"])
    }
}
