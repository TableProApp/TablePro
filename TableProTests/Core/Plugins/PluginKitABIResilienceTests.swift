//
//  PluginKitABIResilienceTests.swift
//  TableProTests
//
//  Guards the additive-safety promise of the resilient PluginKit ABI: a driver
//  that implements only the required surface and omits every defaulted
//  requirement must still satisfy the protocol, and each default must return its
//  documented value. If a requirement is ever added without a default, this file
//  (and FakeMSSQLPluginDriver) stops compiling, flagging a breaking change that
//  needs a currentPluginKitVersion bump. Cross-binary load compatibility itself
//  is checked by scripts/check-pluginkit-abi.sh, run manually before merging.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

/// Implements only what `PluginDatabaseDriver` requires, for the defaults `FakeMSSQLPluginDriver` overrides.
private final class BareRequiredSurfaceDriver: PluginDatabaseDriver, @unchecked Sendable {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }

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

struct PluginKitABIResilienceTests {
    private func makeMinimalDriver() -> any PluginDatabaseDriver {
        FakeMSSQLPluginDriver()
    }

    @Test("A driver that omits defaulted requirements falls back to the documented synchronous defaults")
    func synchronousDefaults() {
        let driver = makeMinimalDriver()
        #expect(driver.supportsTransactions == true)
        #expect(driver.serverVersion == nil)
        #expect(driver.capabilities.isEmpty)
        #expect(driver.foreignKeyDisableStatements() == nil)
        #expect(driver.foreignKeyEnableStatements() == nil)
        #expect(driver.supportedMaintenanceOperations() == nil)
        #expect(driver.maintenanceOperations() == nil)
        #expect(driver.buildExplainQuery("SELECT 1") == nil)
        #expect(driver.injectRowLimit("SELECT 1", limit: 100) == nil)
        #expect(driver.defaultExportQuery(table: "users") == nil)
        #expect(driver.createViewTemplate() == nil)
        #expect(driver.generateCreateTableSQL(definition: .init(tableName: "users", columns: [], primaryKeyColumns: [])) == nil)
        #expect(driver.unsupportedStructureColumnFields.isEmpty)
        #expect(driver.unsupportedIndexTypes.isEmpty)
        #expect(driver.schemaOperationRefusal(.renameCheckConstraint(from: "a", to: "b")) == nil)
        #expect(driver.checkConstraintRefusal == nil)
        #expect(driver.createSchemaStatement(name: "app") == nil)
        #expect(driver.createSchemaStatements(PluginSchemaDefinition(name: "app")) == nil)
        #expect(driver.renameSchemaStatements(name: "app", to: "archive") == nil)
        #expect(
            driver.alterSchemaStatements(
                from: PluginSchemaDetails(name: "app"),
                to: PluginSchemaDefinition(name: "app")
            ) == nil
        )
    }

    @Test("A driver built before connect warnings existed reports none")
    func connectionWarningDefaultsToNone() {
        let driver: any PluginDatabaseDriver = BareRequiredSurfaceDriver()
        #expect(driver.connectionWarning == nil)
        #expect(driver.hasLostConnection == false)
    }

    @Test("A driver that answers only the older name list has it lifted into table-like descriptors")
    func legacyMaintenanceNamesAreLifted() {
        let lifted = PluginMaintenanceOperation.lifting(["VACUUM", "ANALYZE"])

        #expect(lifted.map(\.name) == ["VACUUM", "ANALYZE"])
        #expect(lifted.allSatisfy { $0.appliesTo == PluginObjectKind.allTableLike })
        #expect(lifted.allSatisfy { $0.scope == .objectOrDatabase })
        #expect(lifted.allSatisfy { $0.options.isEmpty })
        #expect(lifted.allSatisfy { $0.applies(to: .view) })
    }

    @Test("A driver that omits defaulted requirements falls back to the documented asynchronous defaults")
    func asynchronousDefaults() async throws {
        let driver = makeMinimalDriver()
        #expect(try await driver.fetchSchemas().isEmpty)
        #expect(try await driver.fetchExternalSchemaNames().isEmpty)
        #expect(try await driver.fetchSchemaDetails(name: "app") == nil)
        #expect(try await driver.fetchApproximateRowCount(table: "users", schema: nil) == nil)
        #expect(try await driver.fetchIndexDDL(table: "users", schema: nil).isEmpty)
        #expect(try await driver.fetchCommentDDL(table: "users", schema: nil).isEmpty)
        let base = QueryCompletionProfile(
            resolvedDialect: nil,
            statementCompletions: [CompletionEntry(label: "SELECT", insertText: "SELECT")],
            revision: "fixture"
        )
        let resolved = try await driver.resolveQueryCompletionProfile(
            databaseTypeId: "SQL Server",
            base: base
        )
        #expect(resolved.resolvedDialect == nil)
        #expect(resolved.statementCompletions.map(\.label) == ["SELECT"])
        #expect(resolved.revision == "fixture")
    }
}
