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

struct TriggerStatementShapeTests {
    @Test("A trigger's action body is not a CREATE TRIGGER statement")
    func actionBodyIsRefused() {
        #expect(!TriggerStatementShape.createsTrigger("UPDATE stats SET n = n + 1", databaseType: .mysql))
        #expect(!TriggerStatementShape.createsTrigger("BEGIN\n  UPDATE stats SET n = n + 1;\nEND", databaseType: .mysql))
        #expect(!TriggerStatementShape.createsTrigger("CREATE PROCEDURE p() SELECT 'create trigger'", databaseType: .mysql))
        #expect(!TriggerStatementShape.createsTrigger("-- CREATE TRIGGER t\nUPDATE stats SET n = 1", databaseType: .mysql))
    }

    @Test("A full definition is accepted, with a definer, a replace clause or a function ahead of it")
    func fullDefinitionIsAccepted() {
        #expect(TriggerStatementShape.createsTrigger(
            "CREATE DEFINER=`root`@`localhost` TRIGGER `bump` AFTER INSERT ON `orders` FOR EACH ROW\nUPDATE stats SET n = n + 1",
            databaseType: .mysql
        ))
        #expect(TriggerStatementShape.createsTrigger("create or replace trigger t before insert on x begin null; end;", databaseType: .oracle))
        #expect(TriggerStatementShape.createsTrigger("CREATE TEMP TRIGGER t AFTER INSERT ON x BEGIN SELECT 1; END", databaseType: .sqlite))
        #expect(TriggerStatementShape.createsTrigger(
            """
            CREATE OR REPLACE FUNCTION f() RETURNS trigger AS $$ BEGIN RETURN NEW; END $$ LANGUAGE plpgsql;
            CREATE TRIGGER t BEFORE INSERT ON x FOR EACH ROW EXECUTE FUNCTION f();
            """,
            databaseType: .postgresql
        ))
    }
}

@MainActor
struct TriggerEditSafetyTests {
    private static let fullDefinition = "CREATE TRIGGER bump AFTER INSERT ON orders FOR EACH ROW\nUPDATE stats SET n = n + 1"
    private static let body = "UPDATE stats SET n = n + 1"

    private func makeStubAndAdapter() -> (StubTriggerDriver, PluginDriverAdapter) {
        let stub = StubTriggerDriver()
        let connection = DatabaseConnection(name: "Test", type: .mysql)
        return (stub, PluginDriverAdapter(connection: connection, pluginDriver: stub))
    }

    @Test("The editor is seeded with the full definition, never the action body")
    func editorSourceIsTheFullDefinition() async throws {
        let (_, adapter) = makeStubAndAdapter()
        let trigger = TriggerInfo(
            name: "bump", timing: "AFTER", event: "INSERT", statement: Self.body, table: "orders",
            definition: Self.fullDefinition
        )
        let source = try await TriggerEditSource.resolve(trigger, table: "orders", databaseType: .mysql, on: adapter)
        #expect(source == Self.fullDefinition)
    }

