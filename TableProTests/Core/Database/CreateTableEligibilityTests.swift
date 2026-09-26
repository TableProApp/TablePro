//
//  CreateTableEligibilityTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private class EligibilityBaseDriver {
    var supportsTransactions: Bool { false }
    var serverVersion: String? { nil }

    func connect() async throws {}
    func disconnect() {}

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

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func switchDatabase(to database: String) async throws {}
}

private final class NoCreateDriver: EligibilityBaseDriver, PluginDatabaseDriver, @unchecked Sendable {}

private final class SQLCreateDriver: EligibilityBaseDriver, PluginDatabaseDriver, @unchecked Sendable {
    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        "CREATE TABLE \(definition.tableName) (\(definition.columns.map { "\($0.name) \($0.dataType)" }.joined(separator: ", ")))"
    }
}

private final class FormCreateDriver: EligibilityBaseDriver, PluginDatabaseDriver, @unchecked Sendable {
    func createTableFormSpec(schema: String?) -> PluginCreateTableFormSpec? {
        PluginCreateTableFormSpec(sections: [])
    }
}

@MainActor
struct CreateTableEligibilityTests {
    private func adapter(_ driver: any PluginDatabaseDriver) -> PluginDriverAdapter {
        PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .postgresql), pluginDriver: driver)
    }

    @Test("A driver with no create hook cannot create a table")
    func driverWithoutAHookCannotCreate() {
        #expect(!CreateTableEligibility.canCreateTable(with: adapter(NoCreateDriver())))
    }

    @Test("A driver that writes CREATE TABLE can create a table")
    func sqlDriverCanCreate() {
        #expect(CreateTableEligibility.canCreateTable(with: adapter(SQLCreateDriver())))
    }

    @Test("A driver with its own Create Table form can create a table")
    func formDriverCanCreate() {
        #expect(CreateTableEligibility.canCreateTable(with: adapter(FormCreateDriver())))
    }

    @Test("No driver means no New Table")
    func noDriverCannotCreate() {
        #expect(!CreateTableEligibility.canCreateTable(with: nil))
    }
}
