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
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct WindowSidebarStateTests {
    @Test
    func twoInstancesHoldIndependentSelection() {
        let windowA = WindowSidebarState()
        let windowB = WindowSidebarState()

        let users = TestFixtures.makeTableRef(name: "users")
        windowA.selectedTables = [users]

        #expect(windowA.selectedTables == [users])
        #expect(windowB.selectedTables.isEmpty)
    }

    @Test("A window with nothing selected accepts the open document's mark")
    func acceptsTheMarkWhenNothingIsSelected() {
        #expect(WindowSidebarState().acceptsObjectMarkRefresh)
    }

    @Test("A table the user picked without opening it survives a background reload")
    func refusesTheMarkOverASingleUserPick() {
        let state = WindowSidebarState()
        state.select(tables: [TestFixtures.makeTableRef(name: "orders")], rowCount: 1)

        #expect(!state.acceptsObjectMarkRefresh)
    }

    @Test("A batch selection survives a background reload")
    func refusesTheMarkOverAMultiRowSelection() {
        let state = WindowSidebarState()
        state.select(
            tables: [
                TestFixtures.makeTableRef(name: "orders"),
                TestFixtures.makeTableRef(name: "users"),
            ],
            rowCount: 2
        )

        #expect(!state.acceptsObjectMarkRefresh)
    }

    @Test("A selected row that is not a table survives a background reload")
    func refusesTheMarkOverANonTableRow() {
        let state = WindowSidebarState()
        state.select(tables: [], rowCount: 1)

        #expect(!state.acceptsObjectMarkRefresh)
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

    @Test("Object group expansion defaults by kind and persists per scope")
    func objectGroupExpansionPersistsPerScope() throws {
        let defaults = try makeDefaults()
        let connectionId = UUID()
        let publicTables = DatabaseTreeObjectGroup(database: "shop", schema: "public", kind: .table)
        let auditTables = DatabaseTreeObjectGroup(database: "shop", schema: "audit", kind: .table)
        let publicViews = DatabaseTreeObjectGroup(database: "shop", schema: "public", kind: .view)

        let state = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        #expect(state.isTreeObjectGroupExpanded(publicTables))
        #expect(state.isTreeObjectGroupExpanded(publicViews) == false)
        state.setTreeObjectGroup(publicTables, expanded: false)
        state.setTreeObjectGroup(publicViews, expanded: true)

        let restored = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        #expect(restored.isTreeObjectGroupExpanded(publicTables) == false)
        #expect(restored.isTreeObjectGroupExpanded(auditTables))
        #expect(restored.isTreeObjectGroupExpanded(publicViews))
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
        #expect(restored.treeObjectGroupExpansion.isEmpty)
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

    /// Object kinds are an open set, so a build that has never heard of one still has to read the
    /// rest of the blob. Decoding the kind as an enum threw and took every other expansion set with
    /// it, including the seed flag, which reopened containers the user had closed.
    @Test("An unrecognized object kind does not discard the rest of the expansion")
    func unknownObjectKindKeepsOtherExpansion() throws {
        let defaults = try makeDefaults()
        let connectionId = UUID()
        let stored = """
        {"schemas":["public"],"databases":["shop"],"databaseSchemas":[],"tables":[],\
        "objectGroups":[{"database":"shop","schema":"public","kind":"sequence","expanded":true},\
        {"database":"shop","schema":"public","kind":"view","expanded":true}],"seeded":true}
        """
        defaults.set(Data(stored.utf8), forKey: "com.TablePro.sidebar.treeExpansion.\(connectionId.uuidString)")

        let restored = WindowSidebarState(connectionId: connectionId, defaults: defaults)

        #expect(restored.expandedTreeDatabases == ["shop"])
        #expect(restored.expandedTreeSchemas == ["public"])
        #expect(restored.didSeedExpansion)
        #expect(restored.treeObjectGroupExpansion.count == 1)
        #expect(
            restored.isTreeObjectGroupExpanded(
                DatabaseTreeObjectGroup(database: "shop", schema: "public", kind: .view)
            )
        )
    }

    @Test("A window without a connection does not persist")
    func nilConnectionDoesNotPersist() throws {
        let defaults = try makeDefaults()
        let state = WindowSidebarState(connectionId: nil, defaults: defaults)
        state.expandedTreeDatabases.insert("x")
        #expect(state.expandedTreeDatabases == ["x"])
    }
}
