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
}
