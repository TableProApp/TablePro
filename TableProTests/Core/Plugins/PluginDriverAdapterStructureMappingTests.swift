//
//  PluginDriverAdapterStructureMappingTests.swift
//  TableProTests
//
//  Every adapter path that hands a table's structure to the app carries every field the plugin read.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class StubStructureDriver: PluginDatabaseDriver, @unchecked Sendable {
    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { "public" }
    var serverVersion: String? { nil }
    var providesBulkForeignKeyFetch: Bool { true }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        PluginStructureFixtures.columns
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        ["orders": PluginStructureFixtures.columns]
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        PluginStructureFixtures.indexes
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        PluginStructureFixtures.foreignKeys
    }

    func fetchAllForeignKeys(schema: String?) async throws -> [String: [PluginForeignKeyInfo]] {
        ["orders": PluginStructureFixtures.foreignKeys]
    }

    func fetchCheckConstraints(table: String, schema: String?) async throws -> [PluginCheckConstraintInfo] {
        PluginStructureFixtures.checkConstraints
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginStructureFixtures.tableMetadata.first { $0.tableName == table } ?? PluginTableMetadata(tableName: table)
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}
    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}

@Suite("PluginDriverAdapter structure mapping")
struct PluginDriverAdapterStructureMappingTests {
    private func makeAdapter() -> PluginDriverAdapter {
        PluginDriverAdapter(
            connection: DatabaseConnection(name: "Test", type: .postgresql),
            pluginDriver: StubStructureDriver()
        )
    }

    private func expectCarried<Source, Target>(
        _ sources: [Source],
        _ targets: [Target],
        appOnly: Set<String> = ["id"],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let problems = StructureMappingCoverage.carryProblems(from: sources, to: targets, appOnly: appOnly)
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))", sourceLocation: sourceLocation)
    }

    @Test("Both column reads and the bulk column read carry every column field")
    func columnReadsCarryEveryField() async throws {
        let adapter = makeAdapter()
        let fixtures = PluginStructureFixtures.columns

        let current = try await adapter.fetchColumns(table: "orders")
        let named = try await adapter.fetchColumns(table: "orders", schema: "app")
        let bulk = try await adapter.fetchAllColumns()

        expectCarried(fixtures, current)
        expectCarried(fixtures, named)
        expectCarried(fixtures, bulk["orders"] ?? [])
    }

    @Test("Both index reads carry every index field")
    func indexReadsCarryEveryField() async throws {
        let adapter = makeAdapter()
        let fixtures = PluginStructureFixtures.indexes

        let current = try await adapter.fetchIndexes(table: "orders")
        let named = try await adapter.fetchIndexes(table: "orders", schema: "app")

        expectCarried(fixtures, current)
        expectCarried(fixtures, named)
    }

    @Test("Both foreign key reads and the bulk foreign key read carry every foreign key field")
    func foreignKeyReadsCarryEveryField() async throws {
        let adapter = makeAdapter()
        let fixtures = PluginStructureFixtures.foreignKeys

        let current = try await adapter.fetchForeignKeys(table: "orders")
        let named = try await adapter.fetchForeignKeys(table: "orders", schema: "app")
        let bulk = try await adapter.fetchAllForeignKeys()

        expectCarried(fixtures, current)
        expectCarried(fixtures, named)
        expectCarried(fixtures, bulk["orders"] ?? [])
    }

    @Test("Both check constraint reads carry every check constraint field")
    func checkConstraintReadsCarryEveryField() async throws {
        let adapter = makeAdapter()
        let fixtures = PluginStructureFixtures.checkConstraints

        let current = try await adapter.fetchCheckConstraints(table: "orders")
        let named = try await adapter.fetchCheckConstraints(table: "orders", schema: "app")

        expectCarried(fixtures, current)
        expectCarried(fixtures, named)
    }

    @Test("The table metadata read carries every metadata field")
    func tableMetadataReadCarriesEveryField() async throws {
        let adapter = makeAdapter()
        let fixtures = PluginStructureFixtures.tableMetadata

        var mapped: [TableMetadata] = []
        for fixture in fixtures {
            mapped.append(try await adapter.fetchTableMetadata(tableName: fixture.tableName))
        }

        expectCarried(fixtures, mapped, appOnly: [])
    }
}
