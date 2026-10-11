//
//  PluginDriverAdapterSchemaSetTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class SchemaSetStubDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var requested: [[String]] = []

    let tables: [PluginTableInfo]?
    let types: [PluginUserDefinedTypeInfo]?

    init(tables: [PluginTableInfo]? = nil, types: [PluginUserDefinedTypeInfo]? = nil) {
        self.tables = tables
        self.types = types
    }

    var requestedSchemaSets: [[String]] {
        lock.withLock { requested }
    }

    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { "public" }
    var serverVersion: String? { nil }

    func fetchTables(inSchemas schemas: [String]) async throws -> [PluginTableInfo]? {
        lock.withLock { requested.append(schemas) }
        return tables
    }

    func fetchUserDefinedTypes(inSchemas schemas: [String]) async throws -> [PluginUserDefinedTypeInfo]? {
        lock.withLock { requested.append(schemas) }
        return types
    }

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

private final class SchemaSetUnawareDriver: PluginDatabaseDriver, @unchecked Sendable {
    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { "public" }
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

@MainActor
struct PluginDriverAdapterSchemaSetTests {
    private func adapter(_ driver: any PluginDatabaseDriver) -> PluginDriverAdapter {
        PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .postgresql), pluginDriver: driver)
    }

    @Test("A set read maps each row's kind and keeps the schema the row came from")
    func setReadMapsKindsAndKeepsSchemas() async throws {
        let driver = SchemaSetStubDriver(tables: [
            PluginTableInfo(name: "events", type: "PARTITIONED TABLE", schema: "app", comment: nil, partitionCount: 3),
            PluginTableInfo(name: "orders", type: "TABLE", schema: "sales"),
            PluginTableInfo(name: "totals", type: "MATERIALIZED VIEW", schema: "sales")
        ])
        let tables = try #require(try await adapter(driver).fetchTables(inSchemas: ["app", "sales"]))

        #expect(tables.map(\.name) == ["events", "orders", "totals"])
        #expect(tables.map(\.type) == [.partitionedTable, .table, .materializedView])
        #expect(tables.map(\.schema) == ["app", "sales", "sales"])
        #expect(tables.first?.partitionCount == 3)
        #expect(driver.requestedSchemaSets == [["app", "sales"]])
    }

    @Test("A one-schema set stamps that schema on a row that came back without one")
    func oneSchemaSetStampsItsSchema() async throws {
        let driver = SchemaSetStubDriver(tables: [PluginTableInfo(name: "orders", type: "TABLE")])
        let tables = try #require(try await adapter(driver).fetchTables(inSchemas: ["sales"]))
        #expect(tables.map(\.schema) == ["sales"])
    }

    @Test("A row without a schema in a several-schema set is not given a guessed one")
    func severalSchemaSetGuessesNoSchema() async throws {
        let driver = SchemaSetStubDriver(tables: [PluginTableInfo(name: "orders", type: "TABLE")])
        let tables = try #require(try await adapter(driver).fetchTables(inSchemas: ["app", "sales"]))
        #expect(tables.map(\.schema) == [nil])
    }

    @Test("A driver with no set read answers nil, so the caller asks each schema itself")
    func unsupportedSetReadPassesNilThrough() async throws {
        let unaware = adapter(SchemaSetUnawareDriver())
        #expect(try await unaware.fetchTables(inSchemas: ["app"]) == nil)
        #expect(try await unaware.fetchUserDefinedTypes(inSchemas: ["app"]) == nil)

        let declining = adapter(SchemaSetStubDriver(tables: nil, types: nil))
        #expect(try await declining.fetchTables(inSchemas: ["app"]) == nil)
        #expect(try await declining.fetchUserDefinedTypes(inSchemas: ["app"]) == nil)
    }

    @Test("Types from a set read are sorted by schema, then name")
    func typesSortBySchemaThenName() async throws {
        let driver = SchemaSetStubDriver(types: [
            PluginUserDefinedTypeInfo(name: "mood", kind: .enumeration, schema: "sales"),
            PluginUserDefinedTypeInfo(name: "zone", kind: .domain, schema: "app"),
            PluginUserDefinedTypeInfo(name: "amount", kind: .domain, schema: "sales"),
            PluginUserDefinedTypeInfo(name: "address", kind: .composite, schema: "app")
        ])
        let types = try #require(try await adapter(driver).fetchUserDefinedTypes(inSchemas: ["sales", "app"]))

        #expect(types.map(\.schema) == ["app", "app", "sales", "sales"])
        #expect(types.map(\.name) == ["address", "zone", "amount", "mood"])
    }

    @Test("Only a one-schema set stamps its schema on a type that came back without one")
    func typeSchemaFallbackNeedsOneSchema() async throws {
        let unnamed = [PluginUserDefinedTypeInfo(name: "mood", kind: .enumeration)]
        let one = try #require(
            try await adapter(SchemaSetStubDriver(types: unnamed)).fetchUserDefinedTypes(inSchemas: ["sales"])
        )
        let several = try #require(
            try await adapter(SchemaSetStubDriver(types: unnamed)).fetchUserDefinedTypes(inSchemas: ["app", "sales"])
        )
        #expect(one.map(\.schema) == ["sales"])
        #expect(several.map(\.schema) == [nil])
    }
}
