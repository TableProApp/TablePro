//
//  PluginDriverAdapterPingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private class BasePingDriver {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

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

private final class DefaultPingDriver: BasePingDriver, PluginDatabaseDriver {}

private final class PingOverrideDriver: BasePingDriver, PluginDatabaseDriver {
    private(set) var pingCallCount = 0

    func ping() async throws {
        pingCallCount += 1
    }
}

@Suite("PluginDriverAdapter ping")
struct PluginDriverAdapterPingTests {
    private func makeAdapter(driver: any PluginDatabaseDriver) -> PluginDriverAdapter {
        let connection = DatabaseConnection(name: "Test", type: .redis)
        return PluginDriverAdapter(connection: connection, pluginDriver: driver)
    }

    @Test("Adapter ping routes to the plugin ping override, never to execute")
    func pingRoutesToPluginPing() async throws {
        let driver = PingOverrideDriver()
        let adapter = makeAdapter(driver: driver)

        try await adapter.ping()

        #expect(driver.pingCallCount == 1)
        #expect(driver.executedQueries.isEmpty)
    }

    @Test("SQL drivers without a ping override fall back to SELECT 1")
    func defaultPingFallsBackToSelectOne() async throws {
        let driver = DefaultPingDriver()
        let adapter = makeAdapter(driver: driver)

        try await adapter.ping()

        #expect(driver.executedQueries == ["SELECT 1"])
    }
}
