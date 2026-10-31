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

private final class StubTriggerDriver: PluginDriverStub, @unchecked Sendable {
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

    func ping() async throws {}
    func execute(query: String) async throws -> PluginQueryResult {
        executedQueries.append(query)
        if let marker = throwOnQueryContaining, query.contains(marker) {
            throw NSError(domain: "StubTriggerDriver", code: 1)
        }
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func fetchTriggers(table: String, schema: String?) async throws -> [PluginTriggerInfo] { triggersToReturn }
}

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

struct StructurePaneTriggersTests {
    @Test("Triggers is one of the Structure view's panes")
    func triggersInAllCases() {
        #expect(StructurePane.allCases.contains(.triggers))
    }

    @Test("The Triggers pane has a localized display name")
    func triggersDisplayName() {
        #expect(StructurePane.triggers.displayName == "Triggers")
    }
}

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

    // A trigger edit's own BEGIN ran inside the transaction a query tab left open on the session driver.
    // The gate is injected: the real one confirms a drop with an NSAlert nobody answers on CI.
    @Test("Apply and drop run on the pooled connection and leave the session driver alone")
    func applyAndDropRunOnThePooledConnection() async throws {
        let connection = TestFixtures.makeConnection(database: "app", type: .postgresql)
        let sessionStub = StubTriggerDriver()
        sessionStub.dropToReturn = "DROP TRIGGER t"
        let session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: sessionStub)
        )
        DatabaseManager.shared.injectSession(session, for: connection.id)
        let scope = DatabaseScope(connectionId: connection.id, database: "app", schema: "public")
        let pooledStub = StubTriggerDriver()
        pooledStub.transactionalDDL = true
        // Both stubs build the drop, so only the queries each one executed show which driver was asked.
        pooledStub.dropToReturn = "DROP TRIGGER t"
        let pooledAdapter = PluginDriverAdapter(connection: connection, pluginDriver: pooledStub)
        try await pooledAdapter.connect()
        MetadataConnectionPool.shared.injectEntry(pooledAdapter, scope: scope)
        defer {
            MetadataConnectionPool.shared.closeAll(connectionId: connection.id)
            DatabaseManager.shared.removeSession(for: connection.id)
        }

        try await TriggerEditing.apply(
            scope: scope,
            connection: connection,
            tableName: "orders",
            sql: "CREATE TRIGGER t",
            isEdit: false,
            originalName: nil,
            originalDefinition: nil,
            gate: AlwaysAllowGate()
        )
        try await TriggerEditing.drop(
            scope: scope,
            connection: connection,
            tableName: "orders",
            name: "t",
            gate: AlwaysAllowGate()
        )

        #expect(pooledStub.executedQueries == ["BEGIN", "CREATE TRIGGER t", "COMMIT", "DROP TRIGGER t"])
        #expect(sessionStub.executedQueries.isEmpty)
    }
}
