//
//  TriggerInfoMappingTests.swift
//  TableProTests
//
//  Tests for PluginTriggerInfo encoding and the PluginDriverAdapter trigger bridge.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class StubTriggerDriver: PluginDatabaseDriver {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    var triggersToReturn: [PluginTriggerInfo] = []
    var templateToReturn: String?
    var definitionToReturn: String?
    var dropToReturn: String?
    var editUsesReplace = false
    var transactionalDDL = false
    var executedQueries: [String] = []
    var throwOnQueryContaining: String?

    func createTriggerTemplate(table: String, schema: String?) -> String? { templateToReturn }
    func fetchTriggerDefinition(name: String, table: String, schema: String?) async throws -> String? { definitionToReturn }
    func generateDropTriggerSQL(name: String, table: String, schema: String?) -> String? { dropToReturn }
    var triggerEditUsesReplace: Bool { editUsesReplace }
    var supportsTransactionalDDL: Bool { transactionalDDL }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}
    func execute(query: String) async throws -> PluginQueryResult {
        executedQueries.append(query)
        if let marker = throwOnQueryContaining, query.contains(marker) {
            throw NSError(domain: "StubTriggerDriver", code: 1)
        }
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTriggers(table: String, schema: String?) async throws -> [PluginTriggerInfo] { triggersToReturn }
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

@Suite("Trigger info mapping")
struct TriggerInfoMappingTests {
    @Test("PluginTriggerInfo encodes and decodes")
    func codableRoundTrip() throws {
        let original = PluginTriggerInfo(
            name: "trg_audit",
            timing: "AFTER",
            event: "INSERT",
            statement: "CREATE TRIGGER trg_audit AFTER INSERT ON t FOR EACH ROW BEGIN END"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PluginTriggerInfo.self, from: data)
        #expect(decoded.name == original.name)
        #expect(decoded.timing == original.timing)
        #expect(decoded.event == original.event)
        #expect(decoded.statement == original.statement)
    }

    @Test("Adapter maps plugin triggers to app TriggerInfo preserving fields")
    func adapterMapsTriggers() async throws {
        let driver = StubTriggerDriver()
        driver.triggersToReturn = [
            PluginTriggerInfo(
                name: "trg_audit",
                timing: "AFTER",
                event: "INSERT OR UPDATE",
                statement: "CREATE TRIGGER trg_audit ...",
                enabled: false
            )
        ]
        let connection = DatabaseConnection(name: "Test", type: .postgresql)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: driver)

        let triggers = try await adapter.fetchTriggers(table: "t")
        #expect(triggers.count == 1)
        let trigger = try #require(triggers.first)
        #expect(trigger.name == "trg_audit")
        #expect(trigger.timing == "AFTER")
        #expect(trigger.event == "INSERT OR UPDATE")
        #expect(trigger.statement == "CREATE TRIGGER trg_audit ...")
        #expect(trigger.enabled == false)
    }

    @Test("PluginTriggerInfo carries enabled state through Codable")
    func codableRoundTripWithEnabled() throws {
        let original = PluginTriggerInfo(
            name: "trg_check",
            timing: "BEFORE",
            event: "UPDATE",
            statement: "CREATE TRIGGER trg_check ...",
            enabled: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PluginTriggerInfo.self, from: data)
        #expect(decoded.enabled == true)
    }
}

@Suite("StructureTab triggers")
struct StructureTabTriggersTests {
    @Test("Triggers tab is part of the canonical tab set")
    func triggersInAllCases() {
        #expect(StructureTab.allCases.contains(.triggers))
    }

    @Test("Triggers tab has a localized display name")
    func triggersDisplayName() {
        #expect(StructureTab.triggers.displayName == "Triggers")
    }
}

@Suite("Trigger apply strategy")
struct TriggerApplyStrategyTests {
    @Test("MySQL edit drops then recreates (no replace, non-transactional)")
    func mysqlEdit() {
        #expect(TriggerApplyStrategy.resolve(isEdit: true, usesReplace: false, transactionalDDL: false) == .dropThenCreate)
    }

    @Test("Create is always direct or transactional, never drop-first")
    func createNeverDropsFirst() {
        #expect(TriggerApplyStrategy.resolve(isEdit: false, usesReplace: false, transactionalDDL: false) == .direct)
        #expect(TriggerApplyStrategy.resolve(isEdit: false, usesReplace: false, transactionalDDL: true) == .transactional(dropFirst: false))
    }

    @Test("SQLite edit drops first inside a transaction")
    func sqliteEdit() {
        #expect(TriggerApplyStrategy.resolve(isEdit: true, usesReplace: false, transactionalDDL: true) == .transactional(dropFirst: true))
    }

