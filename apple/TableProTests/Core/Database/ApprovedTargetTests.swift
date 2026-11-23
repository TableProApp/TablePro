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

    var events: [String] { lock.withLock { recorded } }

    var transactionState: PluginSessionTransactionState {
        get { lock.withLock { state } }
        set { lock.withLock { state = newValue } }
    }

    func sessionTransactionState() async -> PluginSessionTransactionState { transactionState }

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

    @Test("A fixed-database engine is checked against the database it reaches, not a relabeled browse cursor")
    func fixedEngineChecksTheConnectedDatabase() async throws {
        let (id, _) = session(.oracle, database: "PROD", browseDatabase: "ARCHIVE")
        defer { DatabaseManager.shared.removeSession(for: id) }
        let bridge = DatabaseAccessBridge()

        await #expect(throws: DatabaseAccessError.self) {
            _ = try await bridge.resolveStatementScope(connectionId: id, database: "ARCHIVE", schema: nil)
        }
        let connected = try await bridge.resolveStatementScope(connectionId: id, database: "PROD", schema: nil)
        #expect(connected.database == "PROD")
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

    @Test("A fixed engine configured with no database checks against the one it browses, as BigQuery's project")
    func fixedEngineWithNoConfiguredDatabaseKeepsItsProject() async throws {
        var connection = TestFixtures.makeConnection(database: "", type: .bigQuery)
        connection.additionalFields["bqProjectId"] = "my-project"
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: CachedTargetDriver())
        )
        session.browseDatabase = "my-project"
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let bridge = DatabaseAccessBridge()

        let own = try await bridge.resolveScope(connectionId: connection.id, database: "my-project", schema: nil)
        #expect(own.database == "my-project")
        await #expect(throws: DatabaseAccessError.self) {
            _ = try await bridge.resolveScope(connectionId: connection.id, database: "other-project", schema: nil)
        }
    }
}
