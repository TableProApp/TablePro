//
//  ConnectionToolbarStateTests.swift
//  TableProTests
//
//  Tests for the toolbar chip's grouping-aware text resolution.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
@Suite("ConnectionToolbarState")
struct ConnectionToolbarStateTests {
    // MARK: - scopeComponents

    @Test("A database-only engine shows just its database")
    func scopeComponentsByDatabase() {
        let state = ConnectionToolbarState()
        state.databaseType = .mysql
        state.databaseGroupingStrategy = .byDatabase
        state.currentDatabase = "myappdb"
        state.currentSchema = "ignored"

        #expect(state.scopeComponents.map(\.name) == ["myappdb"])
        #expect(state.scopeComponents.map(\.kind) == [.database])
    }

    /// The chip used to show only the schema here while its click switched the database. Both
    /// scopes are now present, each with its own chooser (#2196).
    @Test("A schema-grouped engine shows its database and its schema")
    func scopeComponentsBySchema() {
        let state = ConnectionToolbarState()
        state.databaseType = .postgresql
        state.databaseGroupingStrategy = .bySchema
        state.currentDatabase = "Sales"
        state.currentSchema = "dbo"

        #expect(state.scopeComponents.map(\.name) == ["Sales", "dbo"])
        #expect(state.scopeComponents.map(\.kind) == [.database, .schema])
    }

    @Test("An unresolved schema leaves only the database component")
    func scopeComponentsBySchemaWithNilSchema() {
        let state = ConnectionToolbarState()
        state.databaseType = .postgresql
        state.databaseGroupingStrategy = .bySchema
        state.currentDatabase = "Sales"
        state.currentSchema = nil

        #expect(state.scopeComponents.map(\.name) == ["Sales"])
    }

    @Test("An empty schema leaves only the database component")
    func scopeComponentsBySchemaWithEmptySchema() {
        let state = ConnectionToolbarState()
        state.databaseType = .postgresql
        state.databaseGroupingStrategy = .bySchema
        state.currentDatabase = "Sales"
        state.currentSchema = ""

        #expect(state.scopeComponents.map(\.name) == ["Sales"])
    }

    @Test("A flat engine shows just its database (Redis, MongoDB)")
    func scopeComponentsFlat() {
        let state = ConnectionToolbarState()
        state.databaseType = .redis
        state.databaseGroupingStrategy = .flat
        state.currentDatabase = "0"
        state.currentSchema = "ignored"

        #expect(state.scopeComponents.map(\.name) == ["0"])
        #expect(state.scopeComponents.map(\.isSwitchable) == [false])
    }

    // MARK: - reset

    @Test("reset clears database, schema, and grouping strategy")
    func resetClearsAllChipFields() {
        let state = ConnectionToolbarState()
        state.databaseGroupingStrategy = .bySchema
        state.currentDatabase = "Sales"
        state.currentSchema = "dbo"

        state.reset()

        #expect(state.currentDatabase == "")
        #expect(state.currentSchema == nil)
        #expect(state.databaseGroupingStrategy == .byDatabase)
        #expect(state.scopeComponents.isEmpty)
    }

    // MARK: - syncFromSession

    @Test("syncFromSession resolves currentDatabase from connection when no session exists")
    func syncFromSessionFallsBackToConnectionDatabase() {
        let connection = TestFixtures.makeConnection(database: "Production", type: .postgresql)
        let state = ConnectionToolbarState()

        state.syncFromSession(for: connection)

        #expect(state.currentDatabase == "Production")
    }

    // MARK: - safe mode

    @Test("syncFromSession falls back to the connection's saved safe mode when no session exists")
    func syncFromSessionFallsBackToConnectionSafeMode() {
        var connection = TestFixtures.makeConnection()
        connection.safeModeLevel = .readOnly
        let state = ConnectionToolbarState()

        state.syncFromSession(for: connection)

        #expect(state.safeModeLevel == .readOnly)
    }

    @Test("A new toolbar state adopts the live session safe mode, not the stale saved default")
    func newToolbarStateAdoptsLiveSessionSafeMode() {
        let id = UUID()
        var connection = TestFixtures.makeConnection(id: id)
        connection.safeModeLevel = .silent
        DatabaseManager.shared.injectSession(ConnectionSession(connection: connection), for: id)
        DatabaseManager.shared.setSafeModeLevel(.readOnly, for: id)
        defer { DatabaseManager.shared.removeSession(for: id) }

        let state = ConnectionToolbarState(connection: connection)

        #expect(state.safeModeLevel == .readOnly)
    }
}