    @Test("PostgreSQL and SQL Server edits replace in a transaction without a drop")
    func replaceTransactionalEdit() {
        #expect(TriggerApplyStrategy.resolve(isEdit: true, usesReplace: true, transactionalDDL: true) == .transactional(dropFirst: false))
    }

    @Test("Oracle edit replaces directly (no transactional DDL)")
    func oracleEdit() {
        #expect(TriggerApplyStrategy.resolve(isEdit: true, usesReplace: true, transactionalDDL: false) == .direct)
    }
}

@Suite("Trigger editing bridge")
struct TriggerEditingBridgeTests {
    private func makeAdapter(_ configure: (StubTriggerDriver) -> Void) -> PluginDriverAdapter {
        let driver = StubTriggerDriver()
        configure(driver)
        let connection = DatabaseConnection(name: "Test", type: .postgresql)
        return PluginDriverAdapter(connection: connection, pluginDriver: driver)
    }

    @Test("Adapter bridges the create-trigger template")
    func bridgesTemplate() {
        let adapter = makeAdapter { $0.templateToReturn = "CREATE TRIGGER t ..." }
        #expect(adapter.createTriggerTemplate(table: "users") == "CREATE TRIGGER t ...")
    }

    @Test("Adapter bridges the drop-trigger SQL")
    func bridgesDrop() {
        let adapter = makeAdapter { $0.dropToReturn = "DROP TRIGGER t" }
        #expect(adapter.generateDropTriggerSQL(name: "t", table: "users") == "DROP TRIGGER t")
    }

    @Test("Adapter bridges the editable definition")
    func bridgesDefinition() async throws {
        let adapter = makeAdapter { $0.definitionToReturn = "CREATE OR REPLACE TRIGGER t ..." }
        let def = try await adapter.fetchTriggerDefinition(name: "t", table: "users")
        #expect(def == "CREATE OR REPLACE TRIGGER t ...")
    }

    @Test("Adapter bridges edit-strategy capability flags")
    func bridgesFlags() {
        let adapter = makeAdapter {
            $0.editUsesReplace = true
            $0.transactionalDDL = true
        }
        #expect(adapter.triggerEditUsesReplace)
        #expect(adapter.supportsTransactionalDDL)
    }
}

@MainActor
@Suite("Trigger apply execution")
struct TriggerApplyExecutionTests {
    private func makeStubAndAdapter() -> (StubTriggerDriver, PluginDriverAdapter) {
        let stub = StubTriggerDriver()
        let connection = DatabaseConnection(name: "Test", type: .postgresql)
        return (stub, PluginDriverAdapter(connection: connection, pluginDriver: stub))
    }

    @Test("Transactional apply runs BEGIN, drop, create, COMMIT in order")
    func transactionalSuccess() async throws {
        let (stub, adapter) = makeStubAndAdapter()
        try await TriggerEditing.runInTransaction(driver: adapter, dropSQL: "DROP TRIGGER t", sql: "CREATE TRIGGER t")
        #expect(stub.executedQueries == ["BEGIN", "DROP TRIGGER t", "CREATE TRIGGER t", "COMMIT"])
    }

    @Test("Transactional apply rolls back and does not commit when the create fails")
    func transactionalRollback() async {
        let (stub, adapter) = makeStubAndAdapter()
        stub.throwOnQueryContaining = "CREATE TRIGGER"
        await #expect(throws: (any Error).self) {
            try await TriggerEditing.runInTransaction(driver: adapter, dropSQL: nil, sql: "CREATE TRIGGER t")
        }
        #expect(stub.executedQueries.contains("ROLLBACK"))
        #expect(!stub.executedQueries.contains("COMMIT"))
    }

    @Test("Drop-then-create runs drop then create on success")
    func dropThenCreateSuccess() async throws {
        let (stub, adapter) = makeStubAndAdapter()
        try await TriggerEditing.runDropThenCreate(driver: adapter, dropSQL: "DROP TRIGGER t", sql: "CREATE TRIGGER t", rollback: "RESTORE t")
        #expect(stub.executedQueries == ["DROP TRIGGER t", "CREATE TRIGGER t"])
    }

    @Test("Drop-then-create restores the original when the create fails")
    func dropThenCreateRollbackBuffer() async {
        let (stub, adapter) = makeStubAndAdapter()
        stub.throwOnQueryContaining = "CREATE TRIGGER"
        await #expect(throws: (any Error).self) {
            try await TriggerEditing.runDropThenCreate(driver: adapter, dropSQL: "DROP TRIGGER t", sql: "CREATE TRIGGER t", rollback: "RESTORE t")
        }
        #expect(stub.executedQueries == ["DROP TRIGGER t", "CREATE TRIGGER t", "RESTORE t"])
    }
}
