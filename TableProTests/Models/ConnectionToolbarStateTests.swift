//
//  ConnectionToolbarStateTests.swift
//  TableProTests
//
//  Tests for the state the toolbar and the menu bar validate against.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
@Suite("ConnectionToolbarState")
struct ConnectionToolbarStateTests {
    // MARK: - reset

    @Test("reset clears database, schema, and grouping strategy")
    func resetClearsScopeFields() {
        let state = ConnectionToolbarState()
        state.databaseGroupingStrategy = .bySchema
        state.currentDatabase = "Sales"
        state.currentSchema = "dbo"

        state.reset()

        #expect(state.currentDatabase == "")
        #expect(state.currentSchema == nil)
        #expect(state.databaseGroupingStrategy == .byDatabase)
    }

    // MARK: - query timing

    /// The status bar that draws this belongs to one tab, so an untagged duration would report a
    /// background tab's query under the rows of the tab on screen.
    @Test("A duration is only offered to the tab that produced it")
    func queryTimingIsScopedToItsTab() {
        let state = ConnectionToolbarState()
        let ran = UUID()
        let other = UUID()

        state.recordQueryTiming(PluginQueryTiming(total: 1.5), for: ran)

        #expect(state.queryTiming(forTab: ran)?.total == 1.5)
        #expect(state.queryTiming(forTab: other) == nil)
    }

    /// A failure on one tab says nothing about the duration another tab is still showing.
    @Test("Clearing a duration from another tab leaves it standing")
    func clearingFromAnotherTabIsIgnored() {
        let state = ConnectionToolbarState()
        let ran = UUID()
        state.recordQueryTiming(PluginQueryTiming(total: 1.5), for: ran)

        state.clearQueryTiming(forTab: UUID())
        #expect(state.queryTiming(forTab: ran)?.total == 1.5)

        state.clearQueryTiming(forTab: ran)
        #expect(state.queryTiming(forTab: ran) == nil)
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
