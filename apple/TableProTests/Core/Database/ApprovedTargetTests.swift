//
//  ApprovedTargetTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

// Its cached schema stays where the session started, as LibPQ's does after a SET search_path the app did not send.
private final class CachedTargetDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var state: PluginSessionTransactionState = .idle
    private var reported: String?

    var events: [String] { lock.withLock { recorded } }

    var transactionState: PluginSessionTransactionState {
        get { lock.withLock { state } }
        set { lock.withLock { state = newValue } }
    }

    func sessionTransactionState() async -> PluginSessionTransactionState { transactionState }

    var reportedDatabase: String? {
        get { lock.withLock { reported } }
        set { lock.withLock { reported = newValue } }
    }

    var currentDatabase: String? { reportedDatabase }

    var supportsSchemas: Bool { true }
    var currentSchema: String? { "public" }

    private func record(_ event: String) {
        lock.withLock { recorded.append(event) }
    }

    func execute(query: String) async throws -> PluginQueryResult {
        record(query)
        return .empty
    }

    func switchSchema(to schema: String) async throws {
        record("SCHEMA \(schema)")
    }

    func switchDatabase(to database: String) async throws {
        record("DATABASE \(database)")
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        record("COUNT \(table)")
        return 0
    }
}

// The person approving is still deciding when the connection moves to another database.
private struct SwitchingWhileAskedGate: ExecutionGate {
    let connectionId: UUID
    let database: String

    func authorize(_ request: OperationRequest) async -> OperationDecision {
        try? await DatabaseManager.shared.switchDatabase(to: database, for: connectionId, persist: false)
        return await AlwaysAllowGate().authorize(request)
    }
}

