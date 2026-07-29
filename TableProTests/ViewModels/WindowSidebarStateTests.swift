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

    @Test("Expanded partitioned tables persist and restore")
    func persistsExpandedPartitionedTables() throws {
        let defaults = try makeDefaults()
        let connectionId = UUID()
        let orders = DatabaseTableKey(database: "shop", schema: "public", table: "orders")

        let state = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        state.expandedTreeTables.insert(orders)

        let restored = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        #expect(restored.expandedTreeTables == [orders])
    }

    @Test("A schema-less table key stays distinct from a schema-qualified one")
    func partitionedTableKeysDistinguishSchema() throws {
        let defaults = try makeDefaults()
        let connectionId = UUID()
        let qualified = DatabaseTableKey(database: "shop", schema: "public", table: "orders")
        let unqualified = DatabaseTableKey(database: "shop", schema: nil, table: "orders")

        let state = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        state.expandedTreeTables = [qualified, unqualified]

        let restored = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        #expect(restored.expandedTreeTables.count == 2)
        #expect(restored.expandedTreeTables.contains(qualified))
        #expect(restored.expandedTreeTables.contains(unqualified))
    }

    @Test("Expansion saved before partitions shipped still decodes")
    func decodesExpansionWrittenBeforePartitionSupport() throws {
        let defaults = try makeDefaults()
        let connectionId = UUID()
        let legacy = """
            {"schemas":["public"],"databases":["shop"],"databaseSchemas":[{"database":"shop","schema":"public"}]}
            """
        defaults.set(Data(legacy.utf8), forKey: "com.TablePro.sidebar.treeExpansion.\(connectionId.uuidString)")

        let restored = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        #expect(restored.expandedTreeDatabases == ["shop"])
        #expect(restored.expandedTreeSchemas == ["public"])
        #expect(restored.expandedTreeTables.isEmpty)
    }

    @Test("Collapsing every partitioned table clears storage alongside the rest")
    func clearingPartitionedTablesRemovesStorage() throws {
        let defaults = try makeDefaults()
        let connectionId = UUID()

        let state = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        state.expandedTreeTables.insert(DatabaseTableKey(database: "shop", schema: "public", table: "orders"))
        state.expandedTreeTables.removeAll()

        let restored = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        #expect(restored.expandedTreeTables.isEmpty)
    }

    @Test("A window without a connection does not persist")
    func nilConnectionDoesNotPersist() throws {
        let defaults = try makeDefaults()
        let state = WindowSidebarState(connectionId: nil, defaults: defaults)
        state.expandedTreeDatabases.insert("x")
        #expect(state.expandedTreeDatabases == ["x"])
    }
}
