//
//  ScopedDriverPinningTests.swift
//  TableProTests
//
//  What a scoped lease guarantees, and what running on the session driver directly does not.
//  A maintenance statement names its table and nothing else, so the connection's current database
//  decides where it lands, and nothing tracks where that is.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Scoped driver pinning", .serialized)
@MainActor
struct ScopedDriverPinningTests {
    private static func seed(
        browseDatabase: String
    ) -> (connection: DatabaseConnection, recorder: CallRecordingPluginDriver) {
        let connection = TestFixtures.makeConnection(database: browseDatabase, type: .mysql)
        let recorder = CallRecordingPluginDriver()
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: recorder)
        )
        session.browseDatabase = browseDatabase
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return (connection, recorder)
    }

    @Test("A scoped statement moves the connection onto its own database before it runs")
    func pinsBeforeRunningTheStatement() async throws {
        let (connection, recorder) = Self.seed(browseDatabase: "app")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let scope = DatabaseScope(connectionId: connection.id, database: "logs", schema: nil)
        try await DatabaseManager.shared.withScopedDriver(
            scope: scope,
            route: DatabaseManager.shared.executionRoute(for: scope),
            cancellation: .protectedWrite
        ) { driver in
            _ = try await driver.execute(query: "OPTIMIZE TABLE `role_ability`")
        }

        #expect(recorder.calls == ["switch:logs", "execute:OPTIMIZE TABLE `role_ability`"])
    }

    /// The half that made an unscoped statement dangerous. A lease moves the shared connection and
    /// deliberately writes no session state back, so the browse cursor still says `app` while the
    /// handle sits on `logs`. Anything that then runs on the session driver without a scope of its
    /// own inherits `logs` and reports success against the wrong database.
    @Test("A lease leaves the shared connection on its database and the browse cursor untouched")
    func leavesTheConnectionWhereTheLeasePutIt() async throws {
        let (connection, recorder) = Self.seed(browseDatabase: "app")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let scope = DatabaseScope(connectionId: connection.id, database: "logs", schema: nil)
        try await DatabaseManager.shared.withScopedDriver(
            scope: scope,
            route: DatabaseManager.shared.executionRoute(for: scope),
            cancellation: .protectedWrite
        ) { driver in
            _ = try await driver.execute(query: "SELECT 1")
        }

        #expect(recorder.currentDatabase == "logs")
        #expect(DatabaseManager.shared.session(for: connection.id)?.resolvedBrowseDatabase == "app")
    }

    @Test("A statement scoped to the browsed database is pinned back onto it")
    func pinsBackOntoTheBrowsedDatabase() async throws {
        let (connection, recorder) = Self.seed(browseDatabase: "app")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let foreign = DatabaseScope(connectionId: connection.id, database: "logs", schema: nil)
        try await DatabaseManager.shared.withScopedDriver(
            scope: foreign,
            route: DatabaseManager.shared.executionRoute(for: foreign),
            cancellation: .cancellableRead
        ) { driver in
            _ = try await driver.execute(query: "SELECT 1")
        }

        let browsed = try #require(DatabaseManager.shared.browseScope(for: connection.id))
        recorder.reset()
        try await DatabaseManager.shared.withScopedDriver(
            scope: browsed,
            route: DatabaseManager.shared.executionRoute(for: browsed),
            cancellation: .protectedWrite
        ) { driver in
            _ = try await driver.execute(query: "OPTIMIZE TABLE `role_ability`")
        }

        #expect(recorder.calls == ["switch:app", "execute:OPTIMIZE TABLE `role_ability`"])
        #expect(recorder.currentDatabase == "app")
    }
}

/// Records the order of the two calls that decide where a statement lands.
private final class CallRecordingPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var database: String?

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var currentDatabase: String? {
        lock.lock()
        defer { lock.unlock() }
        return database
    }

    func reset() {
        lock.lock()
        recorded = []
        lock.unlock()
    }

    private func record(_ call: String) {
        lock.lock()
        recorded.append(call)
        lock.unlock()
    }

    func switchDatabase(to database: String) async throws {
        lock.withLock { self.database = database }
        record("switch:\(database)")
    }

    func execute(query: String) async throws -> PluginQueryResult {
        record("execute:\(query)")
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func connect() async throws {}
    func disconnect() {}
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
