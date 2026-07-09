//
//  WindowSidebarStateTests.swift
//  TableProTests
//
//  Pins per-window scoping of table selection. Regression guard for #1313 where
//  selectedTables was shared across windows of the same connection, causing
//  Cmd+T to jump focus back to a sibling window. Sidebar filter text is
//  connection-scoped and lives in SharedSidebarState; see SharedSidebarStateTests.
//  Also pins per-connection persistence of database-tree expansion.
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@MainActor
struct WindowSidebarStateTests {
    @Test
    func twoInstancesHoldIndependentSelection() {
        let windowA = WindowSidebarState()
        let windowB = WindowSidebarState()

        let users = TestFixtures.makeTableInfo(name: "users")
        windowA.selectedTables = [users]

        #expect(windowA.selectedTables == [users])
        #expect(windowB.selectedTables.isEmpty)
    }

    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "sidebar-tree-\(UUID().uuidString)"))
    }

    @Test("Tree expansion persists and restores across instances for a connection")
    func persistsAndRestores() throws {
        let defaults = try makeDefaults()
        let connectionId = UUID()

        let state = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        state.expandedTreeDatabases.insert("shop")
        state.expandedTreeSchemas.insert("public")
        state.expandedTreeDatabaseSchemas.insert(DatabaseSchemaKey(database: "shop", schema: "public"))

        let restored = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        #expect(restored.expandedTreeDatabases == ["shop"])
        #expect(restored.expandedTreeSchemas == ["public"])
        #expect(restored.expandedTreeDatabaseSchemas.contains(DatabaseSchemaKey(database: "shop", schema: "public")))
    }

    @Test("Different connections keep independent expansion")
    func connectionsAreIsolated() throws {
        let defaults = try makeDefaults()
        let first = UUID()
        let second = UUID()

        WindowSidebarState(connectionId: first, defaults: defaults).expandedTreeDatabases.insert("a")

        let secondState = WindowSidebarState(connectionId: second, defaults: defaults)
        #expect(secondState.expandedTreeDatabases.isEmpty)
    }

    @Test("Collapsing everything removes stored expansion")
    func clearingRemovesStorage() throws {
        let defaults = try makeDefaults()
        let connectionId = UUID()

        let state = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        state.expandedTreeDatabases.insert("shop")
        state.expandedTreeDatabases.removeAll()

        let restored = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        #expect(restored.expandedTreeDatabases.isEmpty)
    }

    @Test("A window without a connection does not persist")
    func nilConnectionDoesNotPersist() throws {
        let defaults = try makeDefaults()
        let state = WindowSidebarState(connectionId: nil, defaults: defaults)
        state.expandedTreeDatabases.insert("x")
        #expect(state.expandedTreeDatabases == ["x"])
    }
}
