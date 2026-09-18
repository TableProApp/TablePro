//
//  StatementTextValidatorTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class ExecutionRecordingDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var executedQueries: [String] {
        lock.withLock { recorded }
    }

    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}

    func execute(query: String) async throws -> PluginQueryResult {
        lock.withLock { recorded.append(query) }
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

@Suite("A statement holding a NUL character is never sent")
struct StatementTextValidatorTests {
    private let truncatingDelete = "DELETE FROM t\u{0} WHERE id = 1"

    private func makeAdapter() -> (PluginDriverAdapter, ExecutionRecordingDriver) {
        let driver = ExecutionRecordingDriver()
        let connection = DatabaseConnection(name: "Test", type: .sqlite)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: driver)
        return (adapter, driver)
    }

    @Test("NUL is refused, and every other character is left to the server")
    func validation() {
        #expect(StatementTextValidator.error(for: truncatingDelete) != nil)
        #expect(StatementTextValidator.error(for: "SELECT '\u{8}乐\u{200B}'") == nil)
        #expect(StatementTextValidator.error(for: "") == nil)
    }

    @Test("A C-string driver never sees a statement it would cut short at the NUL")
    func adapterRefusesBeforeTheDriver() async {
        let (adapter, driver) = makeAdapter()

        await #expect(throws: DatabaseError.self) { _ = try await adapter.execute(query: truncatingDelete) }
        await #expect(throws: DatabaseError.self) {
            _ = try await adapter.executeUserQuery(query: truncatingDelete, rowCap: nil, parameters: nil)
        }
        await #expect(throws: DatabaseError.self) {
            _ = try await adapter.executeParameterized(query: truncatingDelete, parameters: [])
        }
        await #expect(throws: DatabaseError.self) {
            _ = try await adapter.executeBoundedQuery(query: truncatingDelete, rowCap: 10)
        }
        #expect(driver.executedQueries.isEmpty)
    }

    @Test("An ordinary statement still reaches the driver")
    func ordinaryStatementRuns() async throws {
        let (adapter, driver) = makeAdapter()
        _ = try await adapter.execute(query: "SELECT 1")
        #expect(driver.executedQueries == ["SELECT 1"])
    }

    @Test("The refusal names the character")
    func message() {
        let message = DatabaseError.statementContainsNulCharacter.errorDescription ?? ""
        #expect(message.contains("U+0000"))
    }
}
