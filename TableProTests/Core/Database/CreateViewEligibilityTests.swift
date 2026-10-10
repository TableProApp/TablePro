//
//  CreateViewEligibilityTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private class ViewEligibilityBaseDriver {
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

private final class NoViewTemplateDriver: ViewEligibilityBaseDriver, PluginDatabaseDriver, @unchecked Sendable {}

private final class ViewTemplateDriver: ViewEligibilityBaseDriver, PluginDatabaseDriver, @unchecked Sendable {
    func createViewTemplate() -> String? {
        "CREATE VIEW view_name AS\nSELECT 1;"
    }
}

@MainActor
struct CreateViewEligibilityTests {
    private func adapter(_ driver: any PluginDatabaseDriver) -> PluginDriverAdapter {
        PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .postgresql), pluginDriver: driver)
    }

    @Test("No driver means no New View")
    func noDriverCannotCreate() {
        #expect(!CreateViewEligibility.canCreateView(with: nil))
    }

    @Test("A driver with a view template can create a view")
    func templateDriverCanCreate() {
        #expect(CreateViewEligibility.canCreateView(with: adapter(ViewTemplateDriver())))
    }

    @Test("A driver with no view template is not offered New View")
    func driverWithoutTemplateCannotCreate() {
        #expect(!CreateViewEligibility.canCreateView(with: adapter(NoViewTemplateDriver())))
    }
}
