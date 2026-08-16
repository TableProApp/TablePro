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
        browseDatabase: String
    ) -> DatabaseConnection {
        let connection = TestFixtures.makeConnection(database: browseDatabase, type: type)
        var session = ConnectionSession(connection: connection)
        session.browseDatabase = browseDatabase
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return connection
    }

    private static func scope(_ connection: DatabaseConnection, database: String) -> DatabaseScope {
        DatabaseScope(connectionId: connection.id, database: database, schema: nil)
    }

    /// A schema name only means something inside its own database. Inheriting the browsed
    /// schema into a scope naming another database made the sidebar ask a newly attached
    /// DuckDB catalog for a schema that lives in a different one, and DuckDB rejected the
    /// whole read, so the attached database never listed its schemas.
    @Test("A scope on another database does not inherit the browsed schema")
    func foreignDatabaseScopeDoesNotInheritSchema() throws {
        let connection = Self.makeSession(type: .duckdb, browseDatabase: "analytics")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        DatabaseManager.shared.updateSession(connection.id) { $0.browseSchema = "sales" }

        let own = DatabaseManager.shared.resolvedScope(
            database: "analytics", schema: nil, for: connection.id
        )
        #expect(own?.schema == "sales", "The browsed database still inherits the browsed schema")

        let attached = DatabaseManager.shared.resolvedScope(
            database: "warehouse", schema: nil, for: connection.id
        )
        #expect(attached?.schema == nil, "A different database must not inherit 'sales'")

        let explicit = DatabaseManager.shared.resolvedScope(
            database: "warehouse", schema: "staging", for: connection.id
        )
        #expect(explicit?.schema == "staging", "An explicit schema still passes through")
    }

    @Test("A pin-capable engine keeps the user's SQL on the session driver")
    func pinCapableEngineUsesTheSessionDriver() throws {
        let connection = Self.makeSession(type: .mysql, browseDatabase: "inventory")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let foreign = Self.scope(connection, database: "orders")

        #expect(DatabaseManager.shared.executionRoute(for: foreign) == .sessionDriver)
    }

    @Test("A reconnect-required engine stays on the session driver for its own database")
    func reconnectRequiredEngineStaysOnItsOwnDatabase() throws {
        let connection = Self.makeSession(type: .postgresql, browseDatabase: "orders")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let own = Self.scope(connection, database: "orders")

        #expect(DatabaseManager.shared.executionRoute(for: own) == .sessionDriver)
    }

    @Test("A connection with no database selected still runs on the session driver")
    func serverScopedWorkStaysOnTheSessionDriver() {
        let connection = Self.makeSession(type: .mysql, browseDatabase: "")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let serverScoped = Self.scope(connection, database: "")

        #expect(serverScoped.isServerScoped)
        #expect(DatabaseManager.shared.executionRoute(for: serverScoped) == .sessionDriver)
        #expect(DatabaseManager.shared.metadataRoute(for: serverScoped) == .sessionDriver)
    }

    @Test("A reconnect-required engine runs a foreign database on a pooled connection")
    func reconnectRequiredEngineOnAForeignDatabasePools() throws {
        let connection = Self.makeSession(type: .postgresql, browseDatabase: "inventory")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let foreign = Self.scope(connection, database: "orders")

        #expect(DatabaseManager.shared.executionRoute(for: foreign) == .pooled)
    }

    @Test("An engine that can neither pin nor pool reports the tab's database instead of guessing")
    func engineThatCanNeitherPinNorPoolIsUnavailable() throws {
        let connection = Self.makeSession(type: .pglite, browseDatabase: "inventory")
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
        let connection = Self.makeSession(type: .sqlite, browseDatabase: "main")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        #expect(PluginManager.shared.supportsDatabaseSwitching(for: .sqlite) == false)

        let own = Self.scope(connection, database: "main")
        let foreign = Self.scope(connection, database: "another_file")

        #expect(DatabaseManager.shared.executionRoute(for: own) == .sessionDriver)
        #expect(
            DatabaseManager.shared.executionRoute(for: foreign) == .sessionDriver,
            "A second read-write handle on the same file would fight the session driver's lock"
        )
    }

    /// DuckDB switches catalog with `USE` on the live connection, so it declares database
    /// switching, but it still must not pool: a second `duckdb_open` is a different
    /// database. Switching in place is exactly what keeps every scope on the one driver.
    @Test("An embedded engine that switches catalogs stays on the session driver")
    func embeddedCatalogSwitchingStaysOnTheSessionDriver() throws {
        let connection = Self.makeSession(type: .duckdb, browseDatabase: "main")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        #expect(PluginManager.shared.supportsDatabaseSwitching(for: .duckdb) == true)
        #expect(PluginManager.shared.requiresReconnectForDatabaseSwitch(for: .duckdb) == false)

        let own = Self.scope(connection, database: "main")
        let attached = Self.scope(connection, database: "another_file")

        #expect(DatabaseManager.shared.executionRoute(for: own) == .sessionDriver)
        #expect(
            DatabaseManager.shared.executionRoute(for: attached) == .sessionDriver,
            "An ATTACH'd catalog lives on the same connection, so there is nothing to pool to"
        )
    }

    @Test("An embedded engine keeps its metadata reads on the session driver too")
    func embeddedEnginesNeverPoolMetadataReads() throws {
        let connection = Self.makeSession(type: .duckdb, browseDatabase: "memory")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        #expect(DatabaseType.duckdb.supportsConnectionPooling == false)

        let browsed = Self.scope(connection, database: "memory")

        #expect(
            DatabaseManager.shared.metadataRoute(for: browsed) == .sessionDriver,
            "A second duckdb_open is a different database, so a pooled read lists nothing (#2108)"
        )
    }

    @Test("A metadata read on a poolable engine leaves the shared driver where it is")
    func metadataReadsPoolWhenTheEngineCan() throws {
        let connection = Self.makeSession(type: .mysql, browseDatabase: "inventory")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let foreign = Self.scope(connection, database: "orders")

        #expect(DatabaseManager.shared.metadataRoute(for: foreign) == .pooled)
    }

    @Test("A metadata read falls back to the session driver when the engine cannot pool")
    func metadataReadsFallBackToTheSessionDriver() throws {
        let connection = Self.makeSession(type: .pglite, browseDatabase: "inventory")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let scope = Self.scope(connection, database: "orders")

        #expect(DatabaseManager.shared.metadataRoute(for: scope) == .sessionDriver)
    }

    @Test("An engine that selects its database from a connection field is never pooled")
    func connectionFieldScopedEngineIsNeverPooled() throws {
        let connection = Self.makeSession(type: .redis, browseDatabase: "0")
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