    @Test("A trigger with only an action body cannot be opened for editing")
    func bodyOnlyTriggerIsRefused() async {
        let (_, adapter) = makeStubAndAdapter()
        let trigger = TriggerInfo(name: "bump", timing: "AFTER", event: "INSERT", statement: Self.body, table: "orders")
        await #expect(throws: (any Error).self) {
            _ = try await TriggerEditSource.resolve(trigger, table: "orders", databaseType: .mysql, on: adapter)
        }
    }

    @Test("A statement that is itself the full CREATE is still editable")
    func fullStatementIsEditable() async throws {
        let (_, adapter) = makeStubAndAdapter()
        let trigger = TriggerInfo(name: "bump", timing: "AFTER", event: "INSERT", statement: Self.fullDefinition, table: "orders")
        let source = try await TriggerEditSource.resolve(trigger, table: "orders", databaseType: .mysql, on: adapter)
        #expect(source == Self.fullDefinition)
    }

    @Test("A drop-first edit refuses text that would not recreate the trigger")
    func dropFirstRefusesANonCreate() {
        let plan = TriggerApplyPlan(strategy: .dropThenCreate, dropSQL: "DROP TRIGGER bump")
        #expect(throws: TriggerEditingError.self) {
            _ = try TriggerEditing.restoreDefinition(
                for: plan, sql: Self.body, originalDefinition: Self.fullDefinition, databaseType: .mysql
            )
        }
        let transactional = TriggerApplyPlan(strategy: .transactional(dropFirst: true), dropSQL: "DROP TRIGGER bump")
        #expect(throws: TriggerEditingError.self) {
            _ = try TriggerEditing.restoreDefinition(
                for: transactional, sql: Self.body, originalDefinition: nil, databaseType: .sqlite
            )
        }
    }

    @Test("A drop-then-create edit refuses to run without a definition to restore")
    func dropThenCreateNeedsARestorableOriginal() throws {
        let plan = TriggerApplyPlan(strategy: .dropThenCreate, dropSQL: "DROP TRIGGER bump")
        #expect(throws: TriggerEditingError.self) {
            _ = try TriggerEditing.restoreDefinition(
                for: plan, sql: Self.fullDefinition, originalDefinition: Self.body, databaseType: .mysql
            )
        }
        #expect(throws: TriggerEditingError.self) {
            _ = try TriggerEditing.restoreDefinition(
                for: plan, sql: Self.fullDefinition, originalDefinition: nil, databaseType: .mysql
            )
        }
        let restore = try TriggerEditing.restoreDefinition(
            for: plan, sql: Self.fullDefinition, originalDefinition: Self.fullDefinition, databaseType: .mysql
        )
        #expect(restore == Self.fullDefinition)
    }

    @Test("A replace or a create runs without a restore check")
    func directNeedsNoRestore() throws {
        let plan = TriggerApplyPlan(strategy: .direct, dropSQL: nil)
        let restore = try TriggerEditing.restoreDefinition(
            for: plan, sql: Self.body, originalDefinition: nil, databaseType: .oracle
        )
        #expect(restore == nil)
        #expect(plan.gatedStatements(for: Self.fullDefinition).isEmpty)
    }

    @Test("The gate is shown the DROP ahead of the CREATE")
    func gateSeesTheDrop() {
        let plan = TriggerApplyPlan(strategy: .dropThenCreate, dropSQL: "DROP TRIGGER bump")
        #expect(plan.gatedStatements(for: Self.fullDefinition) == ["DROP TRIGGER bump", Self.fullDefinition])
    }

    @Test("A failed restore reports that the trigger is gone and carries its definition")
    func failedRestoreIsReported() async {
        let (stub, adapter) = makeStubAndAdapter()
        stub.throwOnQueryContaining = "CREATE TRIGGER"
        var dropped: String?
        do {
            try await TriggerEditing.runDropThenCreate(
                driver: adapter, dropSQL: "DROP TRIGGER bump", sql: "CREATE TRIGGER bump broken", rollback: Self.fullDefinition
            )
            Issue.record("The edit was expected to fail")
        } catch {
            dropped = (error as? TriggerEditingError)?.droppedDefinition
        }
        #expect(dropped == Self.fullDefinition)
        #expect(stub.executedQueries == ["DROP TRIGGER bump", "CREATE TRIGGER bump broken", Self.fullDefinition])
    }

    @Test("Saving an action body as an edit drops nothing")
    func applyRunsNothingForAnActionBody() async throws {
        let connection = TestFixtures.makeConnection(database: "app", type: .mysql)
        let stub = StubTriggerDriver()
        stub.dropToReturn = "DROP TRIGGER bump"
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: stub)
        try await adapter.connect()
        let session = ConnectionSession(connection: connection, driver: adapter)
        DatabaseManager.shared.injectSession(session, for: connection.id)
        let scope = DatabaseScope(connectionId: connection.id, database: "app", schema: nil)
        MetadataConnectionPool.shared.injectEntry(adapter, scope: scope)
        defer {
            MetadataConnectionPool.shared.closeAll(connectionId: connection.id)
            DatabaseManager.shared.removeSession(for: connection.id)
        }
        let gate = RequestRecordingGate(allows: true)

        await #expect(throws: TriggerEditingError.self) {
            try await TriggerEditing.apply(
                scope: scope,
                connection: connection,
                tableName: "orders",
                sql: Self.body,
                isEdit: true,
                originalName: "bump",
                originalDefinition: Self.body,
                gate: gate
            )
        }
        #expect(stub.executedQueries.isEmpty)
        let requests = await gate.requests
        #expect(requests.isEmpty)
    }
}

// A Cancel in the gate's confirmation reached the trigger editor as an error row under the SQL.
@MainActor
struct TriggerGateDenialTests {
    private func install() async throws -> (connection: DatabaseConnection, scope: DatabaseScope, stub: StubTriggerDriver) {
        let connection = TestFixtures.makeConnection(database: "app", type: .postgresql)
        let stub = StubTriggerDriver()
        stub.dropToReturn = "DROP TRIGGER t"
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: stub)
        try await adapter.connect()
        DatabaseManager.shared.injectSession(ConnectionSession(connection: connection, driver: adapter), for: connection.id)
        let scope = DatabaseScope(connectionId: connection.id, database: "app", schema: nil)
        MetadataConnectionPool.shared.injectEntry(adapter, scope: scope)
        return (connection, scope, stub)
    }

    private func uninstall(_ connection: DatabaseConnection) {
        MetadataConnectionPool.shared.closeAll(connectionId: connection.id)
        DatabaseManager.shared.removeSession(for: connection.id)
    }

    private func failure(of body: () async throws -> Void) async -> GatedOperationFailure? {
        do {
            try await body()
            return nil
        } catch {
            return GatedOperationFailure(error)
        }
    }

    @Test("A Cancel at the gate ends a trigger save and a trigger drop quietly, with nothing run")
    func cancelIsQuiet() async throws {
        let installed = try await install()
        defer { uninstall(installed.connection) }

        let save = await failure {
            try await TriggerEditing.apply(
                scope: installed.scope,
                connection: installed.connection,
                tableName: "orders",
                sql: "CREATE TRIGGER t",
                isEdit: false,
                originalName: nil,
                originalDefinition: nil,
                gate: AlwaysDenyGate.cancelling
            )
        }
        let drop = await failure {
            try await TriggerEditing.drop(
                scope: installed.scope,
                connection: installed.connection,
                tableName: "orders",
                name: "t",
                gate: AlwaysDenyGate.cancelling
            )
        }

        #expect(save == .cancelledByUser)
        #expect(drop == .cancelledByUser)
        #expect(save?.message == nil)
        #expect(installed.stub.executedQueries.isEmpty)
    }

    @Test("A refused trigger save says why and is not a failed statement")
    func refusalExplainsItself() async throws {
        let installed = try await install()
        defer { uninstall(installed.connection) }

        let save = await failure {
            try await TriggerEditing.apply(
                scope: installed.scope,
                connection: installed.connection,
                tableName: "orders",
                sql: "CREATE TRIGGER t",
                isEdit: false,
                originalName: nil,
                originalDefinition: nil,
                gate: AlwaysDenyGate(reason: "Safe Mode is read-only")
            )
        }

        #expect(save == .refused("Safe Mode is read-only"))
        #expect(save?.reportsFailure == false)
        #expect(installed.stub.executedQueries.isEmpty)
    }
}
