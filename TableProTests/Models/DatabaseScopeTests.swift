//
//  DatabaseScopeTests.swift
//  TableProTests
//
//  Pins the tab-binding half of #2026: a scope names the database and schema an
//  operation runs against, it is resolved once, and it never re-derives itself from
//  wherever the sidebar happens to be browsing.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("DatabaseScope")
struct DatabaseScopeTests {
    @Test("A blank database is server scoped, not unbound")
    func blankDatabaseIsServerScoped() {
        let connectionId = UUID()

        let serverScoped = DatabaseScope(connectionId: connectionId, database: "", schema: "public")
        #expect(serverScoped.isServerScoped)
        #expect(serverScoped.database.isEmpty)

        let bound = DatabaseScope(connectionId: connectionId, database: "shop", schema: nil)
        #expect(!bound.isServerScoped)
    }

    @Test("A blank schema normalises to nil")
    func blankSchemaNormalisesToNil() throws {
        let connectionId = UUID()

        let blank = DatabaseScope(connectionId: connectionId, database: "shop", schema: "")
        #expect(blank.schema == nil)

        let missing = DatabaseScope(connectionId: connectionId, database: "shop", schema: nil)
        #expect(missing.schema == nil)

        let present = DatabaseScope(connectionId: connectionId, database: "shop", schema: "sales")
        #expect(present.schema == "sales")
    }

    @Test("qualifiedDescription names the schema only when there is one")
    func qualifiedDescription() throws {
        let connectionId = UUID()

        let flat = DatabaseScope(connectionId: connectionId, database: "shop", schema: nil)
        #expect(flat.qualifiedDescription == "shop")

        let nested = DatabaseScope(connectionId: connectionId, database: "shop", schema: "sales")
        #expect(nested.qualifiedDescription == "shop.sales")
    }

    @Test("Two scopes on different databases are never equal")
    func scopesOnDifferentDatabasesDiffer() throws {
        let connectionId = UUID()

        let alpha = DatabaseScope(connectionId: connectionId, database: "alpha", schema: nil)
        let beta = DatabaseScope(connectionId: connectionId, database: "beta", schema: nil)

        #expect(alpha != beta)
    }
}

@Suite("DatabaseManager scope resolution", .serialized)
@MainActor
struct DatabaseManagerScopeResolutionTests {
    private static func makeSession(
        driverDatabase: String?,
        driverSchema: String? = nil,
        savedDatabase: String = "saved_default"
    ) -> DatabaseConnection {
        let connection = TestFixtures.makeConnection(database: savedDatabase)
        var session = ConnectionSession(connection: connection)
        session.driverDatabase = driverDatabase
        session.driverSchema = driverSchema
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return connection
    }

    @Test("An explicit database passes through untouched while the sidebar browses elsewhere")
    func explicitDatabaseIsNotRewritten() throws {
        let connection = Self.makeSession(driverDatabase: "inventory")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let scope = try #require(
            DatabaseManager.shared.resolvedScope(database: "orders", schema: nil, for: connection.id)
        )

        #expect(scope.database == "orders")
        #expect(scope.connectionId == connection.id)
    }

    @Test("Only a blank database falls back to the browse cursor")
    func blankDatabaseFallsBackToBrowseCursor() throws {
        let connection = Self.makeSession(driverDatabase: "inventory")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let blank = try #require(
            DatabaseManager.shared.resolvedScope(database: "", schema: nil, for: connection.id)
        )
        #expect(blank.database == "inventory")

        let missing = try #require(
            DatabaseManager.shared.resolvedScope(database: nil, schema: nil, for: connection.id)
        )
        #expect(missing.database == "inventory")
    }

    @Test("A blank browse cursor falls back to the connection's saved default database")
    func blankBrowseCursorUsesSavedDefault() throws {
        let connection = Self.makeSession(driverDatabase: nil, savedDatabase: "saved_default")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let scope = try #require(
            DatabaseManager.shared.resolvedScope(database: nil, schema: nil, for: connection.id)
        )

        #expect(scope.database == "saved_default")
    }

    @Test("A resolved scope keeps its database after the browse cursor moves")
    func resolvedScopeSurvivesABrowseCursorMove() throws {
        let connection = Self.makeSession(driverDatabase: "alpha")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let scope = try #require(
            DatabaseManager.shared.resolvedScope(database: nil, schema: nil, for: connection.id)
        )
        #expect(scope.database == "alpha")

        var moved = try #require(DatabaseManager.shared.session(for: connection.id))
        moved.driverDatabase = "beta"
        DatabaseManager.shared.injectSession(moved, for: connection.id)

        #expect(scope.database == "alpha")
        #expect(DatabaseManager.shared.driverScope(for: connection.id)?.database == "beta")
    }

    @Test("An explicit schema passes through and a blank one resolves to the browse schema")
    func schemaResolution() throws {
        let connection = Self.makeSession(driverDatabase: "orders", driverSchema: "dbo")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let explicit = try #require(
            DatabaseManager.shared.resolvedScope(database: "orders", schema: "sales", for: connection.id)
        )
        #expect(explicit.schema == "sales")

        let inherited = try #require(
            DatabaseManager.shared.resolvedScope(database: "orders", schema: "", for: connection.id)
        )
        #expect(inherited.schema == "dbo")
    }

    @Test("Without a session there is neither a browse scope nor an inferred scope")
    func noSessionYieldsNoScope() {
        let connectionId = UUID()

        #expect(DatabaseManager.shared.driverScope(for: connectionId) == nil)
        #expect(DatabaseManager.shared.resolvedScope(database: nil, schema: nil, for: connectionId) == nil)
        #expect(
            DatabaseManager.shared.resolvedScope(database: "orders", schema: nil, for: connectionId)?.database
                == "orders"
        )
    }
}
