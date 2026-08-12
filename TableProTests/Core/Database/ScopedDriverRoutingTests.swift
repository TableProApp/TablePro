//
//  ScopedDriverRoutingTests.swift
//  TableProTests
//
//  Where a scoped operation runs. The route is decided from plugin capabilities, never
//  from a database-type list, because `DatabaseType` is open (#2026).
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Scoped driver routing", .serialized)
@MainActor
struct ScopedDriverRoutingTests {
    private static func makeSession(
        type: DatabaseType,
        driverDatabase: String
    ) -> DatabaseConnection {
        let connection = TestFixtures.makeConnection(database: driverDatabase, type: type)
        var session = ConnectionSession(connection: connection)
        session.driverDatabase = driverDatabase
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return connection
    }

    private static func scope(_ connection: DatabaseConnection, database: String) -> DatabaseScope {
        DatabaseScope(connectionId: connection.id, database: database, schema: nil)
    }

    @Test("A pin-capable engine keeps the user's SQL on the session driver")
    func pinCapableEngineUsesTheSessionDriver() throws {
        let connection = Self.makeSession(type: .mysql, driverDatabase: "inventory")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let foreign = Self.scope(connection, database: "orders")

        #expect(DatabaseManager.shared.executionRoute(for: foreign) == .sessionDriver)
    }

    @Test("A reconnect-required engine stays on the session driver for its own database")
    func reconnectRequiredEngineStaysOnItsOwnDatabase() throws {
        let connection = Self.makeSession(type: .postgresql, driverDatabase: "orders")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let own = Self.scope(connection, database: "orders")

        #expect(DatabaseManager.shared.executionRoute(for: own) == .sessionDriver)
    }

    @Test("A connection with no database selected still runs on the session driver")
    func serverScopedWorkStaysOnTheSessionDriver() {
        let connection = Self.makeSession(type: .mysql, driverDatabase: "")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let serverScoped = Self.scope(connection, database: "")

        #expect(serverScoped.isServerScoped)
        #expect(DatabaseManager.shared.executionRoute(for: serverScoped) == .sessionDriver)
        #expect(DatabaseManager.shared.metadataRoute(for: serverScoped) == .sessionDriver)
    }

    @Test("A reconnect-required engine runs a foreign database on a pooled connection")
    func reconnectRequiredEngineOnAForeignDatabasePools() throws {
        let connection = Self.makeSession(type: .postgresql, driverDatabase: "inventory")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let foreign = Self.scope(connection, database: "orders")

        #expect(DatabaseManager.shared.executionRoute(for: foreign) == .pooled)
    }

    @Test("An engine that can neither pin nor pool reports the tab's database instead of guessing")
    func engineThatCanNeitherPinNorPoolIsUnavailable() throws {
        let connection = Self.makeSession(type: .pglite, driverDatabase: "inventory")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        #expect(DatabaseType.pglite.supportsConnectionPooling == false)
        #expect(PluginManager.shared.requiresReconnectForDatabaseSwitch(for: .pglite))

        let foreign = Self.scope(connection, database: "orders")

        guard case .unavailable(let message) = DatabaseManager.shared.executionRoute(for: foreign) else {
            Issue.record("Expected .unavailable for an engine that can neither pin nor pool")
            return
        }
        #expect(message.contains("orders"))
    }

    @Test("A single-database engine never leaves the session driver")
    func singleDatabaseEnginesNeverLeaveTheSessionDriver() throws {
        for type in [DatabaseType.sqlite, DatabaseType.duckdb] {
            let connection = Self.makeSession(type: type, driverDatabase: "main")
            defer { DatabaseManager.shared.removeSession(for: connection.id) }

            #expect(PluginManager.shared.supportsDatabaseSwitching(for: type) == false)

            let own = Self.scope(connection, database: "main")
            let foreign = Self.scope(connection, database: "another_file")

            #expect(DatabaseManager.shared.executionRoute(for: own) == .sessionDriver)
            #expect(
                DatabaseManager.shared.executionRoute(for: foreign) == .sessionDriver,
                "A second read-write handle on the same file would fight the session driver's lock"
            )
        }
    }

    @Test("A metadata read on a poolable engine leaves the shared driver where it is")
    func metadataReadsPoolWhenTheEngineCan() throws {
        let connection = Self.makeSession(type: .mysql, driverDatabase: "inventory")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let foreign = Self.scope(connection, database: "orders")

        #expect(DatabaseManager.shared.metadataRoute(for: foreign) == .pooled)
    }

    @Test("A metadata read falls back to the session driver when the engine cannot pool")
    func metadataReadsFallBackToTheSessionDriver() throws {
        let connection = Self.makeSession(type: .pglite, driverDatabase: "inventory")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let scope = Self.scope(connection, database: "orders")

        #expect(DatabaseManager.shared.metadataRoute(for: scope) == .sessionDriver)
    }

    @Test("An engine that selects its database from a connection field is never pooled")
    func connectionFieldScopedEngineIsNeverPooled() throws {
        let connection = Self.makeSession(type: .redis, driverDatabase: "0")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let scope = Self.scope(connection, database: "3")

        #expect(DatabaseManager.shared.metadataRoute(for: scope) == .sessionDriver)
        #expect(DatabaseManager.shared.executionRoute(for: scope) == .sessionDriver)
    }

    @Test("Without a session every route is unavailable")
    func noSessionIsAlwaysUnavailable() throws {
        let orphan = DatabaseScope(connectionId: UUID(), database: "orders", schema: nil)

        guard case .unavailable = DatabaseManager.shared.executionRoute(for: orphan) else {
            Issue.record("Expected .unavailable execution route without a session")
            return
        }
        guard case .unavailable = DatabaseManager.shared.metadataRoute(for: orphan) else {
            Issue.record("Expected .unavailable metadata route without a session")
            return
        }
    }
}
