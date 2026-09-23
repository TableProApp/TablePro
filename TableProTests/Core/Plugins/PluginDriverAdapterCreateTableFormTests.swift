//
//  PluginDriverAdapterCreateTableFormTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

private class BaseFormDriver: @unchecked Sendable {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
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

private final class GridOnlyDriver: BaseFormDriver, PluginDatabaseDriver, @unchecked Sendable {}

private final class FormDriver: BaseFormDriver, PluginDatabaseDriver, @unchecked Sendable {
    static let spec = PluginCreateTableFormSpec(sections: [
        PluginFormSection(id: "keys", title: "Primary Key", fields: [
            PluginFormField(id: "pk", label: "Partition key", kind: .text(placeholder: nil, isRequired: true))
        ])
    ])

    private(set) var specSchemas: [String?] = []
    private(set) var requests: [PluginCreateTableRequest] = []

    func createTableFormSpec(schema: String?) -> PluginCreateTableFormSpec? {
        specSchemas.append(schema)
        return Self.spec
    }

    func createTableStatements(for request: PluginCreateTableRequest, schema: String?) throws -> [String] {
        requests.append(request)
        guard let key = request.values["pk"], !key.isEmpty else {
            throw PluginCreateTableFormError(message: "Enter the partition key", fieldId: "pk")
        }
        return ["CreateTable \(request.tableName) \(key) \(schema ?? "-")"]
    }
}

@Suite("Create Table form bridge")
struct PluginDriverAdapterCreateTableFormTests {
    private func makeAdapter(driver: any PluginDatabaseDriver) -> PluginDriverAdapter {
        PluginDriverAdapter(connection: DatabaseConnection(name: "Test", type: .redis), pluginDriver: driver)
    }

    @Test("A DatabaseDriver that does not offer a form returns nil and refuses to build statements")
    func databaseDriverDefaultHasNoForm() {
        let driver = MockDatabaseDriver()
        let request = PluginCreateTableRequest(tableName: "orders", values: [:])

        #expect(driver.createTableFormSpec(schema: nil) == nil)
        #expect(throws: PluginCreateTableFormError.self) {
            try driver.createTableStatements(for: request, schema: nil)
        }
    }

    @Test("A plugin that keeps the PluginKit default leaves the adapter on the column grid")
    func adapterPassesThroughTheDefault() {
        let adapter = makeAdapter(driver: GridOnlyDriver())
        let request = PluginCreateTableRequest(tableName: "orders", values: [:])

        #expect(adapter.createTableFormSpec(schema: "public") == nil)
        #expect(throws: PluginCreateTableFormError.self) {
            try adapter.createTableStatements(for: request, schema: nil)
        }
    }

    @Test("The adapter hands the plugin's spec and statements through with the schema")
    func adapterBridgesThePluginForm() throws {
        let plugin = FormDriver()
        let adapter = makeAdapter(driver: plugin)
        let request = PluginCreateTableRequest(tableName: "orders", values: ["pk": "id"])

        #expect(adapter.createTableFormSpec(schema: "app") == FormDriver.spec)
        #expect(plugin.specSchemas == ["app"])
        #expect(try adapter.createTableStatements(for: request, schema: "app") == ["CreateTable orders id app"])
        #expect(plugin.requests == [request])
    }

    @Test("A plugin's form error reaches the caller unchanged")
    func adapterKeepsThePluginError() {
        let adapter = makeAdapter(driver: FormDriver())
        let request = PluginCreateTableRequest(tableName: "orders", values: [:])

        #expect(throws: PluginCreateTableFormError(message: "Enter the partition key", fieldId: "pk")) {
            try adapter.createTableStatements(for: request, schema: nil)
        }
    }
}