// An approved statement runs in the database and schema its approval named, whatever the session's caches say.
@MainActor
struct ApprovedTargetTests {
    private func session(
        _ type: DatabaseType,
        database: String,
        browseDatabase: String? = nil,
        browseSchema: String? = nil
    ) -> (id: UUID, driver: CachedTargetDriver) {
        let connection = TestFixtures.makeConnection(database: database, type: type)
        let driver = CachedTargetDriver()
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: driver)
        )
        session.browseDatabase = browseDatabase
        session.browseSchema = browseSchema
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return (connection.id, driver)
    }

    @Test("An approved statement sets its schema before it runs, even when the cached schema already matches")
    func approvedSchemaIsAppliedOverAStaleCache() async throws {
        let (id, driver) = session(.postgresql, database: "app", browseDatabase: "app", browseSchema: "public")
        defer { DatabaseManager.shared.removeSession(for: id) }
        let bridge = DatabaseAccessBridge()

        let scope = try await bridge.resolveStatementScope(connectionId: id, database: nil, schema: nil)
        _ = try await bridge.runStatement(
            scope: scope, query: "DROP TABLE orders", maxRows: 10, timeoutSeconds: 30, cancellation: nil
        )

        let switched = try #require(driver.events.firstIndex(of: "SCHEMA public"))
        let dropped = try #require(driver.events.firstIndex(of: "DROP TABLE orders"))
        #expect(switched < dropped)
    }

    @Test("switch_database on a fixed-database engine is refused before the driver is asked")
    func externalSwitchOnAFixedEngineIsRefused() async {
        let (id, driver) = session(.oracle, database: "PROD")
        defer { DatabaseManager.shared.removeSession(for: id) }

        await #expect(throws: DatabaseAccessError.self) {
            _ = try await MCPConnectionBridge().switchDatabase(connectionId: id, database: "ARCHIVE")
        }

        #expect(driver.events.isEmpty)
        #expect(DatabaseManager.shared.session(for: id)?.browseDatabase == nil)
    }

    @Test("A fixed engine whose driver reports no database refuses any named database and still runs with none")
    func fixedEngineWithNoReportRefusesNamedDatabases() async throws {
        let (id, _) = session(.oracle, database: "PROD", browseDatabase: "ARCHIVE")
        defer { DatabaseManager.shared.removeSession(for: id) }
        let bridge = DatabaseAccessBridge()

        for named in ["ARCHIVE", "PROD"] {
            await #expect(throws: DatabaseAccessError.self) {
                _ = try await bridge.resolveStatementScope(connectionId: id, database: named, schema: nil)
            }
        }
        let unnamed = try await bridge.resolveStatementScope(connectionId: id, database: nil, schema: nil)
        #expect(unnamed.connectionId == id)
    }

    @Test("The in-app schema picker on Oracle still reaches the driver")
    func inAppOracleSchemaSwitchStillWorks() async throws {
        let (id, driver) = session(.oracle, database: "PROD")
        defer { DatabaseManager.shared.removeSession(for: id) }

        try await DatabaseManager.shared.switchSchema(to: "ARCHIVE", for: id)

        #expect(driver.events.contains("SCHEMA ARCHIVE"))
        #expect(DatabaseManager.shared.session(for: id)?.browseSchema == "ARCHIVE")
    }

    @Test(
        "A rollback on an aborted transaction reaches the driver with no schema set before it",
        arguments: ["ROLLBACK", "ROLLBACK TO SAVEPOINT sp1"]
    )
    func rollbackOnAnAbortedSessionSkipsTheSchema(statement: String) async throws {
        let (id, driver) = session(.postgresql, database: "app", browseDatabase: "app", browseSchema: "public")
        defer { DatabaseManager.shared.removeSession(for: id) }
        driver.transactionState = .abortedTransaction
        let bridge = DatabaseAccessBridge()

        let scope = try await bridge.resolveStatementScope(connectionId: id, database: nil, schema: nil)
        _ = try await bridge.runStatement(scope: scope, query: statement, maxRows: 10, timeoutSeconds: 30, cancellation: nil)

        #expect(driver.events.contains(statement))
        #expect(!driver.events.contains { $0.hasPrefix("SCHEMA") })
    }

    private func bigQuery(reported: String?) -> UUID {
        var connection = TestFixtures.makeConnection(database: "staging", type: .bigQuery)
        connection.additionalFields["bqProjectId"] = "production"
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: CachedTargetDriver())
        )
        session.openedDatabase = reported
        session.browseDatabase = reported
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return connection.id
    }

    @Test("BigQuery saved as staging but signed in to production refuses staging and takes the project it reported")
    func bigQueryChecksTheReportedProject() async throws {
        let id = bigQuery(reported: "production")
        defer { DatabaseManager.shared.removeSession(for: id) }
        let bridge = DatabaseAccessBridge()

        await #expect(throws: DatabaseAccessError.self) {
            _ = try await bridge.resolveStatementScope(connectionId: id, database: "staging", schema: nil)
        }
        let project = try await bridge.resolveStatementScope(connectionId: id, database: "production", schema: nil)
        #expect(project.database == "production")
    }

    @Test("BigQuery whose driver reported nothing refuses its saved database, which it never signed in to")
    func bigQueryWithNoReportRefusesItsSavedDatabase() async throws {
        let id = bigQuery(reported: nil)
        defer { DatabaseManager.shared.removeSession(for: id) }

        await #expect(throws: DatabaseAccessError.self) {
            _ = try await DatabaseAccessBridge().resolveStatementScope(connectionId: id, database: "staging", schema: nil)
        }
    }

    private func inject(_ connection: DatabaseConnection, driver: CachedTargetDriver, opened: String?) {
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: driver)
        )
        session.openedDatabase = opened
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
    }

    @Test("A statement approved on a.sqlite never reaches the session that replaced it with b.sqlite")
    func replacedSessionNeverTakesTheStatement() async throws {
        let connection = TestFixtures.makeConnection(database: "a.sqlite", type: .sqlite)
        let approved = CachedTargetDriver()
        inject(connection, driver: approved, opened: "a.sqlite")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let bridge = DatabaseAccessBridge()
        let scope = try await bridge.resolveStatementScope(connectionId: connection.id, database: nil, schema: nil)
        let statement = try await bridge.plannedStatement(scope: scope, query: "DROP TABLE orders", maxRows: 10)
        let operation = try await ApprovedOperationFixture.approve([statement], scope: scope, databaseType: .sqlite)

        var replacement = connection
        replacement.database = "b.sqlite"
        let replacing = CachedTargetDriver()
        DatabaseManager.shared.removeSession(for: connection.id)
        inject(replacement, driver: replacing, opened: "b.sqlite")

        await #expect(throws: DatabaseAccessError.self) {
            _ = try await bridge.runStatement(operation, maxRows: 10, timeoutSeconds: 30, cancellation: nil)
        }
        #expect(scope.database == "a.sqlite")
        #expect(replacing.events.isEmpty)
        #expect(approved.events.isEmpty)
    }

    private func approvedDrop(on connectionId: UUID, type: DatabaseType) async throws -> ApprovedOperation {
        let bridge = DatabaseAccessBridge()
        let scope = try await bridge.resolveStatementScope(connectionId: connectionId, database: nil, schema: nil)
        let statement = try await bridge.plannedStatement(scope: scope, query: "DROP TABLE orders", maxRows: 10)
        return try await ApprovedOperationFixture.approve([statement], scope: scope, databaseType: type)
    }

    @Test("A DROP approved on an Oracle session that reported no database never reaches the session that replaced it")
    func replacedOracleSessionNeverTakesTheStatement() async throws {
        let connection = TestFixtures.makeConnection(database: "PROD", type: .oracle)
        let approved = CachedTargetDriver()
        inject(connection, driver: approved, opened: nil)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let operation = try await approvedDrop(on: connection.id, type: .oracle)

        let replacing = CachedTargetDriver()
        DatabaseManager.shared.removeSession(for: connection.id)
        inject(connection, driver: replacing, opened: nil)

        let error = await #expect(throws: DatabaseAccessError.self) {
            _ = try await DatabaseAccessBridge().runStatement(operation, maxRows: 10, timeoutSeconds: 30, cancellation: nil)
        }
        #expect(error?.message == DatabaseAccessBridge.connectionChanged.message)
        #expect(operation.scope.isServerScoped)
        #expect(replacing.events.isEmpty)
        #expect(approved.events.isEmpty)
    }

    @Test("A DROP approved on an Oracle session runs on it while it is the connect the approval was made on")
    func unchangedSessionRunsTheStatement() async throws {
        let connection = TestFixtures.makeConnection(database: "PROD", type: .oracle)
        let approved = CachedTargetDriver()
        inject(connection, driver: approved, opened: nil)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let operation = try await approvedDrop(on: connection.id, type: .oracle)

        _ = try await DatabaseAccessBridge().runStatement(operation, maxRows: 10, timeoutSeconds: 30, cancellation: nil)

        #expect(approved.events.contains("DROP TABLE orders"))
    }

    @Test("A statement approved before a health reconnect is refused on the connection the reconnect opened")
    func healthReconnectRefusesTheApproval() async throws {
        FakeMSSQLPluginRegistration.registerIfNeeded()
        let manager = DatabaseManager()
        var connection = TestFixtures.makeConnection(name: "Prod")
        connection.type = DatabaseType(rawValue: FakeMSSQLPlugin.databaseTypeId)
        let approved = CachedTargetDriver()
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: approved)
        )
        session.status = .connected
        session.browseDatabase = "app"
        manager.injectSession(session, for: connection.id)
        FakeMSSQLPlugin.recordConfigurations(for: connection.id)
        let bridge = DatabaseAccessBridge(manager: manager)
        let scope = try await bridge.resolveStatementScope(connectionId: connection.id, database: nil, schema: nil)
        let statement = try await bridge.plannedStatement(scope: scope, query: "DELETE FROM orders", maxRows: 10)
        let operation = try await ApprovedOperationFixture.approve(
            [statement], scope: scope, databaseType: connection.type, manager: manager
        )

        let outcome = await manager.recoverNow(connection.id, cause: .stoppedResponding)
        let error = await #expect(throws: DatabaseAccessError.self) {
            _ = try await bridge.runStatement(operation, maxRows: 10, timeoutSeconds: 30, cancellation: nil)
        }

        #expect(outcome == .success)
        #expect(error?.message == DatabaseAccessBridge.connectionChanged.message)
        #expect(approved.events.isEmpty)
        manager.endRecoveryLoop(for: connection.id)
        await manager.stopHealthMonitor(for: connection.id)
        manager.removeSession(for: connection.id)
        FakeMSSQLPlugin.clearConfigurations(for: connection.id)
        await SchemaService.shared.invalidate(connectionId: connection.id)
    }

    private func approvedWithNoDatabase(_ sql: String, on id: UUID, bridge: DatabaseAccessBridge) async throws -> ApprovedOperation {
        let scope = try await bridge.resolveStatementScope(connectionId: id, database: nil, schema: nil)
        let statement = try await bridge.plannedStatement(scope: scope, query: sql, maxRows: 10)
        return try await ExternalStatementGate.approve(
            PendingOperation(
                scope: scope,
                driverGeneration: await bridge.driverGeneration(of: id),
                databaseType: .mysql,
                statements: [statement],
                kind: .writeQuery,
                caller: .mcpClient(label: "tests"),
                capabilities: [.mayWrite],
                operationDescription: "test"
            ),
            gate: SwitchingWhileAskedGate(connectionId: id, database: "production")
        )
    }

    @Test("A DELETE approved with no database selected never runs in the database the connection switched to meanwhile")
    func switchWhileTheApprovalWaitsRefuses() async throws {
        let (id, driver) = session(.mysql, database: "")
        defer { DatabaseManager.shared.removeSession(for: id) }
        let bridge = DatabaseAccessBridge()
        let operation = try await approvedWithNoDatabase("DELETE FROM orders WHERE id = 1", on: id, bridge: bridge)

        let error = await #expect(throws: DatabaseAccessError.self) {
            _ = try await bridge.runStatement(operation, maxRows: 10, timeoutSeconds: 30, cancellation: nil)
        }

        #expect(error?.message == DatabaseAccessBridge.connectionChanged.message)
        #expect(operation.scope.isServerScoped)
        #expect(DatabaseManager.shared.session(for: id)?.resolvedBrowseDatabase == "production")
        #expect(!driver.events.contains { $0.hasPrefix("DELETE") })
    }

    @Test("Rows approved for insert with no database selected never land in the database switched to meanwhile")
    func switchWhileAnInsertWaitsRefuses() async throws {
        let (id, _) = session(.mysql, database: "")
        defer { DatabaseManager.shared.removeSession(for: id) }
        let bridge = DatabaseAccessBridge()
        let operation = try await approvedWithNoDatabase("INSERT INTO orders (id) VALUES (1)", on: id, bridge: bridge)

        let error = await #expect(throws: DatabaseAccessError.self) {
            _ = try await bridge.runInserts(operation)
        }

        #expect(error?.message == DatabaseAccessBridge.connectionChanged.message)
    }

    @Test("A DELETE approved with no database selected runs while the connection still has none")
    func noDatabaseApprovalRunsWhileNoneIsSelected() async throws {
        let (id, driver) = session(.mysql, database: "")
        defer { DatabaseManager.shared.removeSession(for: id) }
        let bridge = DatabaseAccessBridge()
        let scope = try await bridge.resolveStatementScope(connectionId: id, database: nil, schema: nil)
        let statement = try await bridge.plannedStatement(scope: scope, query: "DELETE FROM orders WHERE id = 1", maxRows: 10)
        let operation = try await ApprovedOperationFixture.approve([statement], scope: scope, databaseType: .mysql)

        _ = try await bridge.runStatement(operation, maxRows: 10, timeoutSeconds: 30, cancellation: nil)

        #expect(driver.events.contains("DELETE FROM orders WHERE id = 1"))
    }

    // Approved with no statement of its own, with no database selected, while the connection moves to production.
    private func approvedWithNoStatement(
        _ kind: OperationKind,
        scope: DatabaseScope,
        bridge: DatabaseAccessBridge
    ) async throws -> ApprovedOperation {
        try await ExternalStatementGate.approve(
            PendingOperation(
                scope: scope,
                driverGeneration: await bridge.driverGeneration(of: scope.connectionId),
                databaseType: .mysql,
                statements: [],
                kind: kind,
                caller: .mcpClient(label: "tests"),
                capabilities: [.mayWrite],
                operationDescription: "test"
            ),
            gate: SwitchingWhileAskedGate(connectionId: scope.connectionId, database: "production")
        )
    }

    @Test(
        "A COMMIT or ROLLBACK approved with no database selected never reaches the database switched to meanwhile",
        arguments: ["commit", "rollback"]
    )
    func switchWhileATransactionActionWaitsRefuses(action: String) async throws {
        let (id, driver) = session(.mysql, database: "")
        defer { DatabaseManager.shared.removeSession(for: id) }
        let bridge = DatabaseAccessBridge()
        let scope = try await bridge.resolveAppStatementScope(connectionId: id, database: nil, schema: nil)
        let operation = try await approvedWithNoStatement(.writeQuery, scope: scope, bridge: bridge)

        let error = await #expect(throws: DatabaseAccessError.self) {
            try await bridge.transactionControl(operation, action: action)
        }

        #expect(error?.message == DatabaseAccessBridge.connectionChanged.message)
        #expect(!driver.events.contains(action.uppercased()))
    }

    @Test("A row count approved with no database selected is not read from the database switched to meanwhile")
    func switchWhileACountWaitsRefuses() async throws {
        let (id, driver) = session(.mysql, database: "")
        defer { DatabaseManager.shared.removeSession(for: id) }
        let bridge = DatabaseAccessBridge()
        let scope = try await bridge.resolveScope(connectionId: id, database: nil, schema: nil)
        let operation = try await approvedWithNoStatement(.readQuery, scope: scope, bridge: bridge)

        let error = await #expect(throws: DatabaseAccessError.self) {
            _ = try await bridge.countRows(operation, table: "orders", filters: [], logicMode: .and, exact: false)
        }

        #expect(error?.message == DatabaseAccessBridge.connectionChanged.message)
        #expect(!driver.events.contains("COUNT orders"))
    }

    // A call naming production pins the shared driver there and leaves the browse cursor on no database.
    private func pinToProduction(_ id: UUID, bridge: DatabaseAccessBridge) async throws {
        let named = try await bridge.resolveStatementScope(connectionId: id, database: "production", schema: nil)
        _ = try await bridge.runStatement(scope: named, query: "SELECT 1", maxRows: 10, timeoutSeconds: 30, cancellation: nil)
    }

    @Test("After a call pinned production, a DELETE naming no database is approved naming production and runs only there")
    func deleteAfterAPinNamesWhereTheDriverIs() async throws {
        let (id, driver) = session(.mysql, database: "")
        defer { DatabaseManager.shared.removeSession(for: id) }
        let bridge = DatabaseAccessBridge()
        try await pinToProduction(id, bridge: bridge)

        let scope = try await bridge.resolveStatementScope(connectionId: id, database: nil, schema: nil)
        let statement = try await bridge.plannedStatement(scope: scope, query: "DELETE FROM orders WHERE id = 1", maxRows: 10)
        let operation = try await ApprovedOperationFixture.approve([statement], scope: scope, databaseType: .mysql)
        _ = try await bridge.runStatement(operation, maxRows: 10, timeoutSeconds: 30, cancellation: nil)

        #expect(DatabaseManager.shared.session(for: id)?.resolvedBrowseDatabase == "")
        #expect(scope.database == "production")
        let deleted = try #require(driver.events.lastIndex(of: "DELETE FROM orders WHERE id = 1"))
        #expect(driver.events[..<deleted].last { $0.hasPrefix("DATABASE") } == "DATABASE production")
    }

    @Test("A DELETE approved naming no database is refused once a call pinned the driver to production")
    func pinAfterANoDatabaseApprovalRefuses() async throws {
        let (id, driver) = session(.mysql, database: "")
        defer { DatabaseManager.shared.removeSession(for: id) }
        let bridge = DatabaseAccessBridge()
        let scope = try await bridge.resolveStatementScope(connectionId: id, database: nil, schema: nil)
        let statement = try await bridge.plannedStatement(scope: scope, query: "DELETE FROM orders WHERE id = 1", maxRows: 10)
        let operation = try await ApprovedOperationFixture.approve([statement], scope: scope, databaseType: .mysql)

        try await pinToProduction(id, bridge: bridge)
        let error = await #expect(throws: DatabaseAccessError.self) {
            _ = try await bridge.runStatement(operation, maxRows: 10, timeoutSeconds: 30, cancellation: nil)
        }

        #expect(scope.isServerScoped)
        #expect(error?.message == DatabaseAccessBridge.connectionChanged.message)
        #expect(!driver.events.contains { $0.hasPrefix("DELETE") })
    }

    @Test("A DELETE approved naming no database is refused once a USE may have moved the connection")
    func useAfterANoDatabaseApprovalRefuses() async throws {
        let (id, driver) = session(.mysql, database: "")
        defer { DatabaseManager.shared.removeSession(for: id) }
        let bridge = DatabaseAccessBridge()
        let scope = try await bridge.resolveStatementScope(connectionId: id, database: nil, schema: nil)
        let statement = try await bridge.plannedStatement(scope: scope, query: "DELETE FROM orders WHERE id = 1", maxRows: 10)
        let operation = try await ApprovedOperationFixture.approve([statement], scope: scope, databaseType: .mysql)

        _ = try await bridge.runStatement(scope: scope, query: "USE production", maxRows: 10, timeoutSeconds: 30, cancellation: nil)
        let error = await #expect(throws: DatabaseAccessError.self) {
            _ = try await bridge.runStatement(operation, maxRows: 10, timeoutSeconds: 30, cancellation: nil)
        }

        #expect(error?.message == DatabaseAccessBridge.databaseUnknown.message)
        #expect(!driver.events.contains { $0.hasPrefix("DELETE") })
    }

    @Test("After a USE on a driver that reports its database, a scope naming none names the database it reports")
    func reportedDatabaseAnswersAfterAUse() async throws {
        let (id, driver) = session(.mysql, database: "")
        defer { DatabaseManager.shared.removeSession(for: id) }
        let bridge = DatabaseAccessBridge()
        let unnamed = try await bridge.resolveStatementScope(connectionId: id, database: nil, schema: nil)

        driver.reportedDatabase = "staging"
        _ = try await bridge.runStatement(scope: unnamed, query: "USE staging", maxRows: 10, timeoutSeconds: 30, cancellation: nil)
        let scope = try await bridge.resolveStatementScope(connectionId: id, database: nil, schema: nil)

        #expect(unnamed.isServerScoped)
        #expect(scope.database == "staging")
    }

    // The bridge refuses a text that is only comments as empty, so it runs from an editor tab, straight on the driver.
    @Test("A DELETE approved naming no database is refused after a USE behind more comment versions than are read")
    func useBehindTooManyVersionsRefuses() async throws {
        let (id, driver) = session(.mysql, database: "")
        defer { DatabaseManager.shared.removeSession(for: id) }
        let bridge = DatabaseAccessBridge()
        let scope = try await bridge.resolveStatementScope(connectionId: id, database: nil, schema: nil)
        let statement = try await bridge.plannedStatement(scope: scope, query: "DELETE FROM orders WHERE id = 1", maxRows: 10)
        let operation = try await ApprovedOperationFixture.approve([statement], scope: scope, databaseType: .mysql)
        let versions = (10_000...10_032).map { "/*!\($0) */" }.joined(separator: " ")
        let sessionDriver = try #require(DatabaseManager.shared.driver(for: id))

        _ = try await sessionDriver.execute(query: "/*! USE production */ \(versions)")
        let error = await #expect(throws: DatabaseAccessError.self) {
            _ = try await bridge.runStatement(operation, maxRows: 10, timeoutSeconds: 30, cancellation: nil)
        }

        #expect(error?.message == DatabaseAccessBridge.databaseUnknown.message)
        #expect(!driver.events.contains { $0.hasPrefix("DELETE") })
    }

    // The SQL Server stand-in plugin connects for real, and SQL Server reads USE as MySQL does.
    @Test("A startup USE leaves the database unknown after connect and again after a reconnect")
    func startupUseLeavesTheDatabaseUnknown() async throws {
        FakeMSSQLPluginRegistration.registerIfNeeded()
        var connection = TestFixtures.makeConnection(database: "", type: .mssql)
        connection.startupCommands = "USE production"
        let bridge = DatabaseAccessBridge()
        func unnamedDeleteIsRefused() async {
            let error = await #expect(throws: DatabaseAccessError.self) {
                _ = try await bridge.resolveStatementScope(connectionId: connection.id, database: nil, schema: nil)
            }
            #expect(error?.message == DatabaseAccessBridge.databaseUnknown.message)
        }
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        try await DatabaseManager.shared.ensureConnected(connection)
        await unnamedDeleteIsRefused()
        try await DatabaseManager.shared.reconnectSession(connection.id)
        await unnamedDeleteIsRefused()

        #expect(DatabaseManager.shared.session(for: connection.id)?.resolvedBrowseDatabase == "")
        await DatabaseManager.shared.stopHealthMonitor(for: connection.id)
        DatabaseManager.shared.driver(for: connection.id)?.disconnect()
    }

    private func approvedNoDatabaseDrop(on id: UUID, bridge: DatabaseAccessBridge) async throws -> ApprovedOperation {
        let scope = try await bridge.resolveStatementScope(connectionId: id, database: nil, schema: nil)
        let statement = try await bridge.plannedStatement(scope: scope, query: "DROP TABLE orders", maxRows: 10)
        return try await ApprovedOperationFixture.approve([statement], scope: scope, databaseType: .mssql)
    }

    // The plan fails, as it can, and the USE it ran under SHOWPLAN stays: an error does not move the session back.
    @Test("On SQL Server a pending DROP naming no database is refused after an analyzed plan of USE production")
    func analyzedPlanOfAUseRefusesAPendingDrop() async throws {
        let (id, driver) = session(.mssql, database: "")
        defer { DatabaseManager.shared.removeSession(for: id) }
        let bridge = DatabaseAccessBridge()
        let drop = try await approvedNoDatabaseDrop(on: id, bridge: bridge)
        let explain = try await ApprovedOperationFixture.approve(
            [OperationStatement(sql: "USE production")], scope: drop.scope, databaseType: .mssql
        )

        _ = try? await bridge.runExplainPlan(
            explain,
            step: ExplainRequest.DriverStep(variantId: "actual", runsStatement: true),
            timeoutSeconds: 30,
            cancellation: nil
        )
        let error = await #expect(throws: DatabaseAccessError.self) {
            _ = try await bridge.runStatement(drop, maxRows: 10, timeoutSeconds: 30, cancellation: nil)
        }

        #expect(drop.scope.isServerScoped)
        #expect(error?.message == DatabaseAccessBridge.databaseUnknown.message)
        #expect(!driver.events.contains { $0.hasPrefix("DROP") })
    }

    @Test("An in-app Explain of USE production leaves a pending approval naming no database refused")
    func inAppExplainOfAUseRefusesAPendingDrop() async throws {
        let (id, driver) = session(.mssql, database: "")
        defer { DatabaseManager.shared.removeSession(for: id) }
        let bridge = DatabaseAccessBridge()
        let drop = try await approvedNoDatabaseDrop(on: id, bridge: bridge)
        let sessionDriver = try #require(DatabaseManager.shared.driver(for: id))

        _ = try? await QueryExecutor.fetchExplainPlan(driver: sessionDriver, statement: "USE production", variantId: "estimated")
        let error = await #expect(throws: DatabaseAccessError.self) {
            _ = try await bridge.runStatement(drop, maxRows: 10, timeoutSeconds: 30, cancellation: nil)
        }

        #expect(error?.message == DatabaseAccessBridge.databaseUnknown.message)
        #expect(!driver.events.contains { $0.hasPrefix("DROP") })
    }

    @Test("A DELETE approved naming no database is refused after EXECUTE IMMEDIATE 'USE production'")
    func executeImmediateUseRefusesAPendingDelete() async throws {
        let (id, driver) = session(.mysql, database: "")
        defer { DatabaseManager.shared.removeSession(for: id) }
        let bridge = DatabaseAccessBridge()
        let scope = try await bridge.resolveStatementScope(connectionId: id, database: nil, schema: nil)
        let statement = try await bridge.plannedStatement(scope: scope, query: "DELETE FROM orders WHERE id = 1", maxRows: 10)
        let operation = try await ApprovedOperationFixture.approve([statement], scope: scope, databaseType: .mysql)

        _ = try await bridge.runStatement(
            scope: scope, query: "EXECUTE IMMEDIATE 'USE production'", maxRows: 10, timeoutSeconds: 30, cancellation: nil
        )
        let error = await #expect(throws: DatabaseAccessError.self) {
            _ = try await bridge.runStatement(operation, maxRows: 10, timeoutSeconds: 30, cancellation: nil)
        }

        #expect(error?.message == DatabaseAccessBridge.databaseUnknown.message)
        #expect(!driver.events.contains { $0.hasPrefix("DELETE") })
    }

    // The real driver, not connected: the statement is counted before it fails, as one that ran would be.
    @Test("ClickHouse with no database runs SELECT 1, then a call naming none resolves to the database it reports")
    func clickHouseAnswersWithItsRequestDatabase() async throws {
        let plugin = try BundledPlugin.driver("ClickHouseDriver").init()
        let connection = TestFixtures.makeConnection(database: "", type: .clickhouse)
        let pluginDriver = plugin.createDriver(config: DriverConnectionConfig(
            host: "127.0.0.1", port: 8_123, username: "", password: "", database: ""
        ))
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: pluginDriver)
        )
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let sessionDriver = try #require(DatabaseManager.shared.driver(for: connection.id))

        _ = try? await sessionDriver.execute(query: "SELECT 1")
        let scope = try await DatabaseAccessBridge().resolveStatementScope(
            connectionId: connection.id, database: nil, schema: nil
        )

        #expect(sessionDriver.databaseMoves > 0)
        #expect(scope.database == (sessionDriver as? DatabaseReporting)?.currentDatabase)
    }
}
