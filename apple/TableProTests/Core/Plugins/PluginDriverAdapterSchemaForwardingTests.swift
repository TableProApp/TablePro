import Foundation
import os
@testable import TablePro
import TableProPluginKit
import Testing

// Records the schema each read reaches the plugin with. The session sits on `home`.
private final class SchemaRecordingDriver: PluginDriverStub, @unchecked Sendable {
    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { "home" }
    private let recorded = OSAllocatedUnfairLock(initialState: [String: String?]())

    var schemas: [String: String?] { recorded.withLock { $0 } }

    private func record(_ read: String, _ schema: String?) {
        recorded.withLock { $0[read] = .some(schema) }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        record("columns", schema)
        return []
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        record("allColumns", schema)
        return [:]
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        record("viewDefinition", schema)
        return ""
    }

    func fetchObjectComment(table: String, schema: String?) async throws -> String? {
        record("objectComment", schema)
        return nil
    }

    func fetchTableOptions(table: String, schema: String?) async throws -> PluginTableOptions? {
        record("tableOptions", schema)
        return nil
    }

    func fetchDependentTypes(table: String, schema: String?) async throws -> [(name: String, labels: [String])] {
        record("dependentTypes", schema)
        return []
    }

    func fetchDependentSequences(table: String, schema: String?) async throws -> [(name: String, ddl: String)] {
        record("dependentSequences", schema)
        return []
    }

    func sampleFieldPaths(table: String, schema: String?, limit: Int) async throws -> [PluginFieldPath] {
        record("fieldPaths", schema)
        return []
    }

    func createTriggerTemplate(table: String, schema: String?) -> String? {
        record("triggerTemplate", schema)
        return nil
    }

    func fetchTriggerDefinition(name: String, table: String, schema: String?) async throws -> String? {
        record("triggerDefinition", schema)
        return nil
    }

    func generateDropTriggerSQL(name: String, table: String, schema: String?) -> String? {
        record("dropTrigger", schema)
        return nil
    }

    func fetchExactRowCount(
        table: String,
        schema: String?,
        queryFilters: [PluginQueryFilter],
        logicMode: String
    ) async throws -> Int? {
        record(queryFilters.isEmpty ? "exactCount" : "browseCount", schema)
        return nil
    }
}

@MainActor
struct PluginDriverAdapterSchemaForwardingTests {
    private static let reads = [
        "columns", "allColumns", "viewDefinition", "objectComment", "tableOptions", "dependentTypes",
        "dependentSequences", "fieldPaths", "triggerTemplate", "triggerDefinition", "dropTrigger", "exactCount",
        "browseCount",
    ]

    private static func readEverything(through driver: any DatabaseDriver, schema: String?) async throws {
        _ = try await driver.fetchColumns(table: "t", schema: schema)
        _ = try await driver.fetchAllColumns(schema: schema)
        _ = try await driver.fetchViewDefinition(view: "v", schema: schema)
        _ = try await driver.fetchObjectComment(tableName: "t", schema: schema)
        _ = try await driver.fetchTableOptions(tableName: "t", schema: schema)
        _ = try await driver.fetchDependentTypes(forTable: "t", schema: schema)
        _ = try await driver.fetchDependentSequences(forTable: "t", schema: schema)
        _ = try await driver.sampleFieldPaths(table: "t", schema: schema, limit: 10)
        _ = driver.createTriggerTemplate(table: "t", schema: schema)
        _ = try await driver.fetchTriggerDefinition(name: "trg", table: "t", schema: schema)
        _ = driver.generateDropTriggerSQL(name: "trg", table: "t", schema: schema)
        _ = try await driver.fetchExactRowCount(table: "t", schema: schema, filters: [], logicMode: .and)
        _ = try await driver.fetchExactRowCount(
            table: "t",
            schema: schema,
            browseFilters: [PluginQueryFilter(column: "k", op: "=", value: "1")]
        )
    }

    private static func adapter(over plugin: SchemaRecordingDriver) -> any DatabaseDriver {
        PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .postgresql), pluginDriver: plugin)
    }

    @Test("Each read reaches the plugin with the schema its caller named, not the one the session sits on")
    func readsKeepTheCallersSchema() async throws {
        let plugin = SchemaRecordingDriver()
        try await Self.readEverything(through: Self.adapter(over: plugin), schema: "sales")

        let schemas = plugin.schemas
        for read in Self.reads {
            #expect(schemas[read] == .some("sales"), "\(read)")
        }
    }

    @Test("A read whose caller named no schema reads the schema the session sits on")
    func unnamedSchemaReadsTheSessions() async throws {
        let plugin = SchemaRecordingDriver()
        try await Self.readEverything(through: Self.adapter(over: plugin), schema: nil)

        let schemas = plugin.schemas
        for read in Self.reads {
            #expect(schemas[read] == .some("home"), "\(read)")
        }
    }
}
