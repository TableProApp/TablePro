//
//  ConnectionToolbarStateTests.swift
//  TableProTests
//
//  Tests for the state the toolbar and the menu bar validate against.
//

import Combine
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct ConnectionToolbarStateTests {
    // MARK: - reset

    @Test("reset clears the scope and every tab's duration")
    func resetClearsScopeFields() {
        let state = ConnectionToolbarState()
        state.currentDatabase = "Sales"
        state.currentSchema = "dbo"
        state.recordQueryTiming(PluginQueryTiming(total: 1.5), for: UUID())

        state.reset()

        #expect(state.currentDatabase == "")
        #expect(state.currentSchema == nil)
        #expect(state.queryTimings.isEmpty)
    }

    // MARK: - update(from:)

    @Test("update(from:) carries the name and icon the toolbar item draws")
    func updateCarriesNameAndIcon() {
        var connection = TestFixtures.makeConnection(name: "Prod")
        let state = ConnectionToolbarState(connection: connection)
        #expect(state.connectionName == "Prod")
        #expect(state.iconName == nil)

        connection.name = "Production"
        connection.iconName = "server.rack"
        state.update(from: connection)
        #expect(state.connectionName == "Production")
        #expect(state.iconName == "server.rack")

        connection.iconName = nil
        state.update(from: connection)
        #expect(state.iconName == nil)
    }

    /// Runs on every connection save and on a bulk iCloud pull, so an unchanged record must not
    /// wake every window's toolbar.
    @Test("A record that changed nothing the toolbar shows publishes nothing")
    func unchangedRecordIsSilent() {
        var connection = TestFixtures.makeConnection(name: "Prod")
        connection.iconName = "server.rack"
        let state = ConnectionToolbarState(connection: connection)
        var changes = 0
        let observation = state.objectWillChange.sink { changes += 1 }

        state.update(from: connection)

        #expect(changes == 0)
        observation.cancel()
    }

    @Test("reset forgets the name and icon")
    func resetClearsNameAndIcon() {
        var connection = TestFixtures.makeConnection(name: "Prod")
        connection.iconName = "server.rack"
        let state = ConnectionToolbarState(connection: connection)

        state.reset()

        #expect(state.connectionName.isEmpty)
        #expect(state.iconName == nil)
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
