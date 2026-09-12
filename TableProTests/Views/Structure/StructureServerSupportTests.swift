//
//  StructureServerSupportTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class StructureSupportStubDriver: PluginDatabaseDriver, @unchecked Sendable {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    var hiddenFields: Set<StructureColumnField> = []
    var hiddenIndexTypes: Set<String> = []

    var unsupportedStructureColumnFields: Set<StructureColumnField> { hiddenFields }
    var unsupportedIndexTypes: Set<String> { hiddenIndexTypes }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}
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

private final class DefaultStructureStubDriver: PluginDatabaseDriver, @unchecked Sendable {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}
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

@MainActor @Suite("Structure server support")
struct StructureServerSupportTests {
    private static let additionalFields: Set<StructureColumnField> = [
        .primaryKey, .generated, .generationExpression
    ]

    private static let legacyServer = StructureServerSupport(
        unsupportedColumnFields: [.generated, .generationExpression],
        unsupportedIndexTypes: ["brin"]
    )

    private func makeManager() -> StructureChangeManager {
        let manager = StructureChangeManager()
        manager.workingColumns = [EditableColumnDefinition.placeholder()]
        return manager
    }

    private func provider(tab: StructureTab, support: StructureServerSupport) -> StructureRowProvider {
        StructureRowProvider(
            changeManager: makeManager(),
            tab: tab,
            databaseType: .postgresql,
            additionalFields: Self.additionalFields,
            serverSupport: support
        )
    }

    @Test("An unrestricted server offers every field and index type")
    func unrestrictedOffersEverything() {
        let support = StructureServerSupport.unrestricted
        #expect(StructureColumnField.allCases.allSatisfy { support.offers($0) })
        #expect(support.offeredIndexTypes(from: EditableIndexDefinition.IndexType.allCases)
            == EditableIndexDefinition.IndexType.allCases)
    }

    @Test("Index types are matched case-insensitively")
    func indexTypesMatchCaseInsensitively() {
        let offered = Self.legacyServer.offeredIndexTypes(from: EditableIndexDefinition.IndexType.allCases)
        #expect(!offered.contains(.brin))
        #expect(offered.contains(.gin))
        #expect(offered.count == EditableIndexDefinition.IndexType.allCases.count - 1)
    }

    @Test("A server without generated columns never shows the Generated and Expression columns")
    func legacyServerHidesGeneratedFields() {
        let fields = provider(tab: .columns, support: Self.legacyServer).orderedColumnFields
        #expect(!fields.contains(.generated))
        #expect(!fields.contains(.generationExpression))
        #expect(fields.contains(.primaryKey))
    }

    @Test("A server with generated columns keeps them")
    func modernServerKeepsGeneratedFields() {
        let fields = provider(tab: .columns, support: .unrestricted).orderedColumnFields
        #expect(fields.contains(.generated))
        #expect(fields.contains(.generationExpression))
    }

    @Test("The static field order applies the same server support as the provider")
    func staticOrderMatchesProvider() {
        let fields = StructureRowProvider.orderedFields(
            for: .postgresql,
            additionalFields: Self.additionalFields,
            serverSupport: Self.legacyServer
        )
        #expect(fields == provider(tab: .columns, support: Self.legacyServer).orderedColumnFields)
        #expect(!fields.contains(.generated))
    }

    @Test("The index type dropdown leaves out what the server lacks")
    func indexTypeDropdownFiltersUnsupportedTypes() {
        let types = provider(tab: .indexes, support: Self.legacyServer).customDropdownOptions[2]?.compactMap(\.sql) ?? []
        #expect(!types.isEmpty)
        #expect(!types.contains("BRIN"))
        #expect(types.contains("GIN"))
        let unrestricted = provider(tab: .indexes, support: .unrestricted).customDropdownOptions[2]?.compactMap(\.sql)
        #expect(unrestricted?.contains("BRIN") == true)
    }

    @Test("The adapter bridges what the connected server cannot honour")
    func adapterBridgesServerSupport() {
        let driver = StructureSupportStubDriver()
        driver.hiddenFields = [.generated, .generationExpression]
        driver.hiddenIndexTypes = ["BRIN"]
        let adapter = PluginDriverAdapter(
            connection: DatabaseConnection(name: "Test", type: .postgresql),
            pluginDriver: driver
        )
        let support = StructureServerSupport(driver: adapter)
        #expect(support.unsupportedColumnFields == [.generated, .generationExpression])
        #expect(support.unsupportedIndexTypes == ["BRIN"])
    }

    @Test("A driver built before the hook existed restricts nothing")
    func defaultDriverRestrictsNothing() {
        let adapter = PluginDriverAdapter(
            connection: DatabaseConnection(name: "Test", type: .postgresql),
            pluginDriver: DefaultStructureStubDriver()
        )
        #expect(StructureServerSupport(driver: adapter) == .unrestricted)
        #expect(StructureServerSupport(driver: nil) == .unrestricted)
    }
}
