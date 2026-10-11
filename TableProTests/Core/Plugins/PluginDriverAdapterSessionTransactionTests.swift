//
//  PluginDriverAdapterSessionTransactionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private class BaseSessionDriver: @unchecked Sendable {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { true }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    func connect() async throws {}
    func disconnect() {}

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

/// A plugin built before the requirement existed, which reaches the new method through the
/// protocol's own default.
private final class DefaultSessionDriver: BaseSessionDriver, PluginDatabaseDriver {}

private final class ReportingSessionDriver: BaseSessionDriver, PluginDatabaseDriver, @unchecked Sendable {
    let state: PluginSessionTransactionState

    init(state: PluginSessionTransactionState) {
        self.state = state
    }

    func sessionTransactionState() async -> PluginSessionTransactionState { state }
}

struct PluginDriverAdapterSessionTransactionTests {
    private func makeAdapter(driver: any PluginDatabaseDriver) -> PluginDriverAdapter {
        PluginDriverAdapter(
            connection: DatabaseConnection(name: "Test", type: .redis),
            pluginDriver: driver
        )
    }

    @Test("A plugin that cannot answer reports unknown through the adapter")
    func defaultIsUnknown() async {
        let adapter = makeAdapter(driver: DefaultSessionDriver())
        #expect(await adapter.sessionTransactionState() == .unknown)
    }

    @Test(
        "A plugin's own answer is forwarded unchanged",
        arguments: [
            PluginSessionTransactionState.idle,
            .inTransaction,
            .abortedTransaction,
            .holdsSessionLocks,
            .unknown,
        ]
    )
    func answerIsForwarded(state: PluginSessionTransactionState) async {
        let adapter = makeAdapter(driver: ReportingSessionDriver(state: state))
        #expect(await adapter.sessionTransactionState() == state)
    }
}
