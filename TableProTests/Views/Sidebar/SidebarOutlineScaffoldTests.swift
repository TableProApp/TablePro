//
//  SidebarOutlineScaffoldTests.swift
//  TableProTests
//

import AppKit
import os
import SwiftUI
import TableProPluginKit
import TableProSyncTransport
import Testing

@testable import TablePro

/// The two sidebar lists are configured from one place now. They had drifted apart on exactly the
/// settings nobody looks at twice, so these assert the settings rather than the drift.
@Suite("Sidebar outline scaffold")
@MainActor
struct SidebarOutlineScaffoldTests {
    private func makeScrollView(
        multipleSelection: Bool = true,
        rowSize: SidebarRowSizePreference = .matchSystem
    ) -> NSScrollView {
        SidebarOutlineScaffold.makeScrollView(
            outlineView: NSOutlineView(),
            configuration: SidebarOutlineScaffold.Configuration(
                columnIdentifier: "TestColumn",
                allowsMultipleSelection: multipleSelection,
                rowSizePreference: rowSize
            )
        )
    }

    private func outline(_ scrollView: NSScrollView) throws -> NSOutlineView {
        try #require(scrollView.documentView as? NSOutlineView)
    }

    @Test("Both lists get the source list style and no header")
    func configuresAsASourceList() throws {
        let outlineView = try outline(makeScrollView())

        #expect(outlineView.style == .sourceList)
        #expect(outlineView.headerView == nil)
        #expect(outlineView.floatsGroupRows == false)
    }

    /// Expansion is per connection, and while a filter is active it is the search's rather than the
    /// user's. Neither fits AppKit's single global autosave record.
    @Test("Expansion is never autosaved by AppKit")
    func doesNotAutosaveExpansion() throws {
        #expect(try outline(makeScrollView()).autosaveExpandedItems == false)
    }

    @Test("The outline column is created and set as the outline column")
    func createsTheOutlineColumn() throws {
        let outlineView = try outline(makeScrollView())

        #expect(outlineView.tableColumns.count == 1)
        #expect(outlineView.outlineTableColumn === outlineView.tableColumns.first)
    }

    @Test("Multiple selection follows the caller")
    func multipleSelectionIsConfigurable() throws {
        #expect(try outline(makeScrollView(multipleSelection: true)).allowsMultipleSelection)
        #expect(try outline(makeScrollView(multipleSelection: false)).allowsMultipleSelection == false)
    }

    /// The scroller style is the user's "Show scroll bars" setting, so the scaffold must leave it
    /// alone. One of the two lists used to force overlay scrollers.
    @Test("The scroll view leaves the system scroller preference alone")
    func doesNotOverrideScrollerStyle() {
        let scrollView = makeScrollView()

        #expect(scrollView.scrollerStyle == NSScroller.preferredScrollerStyle)
        #expect(scrollView.autohidesScrollers)
        #expect(scrollView.hasVerticalScroller)
        #expect(scrollView.hasHorizontalScroller == false)
    }

    @Test("The list draws no background of its own, so the sidebar material shows through")
    func drawsNoBackground() throws {
        let scrollView = makeScrollView()

        #expect(scrollView.drawsBackground == false)
        #expect(try outline(scrollView).backgroundColor == .clear)
    }

    @Test("An explicit row size reaches the outline, and Match System defers to AppKit")
    func appliesTheRowSize() throws {
        #expect(try outline(makeScrollView(rowSize: .large)).rowSizeStyle == .large)
        #expect(try outline(makeScrollView(rowSize: .matchSystem)).rowSizeStyle == .default)
    }

    @Test("A row size change is applied to a list already on screen")
    func reappliesRowSizeOnUpdate() throws {
        let scrollView = makeScrollView(rowSize: .small)
        #expect(try outline(scrollView).rowSizeStyle == .small)

        SidebarOutlineScaffold.applyRowSize(.large, to: scrollView)

        #expect(try outline(scrollView).rowSizeStyle == .large)
    }
}

@Suite("Database tree object group hierarchy")
@MainActor
struct DatabaseTreeObjectGroupHierarchyTests {
    /// The outline coalesces its selection sync onto the next main-actor hop, so the assertion waits
    /// for the highlight rather than for the task that moves it. It waits for the row it expects,
    /// because "no row yet" and "the wrong row" are the same reading otherwise.
    private func selectionSettles(in outlineView: NSOutlineView, on expected: DatabaseTreeNode) async -> Bool {
        for _ in 0 ..< 8 {
            if outlineView.selectedRow >= 0,
               outlineView.item(atRow: outlineView.selectedRow) as? DatabaseTreeNode === expected {
                return true
            }
            await Task.yield()
        }
        return false
    }

    @Test("Nested groups preserve depth and partition expansion")
    func nestedGroupsPreserveDepth() async throws {
        let connectionId = UUID()
        let defaults = try #require(UserDefaults(suiteName: "tree-groups-\(UUID().uuidString)"))
        let windowState = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        let database = DatabaseTreeNode(id: "database", kind: .database(.minimal(name: "shop")))
        let schema = DatabaseTreeNode(id: "schema", kind: .schema(database: "shop", schema: "public"))
        let groupRef = DatabaseTreeObjectGroup(database: "shop", schema: "public", kind: .table)
        let group = DatabaseTreeNode(id: "group", kind: .containerObjectKindSection(groupRef))
        let parentRef = DatabaseTreeTableRef(
            database: "shop",
            schema: "public",
            table: TableInfo(name: "orders", type: .partitionedTable, rowCount: nil, schema: "public")
        )
        let childRef = DatabaseTreeTableRef(
            database: "shop",
            schema: "public",
            table: TableInfo(name: "orders_2026", type: .table, rowCount: nil, schema: "public")
        )
        let parent = DatabaseTreeNode(id: "parent", kind: .table(parentRef))
        let child = DatabaseTreeNode(id: "child", kind: .table(childRef))
        windowState.expandedTreeDatabases = ["shop"]
        windowState.expandedTreeDatabaseSchemas = [DatabaseSchemaKey(database: "shop", schema: "public")]
        windowState.expandedTreeTables = [
            DatabaseTableKey(database: "shop", schema: "public", table: "orders")
        ]

        let scrollView = SidebarOutlineScaffold.makeScrollView(
            outlineView: NSOutlineView(),
            configuration: SidebarOutlineScaffold.Configuration(
                columnIdentifier: "TreeGroupColumn",
                allowsMultipleSelection: true,
                rowSizePreference: .medium
            )
        )
        let outlineView = try #require(scrollView.documentView as? NSOutlineView)
        let coordinator = DatabaseTreeOutlineCoordinator()
        coordinator.connectionId = connectionId
        coordinator.databaseType = .postgresql
        coordinator.windowState = windowState
        coordinator.childrenCache = [
            "": [database],
            database.id: [schema],
            schema.id: [group],
            group.id: [parent],
            parent.id: [child]
        ]
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        coordinator.attach(outlineView: outlineView)
        outlineView.reloadData()

        coordinator.applyDesiredExpansion()

        #expect(outlineView.numberOfRows == 5)
        #expect(outlineView.level(forItem: group) == 2)
        #expect(outlineView.level(forItem: parent) == 3)
        #expect(outlineView.level(forItem: child) == 4)
        #expect(outlineView.isItemExpanded(group))
        #expect(outlineView.isItemExpanded(parent))
        #expect(coordinator.outlineView(outlineView, isGroupItem: group) == false)
        #expect(coordinator.outlineView(outlineView, shouldSelectItem: group))

        outlineView.collapseItem(parent)
        outlineView.collapseItem(group)
        outlineView.collapseItem(schema)
        windowState.setTreeObjectGroup(groupRef, expanded: true)
        windowState.expandedTreeTables.insert(
            DatabaseTableKey(database: "shop", schema: "public", table: "orders")
        )
        coordinator.activeDatabase = "shop"
        coordinator.nodeCache = [database.id: database, schema.id: schema, group.id: group]
        windowState.selectTables([parentRef.table])
        coordinator.syncSelectionToModel()
        coordinator.nodeCache[parent.id] = parent

        outlineView.expandItem(schema)

        #expect(outlineView.isItemExpanded(group))
        #expect(outlineView.isItemExpanded(parent))
        #expect(outlineView.selectedRow == -1)
        #expect(await selectionSettles(in: outlineView, on: parent))
    }

    @Test("Collapsed groups keep model selection adoption pending")
    func collapsedGroupsKeepSelectionPending() async throws {
        let connectionId = UUID()
        let defaults = try #require(UserDefaults(suiteName: "tree-group-selection-\(UUID().uuidString)"))
        let windowState = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        let tableRef = DatabaseTreeTableRef(
            database: "shop",
            schema: "public",
            table: TableInfo(name: "orders", type: .table, rowCount: nil, schema: "public")
        )
        let viewRef = DatabaseTreeTableRef(
            database: "shop",
            schema: "public",
            table: TableInfo(name: "order_totals", type: .view, rowCount: nil, schema: "public")
        )
        let table = DatabaseTreeNode(id: "table", kind: .table(tableRef))
        let groupRef = DatabaseTreeObjectGroup(database: "shop", schema: "public", kind: .view)
        let group = DatabaseTreeNode(id: "views", kind: .containerObjectKindSection(groupRef))
        let view = DatabaseTreeNode(id: "view", kind: .table(viewRef))
        let scrollView = SidebarOutlineScaffold.makeScrollView(
            outlineView: NSOutlineView(),
            configuration: SidebarOutlineScaffold.Configuration(
                columnIdentifier: "TreeGroupSelectionColumn",
                allowsMultipleSelection: true,
                rowSizePreference: .medium
            )
        )
        let outlineView = try #require(scrollView.documentView as? NSOutlineView)
        let coordinator = DatabaseTreeOutlineCoordinator()
        coordinator.connectionId = connectionId
        coordinator.windowState = windowState
        coordinator.childrenCache = ["": [table, group], group.id: [view]]
        coordinator.nodeCache = [table.id: table, group.id: group]
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        coordinator.attach(outlineView: outlineView)
        outlineView.reloadData()

        windowState.selectTables([tableRef.table])
        coordinator.syncSelectionToModel()
        #expect(outlineView.item(atRow: outlineView.selectedRow) as? DatabaseTreeNode === table)

        windowState.selectTables([viewRef.table])
        coordinator.syncSelectionToModel()
        #expect(outlineView.selectedRow == -1)

        windowState.selectTables([tableRef.table])
        coordinator.syncSelectionToModel()
        #expect(outlineView.item(atRow: outlineView.selectedRow) as? DatabaseTreeNode === table)

        windowState.selectTables([viewRef.table])
        coordinator.syncSelectionToModel()
        coordinator.nodeCache[view.id] = view
        outlineView.expandItem(group)

        #expect(outlineView.isItemExpanded(group))
        #expect(outlineView.selectedRow == -1)
        #expect(await selectionSettles(in: outlineView, on: view))
    }

    @Test("Selection adoption distinguishes identical objects across databases")
    func selectionAdoptionUsesTheActiveDatabase() async throws {
        let connectionId = UUID()
        let defaults = try #require(UserDefaults(suiteName: "tree-group-database-\(UUID().uuidString)"))
        let windowState = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        let table = TableInfo(name: "report", type: .view, rowCount: nil, schema: "public")
        let oldRef = DatabaseTreeTableRef(database: "archive", schema: "public", table: table)
        let activeRef = DatabaseTreeTableRef(database: "shop", schema: "public", table: table)
        let oldView = DatabaseTreeNode(id: "archive-view", kind: .table(oldRef))
        let groupRef = DatabaseTreeObjectGroup(database: "shop", schema: "public", kind: .view)
        let group = DatabaseTreeNode(id: "shop-views", kind: .containerObjectKindSection(groupRef))
        let activeView = DatabaseTreeNode(id: "shop-view", kind: .table(activeRef))
        let scrollView = SidebarOutlineScaffold.makeScrollView(
            outlineView: NSOutlineView(),
            configuration: SidebarOutlineScaffold.Configuration(
                columnIdentifier: "TreeGroupDatabaseColumn",
                allowsMultipleSelection: true,
                rowSizePreference: .medium
            )
        )
        let outlineView = try #require(scrollView.documentView as? NSOutlineView)
        let coordinator = DatabaseTreeOutlineCoordinator()
        coordinator.connectionId = connectionId
        coordinator.windowState = windowState
        coordinator.activeDatabase = "archive"
        coordinator.childrenCache = ["": [oldView, group], group.id: [activeView]]
        coordinator.nodeCache = [oldView.id: oldView, group.id: group]
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        coordinator.attach(outlineView: outlineView)
        outlineView.reloadData()

        windowState.selectTables([table])
        coordinator.syncSelectionToModel()
        #expect(outlineView.item(atRow: outlineView.selectedRow) as? DatabaseTreeNode === oldView)

        coordinator.activeDatabase = "shop"
        coordinator.syncSelectionToModel()
        #expect(outlineView.selectedRow == -1)

        coordinator.nodeCache[activeView.id] = activeView
        outlineView.expandItem(group)

        #expect(await selectionSettles(in: outlineView, on: activeView))
    }

    /// Two tables selected at once still belong to one database. Adopting by name alone highlighted
    /// a same-named table in another database's folder as well, and sent the inflated row count on
    /// to every command that reads the selection.
    @Test("A multi-selection adopts only rows in the active database")
    func multiTableAdoptionScopesToTheActiveDatabase() async throws {
        let connectionId = UUID()
        let defaults = try #require(UserDefaults(suiteName: "tree-group-multi-\(UUID().uuidString)"))
        let windowState = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        let orders = TableInfo(name: "orders", type: .table, rowCount: nil, schema: "public")
        let report = TableInfo(name: "report", type: .table, rowCount: nil, schema: "public")
        let shopOrders = DatabaseTreeNode(
            id: "shop-orders",
            kind: .table(DatabaseTreeTableRef(database: "shop", schema: "public", table: orders))
        )
        let shopReport = DatabaseTreeNode(
            id: "shop-report",
            kind: .table(DatabaseTreeTableRef(database: "shop", schema: "public", table: report))
        )
        let archiveOrders = DatabaseTreeNode(
            id: "archive-orders",
            kind: .table(DatabaseTreeTableRef(database: "archive", schema: "public", table: orders))
        )
        let archiveReport = DatabaseTreeNode(
            id: "archive-report",
            kind: .table(DatabaseTreeTableRef(database: "archive", schema: "public", table: report))
        )
        let scrollView = SidebarOutlineScaffold.makeScrollView(
            outlineView: NSOutlineView(),
            configuration: SidebarOutlineScaffold.Configuration(
                columnIdentifier: "TreeGroupMultiColumn",
                allowsMultipleSelection: true,
                rowSizePreference: .medium
            )
        )
        let outlineView = try #require(scrollView.documentView as? NSOutlineView)
        let coordinator = DatabaseTreeOutlineCoordinator()
        coordinator.connectionId = connectionId
        coordinator.windowState = windowState
        coordinator.activeDatabase = "shop"
        coordinator.childrenCache = ["": [shopOrders, shopReport, archiveOrders, archiveReport]]
        coordinator.nodeCache = [
            shopOrders.id: shopOrders,
            shopReport.id: shopReport,
            archiveOrders.id: archiveOrders,
            archiveReport.id: archiveReport
        ]
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        coordinator.attach(outlineView: outlineView)
        outlineView.reloadData()

        windowState.selectTables([orders, report])
        coordinator.syncSelectionToModel()

        let selected = outlineView.selectedRowIndexes.compactMap {
            outlineView.item(atRow: $0) as? DatabaseTreeNode
        }
        #expect(selected.count == 2)
        #expect(selected.contains { $0 === shopOrders })
        #expect(selected.contains { $0 === shopReport })
        #expect(selected.allSatisfy { $0 !== archiveOrders && $0 !== archiveReport })
    }

    /// Collapsing a kind folder hides the selected row, and AppKit rewriting the outline selection is
    /// not a pick. The model keeps the table, so the highlight comes back when the folder reopens.
    @Test("Collapsing a kind folder keeps the model selection")
    func collapsingAGroupKeepsTheModelSelection() async throws {
        let connectionId = UUID()
        let defaults = try #require(UserDefaults(suiteName: "tree-group-collapse-\(UUID().uuidString)"))
        let windowState = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        let orders = TableInfo(name: "orders", type: .table, rowCount: nil, schema: "public")
        let schema = DatabaseTreeNode(id: "schema", kind: .schema(database: "shop", schema: "public"))
        let groupRef = DatabaseTreeObjectGroup(database: "shop", schema: "public", kind: .table)
        let group = DatabaseTreeNode(id: "group", kind: .containerObjectKindSection(groupRef))
        let table = DatabaseTreeNode(
            id: "table",
            kind: .table(DatabaseTreeTableRef(database: "shop", schema: "public", table: orders))
        )
        let scrollView = SidebarOutlineScaffold.makeScrollView(
            outlineView: NSOutlineView(),
            configuration: SidebarOutlineScaffold.Configuration(
                columnIdentifier: "TreeGroupCollapseColumn",
                allowsMultipleSelection: true,
                rowSizePreference: .medium
            )
        )
        let outlineView = try #require(scrollView.documentView as? NSOutlineView)
        let coordinator = DatabaseTreeOutlineCoordinator()
        coordinator.connectionId = connectionId
        coordinator.windowState = windowState
        coordinator.activeDatabase = "shop"
        coordinator.childrenCache = ["": [schema], schema.id: [group], group.id: [table]]
        coordinator.nodeCache = [schema.id: schema, group.id: group, table.id: table]
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        coordinator.attach(outlineView: outlineView)
        outlineView.reloadData()
        outlineView.expandItem(schema)
        outlineView.expandItem(group)

        windowState.selectTables([orders])
        coordinator.syncSelectionToModel()
        #expect(outlineView.item(atRow: outlineView.selectedRow) as? DatabaseTreeNode === table)

        outlineView.collapseItem(group)

        #expect(windowState.selectedTables == [orders])

        outlineView.expandItem(group)

        #expect(await selectionSettles(in: outlineView, on: table))

        /// The same mechanism hides the row when any container above it closes, so the schema level
        /// is pinned too rather than left to work by accident.
        outlineView.collapseItem(schema)

        #expect(windowState.selectedTables == [orders])

        outlineView.expandItem(schema)

        #expect(await selectionSettles(in: outlineView, on: table))
    }

    /// Opening a table in another database moves the browse database first, so for one turn the model
    /// still names the table the user navigated away from. Adopting it there deselected the row the
    /// user had just clicked.
    @Test("Opening a row in another database keeps that row selected")
    func selectionSurvivesACrossDatabaseOpen() throws {
        let connectionId = UUID()
        let defaults = try #require(UserDefaults(suiteName: "tree-group-open-\(UUID().uuidString)"))
        let windowState = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        let orders = TableInfo(name: "orders", type: .table, rowCount: nil, schema: "public")
        let report = TableInfo(name: "report", type: .table, rowCount: nil, schema: "public")
        let shopOrders = DatabaseTreeNode(
            id: "shop-orders",
            kind: .table(DatabaseTreeTableRef(database: "shop", schema: "public", table: orders))
        )
        let archiveReport = DatabaseTreeNode(
            id: "archive-report",
            kind: .table(DatabaseTreeTableRef(database: "archive", schema: "public", table: report))
        )
        let scrollView = SidebarOutlineScaffold.makeScrollView(
            outlineView: NSOutlineView(),
            configuration: SidebarOutlineScaffold.Configuration(
                columnIdentifier: "TreeGroupOpenColumn",
                allowsMultipleSelection: true,
                rowSizePreference: .medium
            )
        )
        let outlineView = try #require(scrollView.documentView as? NSOutlineView)
        let coordinator = DatabaseTreeOutlineCoordinator()
        coordinator.connectionId = connectionId
        coordinator.windowState = windowState
        coordinator.activeDatabase = "shop"
        coordinator.childrenCache = ["": [shopOrders, archiveReport]]
        coordinator.nodeCache = [shopOrders.id: shopOrders, archiveReport.id: archiveReport]
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        coordinator.attach(outlineView: outlineView)
        outlineView.reloadData()

        windowState.selectTables([orders])
        coordinator.syncSelectionToModel()
        #expect(outlineView.item(atRow: outlineView.selectedRow) as? DatabaseTreeNode === shopOrders)

        let archiveRow = outlineView.row(forItem: archiveReport)
        outlineView.selectRowIndexes(IndexSet(integer: archiveRow), byExtendingSelection: false)

        coordinator.activeDatabase = "archive"
        coordinator.syncSelectionToModel()

        #expect(outlineView.item(atRow: outlineView.selectedRow) as? DatabaseTreeNode === archiveReport)
    }

    /// One disclosure gesture is one edit of the saved layout. Every row the cascade reopened used to
    /// record itself too, rewriting the whole snapshot to `UserDefaults` once per row, on the main
    /// actor, inside the AppKit notification.
    @Test("One disclosure gesture persists the expansion snapshot once")
    func oneGesturePersistsOnce() throws {
        let connectionId = UUID()
        let defaults = try #require(WriteCountingDefaults(suiteName: "tree-group-writes-\(UUID().uuidString)"))
        let windowState = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        let database = DatabaseTreeNode(id: "database", kind: .database(.minimal(name: "shop")))
        let schema = DatabaseTreeNode(id: "schema", kind: .schema(database: "shop", schema: "public"))
        let groupRef = DatabaseTreeObjectGroup(database: "shop", schema: "public", kind: .table)
        let group = DatabaseTreeNode(id: "group", kind: .containerObjectKindSection(groupRef))
        let parentRef = DatabaseTreeTableRef(
            database: "shop",
            schema: "public",
            table: TableInfo(name: "orders", type: .partitionedTable, rowCount: nil, schema: "public")
        )
        let parent = DatabaseTreeNode(id: "parent", kind: .table(parentRef))
        let child = DatabaseTreeNode(
            id: "child",
            kind: .table(
                DatabaseTreeTableRef(
                    database: "shop",
                    schema: "public",
                    table: TableInfo(name: "orders_2026", type: .table, rowCount: nil, schema: "public")
                )
            )
        )
        windowState.expandedTreeDatabases = ["shop"]
        windowState.expandedTreeTables = [
            DatabaseTableKey(database: "shop", schema: "public", table: "orders")
        ]

        let scrollView = SidebarOutlineScaffold.makeScrollView(
            outlineView: NSOutlineView(),
            configuration: SidebarOutlineScaffold.Configuration(
                columnIdentifier: "TreeGroupWriteColumn",
                allowsMultipleSelection: true,
                rowSizePreference: .medium
            )
        )
        let outlineView = try #require(scrollView.documentView as? NSOutlineView)
        let coordinator = DatabaseTreeOutlineCoordinator()
        coordinator.connectionId = connectionId
        coordinator.databaseType = .postgresql
        coordinator.windowState = windowState
        coordinator.childrenCache = [
            "": [database],
            database.id: [schema],
            schema.id: [group],
            group.id: [parent],
            parent.id: [child]
        ]
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        coordinator.attach(outlineView: outlineView)
        outlineView.reloadData()
        outlineView.expandItem(database)

        defaults.writeCount = 0
        outlineView.expandItem(schema)

        #expect(outlineView.isItemExpanded(group))
        #expect(outlineView.isItemExpanded(parent))
        #expect(defaults.writeCount == 1)
    }
}

private final class WriteCountingDefaults: UserDefaults {
    private let writes = OSAllocatedUnfairLock(initialState: 0)

    var writeCount: Int {
        get { writes.withLock { $0 } }
        set { writes.withLock { $0 = newValue } }
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        writes.withLock { $0 += 1 }
        super.set(value, forKey: defaultName)
    }
}

/// Both lists host their rows through one base now. They used to inset by different amounts, so the
/// two tabs of a single sidebar drew rows at different heights.
@Suite("Sidebar hosting cell")
@MainActor
struct SidebarHostingCellViewTests {
    @Test("A row is hosted once and its content swapped on reuse")
    func reusesTheHostingView() {
        let cell = SidebarHostingCellView<Text>()
        cell.update(rootView: Text("first"))
        let hosted = cell.hostedView

        cell.update(rootView: Text("second"))

        #expect(cell.hostedView === hosted)
        #expect(cell.subviews.filter { $0 is NSHostingView<Text> }.count == 1)
    }

    @Test("Both lists inset their content by the same amount")
    func sharesOneInset() {
        #expect(SidebarHostingCellView<Text>.contentInset == FavoritesOutlineCellView<Text>.contentInset)
    }
}

@Suite("Database tree favorite refresh", .serialized)
@MainActor
struct DatabaseTreeFavoriteRefreshTests {
    private static let width: CGFloat = 320
    private static let height: CGFloat = 120

    @Test("Adding and removing a favorite repaints every visible copy without replacing its host")
    func favoriteMutationRepaintsVisibleRows() throws {
        let favoritesSuite = "DatabaseTreeFavoriteRefreshTests.favorites.\(UUID().uuidString)"
        let syncSuite = "DatabaseTreeFavoriteRefreshTests.sync.\(UUID().uuidString)"
        let favoritesDefaults = try #require(UserDefaults(suiteName: favoritesSuite))
        let syncDefaults = try #require(UserDefaults(suiteName: syncSuite))
        favoritesDefaults.removePersistentDomain(forName: favoritesSuite)
        syncDefaults.removePersistentDomain(forName: syncSuite)
        defer {
            favoritesDefaults.removePersistentDomain(forName: favoritesSuite)
            syncDefaults.removePersistentDomain(forName: syncSuite)
        }

        let metadata = SyncMetadataStorage(userDefaults: syncDefaults)
        let tracker = SyncChangeTracker(metadataStorage: metadata)
        let storage = FavoriteTablesStorage(userDefaults: favoritesDefaults, syncTracker: tracker)
        let coordinator = DatabaseTreeOutlineCoordinator(favoriteTablesStorage: storage)
        let connectionId = UUID()
        let table = TableInfo(name: "orders", type: .table, rowCount: nil, schema: "public")
        let ref = DatabaseTreeTableRef(database: "shop", schema: "public", table: table)
        let ordinary = DatabaseTreeNode(id: DatabaseTreeNode.tableId(ref), kind: .table(ref))
        let recent = DatabaseTreeNode(id: DatabaseTreeNode.recentTableId(ref), kind: .recentTable(ref))
        let outlineView = NSOutlineView()
        let scrollView = SidebarOutlineScaffold.makeScrollView(
            outlineView: outlineView,
            configuration: SidebarOutlineScaffold.Configuration(
                columnIdentifier: "FavoriteRefreshColumn",
                allowsMultipleSelection: true,
                rowSizePreference: .medium
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = scrollView

        coordinator.connectionId = connectionId
        coordinator.databaseType = .sqlite
        coordinator.childrenCache[""] = [ordinary, recent]
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        coordinator.attach(outlineView: outlineView)
        outlineView.reloadData()
        settle(window)

        #expect(outlineView.numberOfRows == 2)
        let cells = try (0..<2).map { row in
            try #require(
                outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? DatabaseTreeCellView
            )
        }
        settle(window)
        let hosts = cells.map(\.hostedView)
        let unfavoritePixels = try cells.map(trailingPixels)

        coordinator.toggleFavorite(ref)
        settle(window)

        #expect(coordinator.isFavorite(ref))
        #expect(cells.indices.allSatisfy { cells[$0].hostedView === hosts[$0] })
        let favoritePixels = try cells.map(trailingPixels)
        #expect(zip(unfavoritePixels, favoritePixels).allSatisfy(!=))

        coordinator.toggleFavorite(ref)
        settle(window)

        #expect(!coordinator.isFavorite(ref))
        #expect(cells.indices.allSatisfy { cells[$0].hostedView === hosts[$0] })
        let removedPixels = try cells.map(trailingPixels)
        #expect(zip(favoritePixels, removedPixels).allSatisfy(!=))
    }

    @Test("Adding and removing a database favorite repaints its star in place")
    func databaseFavoriteMutationRepaintsVisibleRow() throws {
        let tableSuite = "DatabaseTreeFavoriteRefreshTests.tables.\(UUID().uuidString)"
        let databaseSuite = "DatabaseTreeFavoriteRefreshTests.databases.\(UUID().uuidString)"
        let syncSuite = "DatabaseTreeFavoriteRefreshTests.database-sync.\(UUID().uuidString)"
        let tableDefaults = try #require(UserDefaults(suiteName: tableSuite))
        let databaseDefaults = try #require(UserDefaults(suiteName: databaseSuite))
        let syncDefaults = try #require(UserDefaults(suiteName: syncSuite))
        defer {
            tableDefaults.removePersistentDomain(forName: tableSuite)
            databaseDefaults.removePersistentDomain(forName: databaseSuite)
            syncDefaults.removePersistentDomain(forName: syncSuite)
        }

        let metadata = SyncMetadataStorage(userDefaults: syncDefaults)
        let tracker = SyncChangeTracker(metadataStorage: metadata)
        let tableStorage = FavoriteTablesStorage(userDefaults: tableDefaults, syncTracker: tracker)
        let databaseStorage = FavoriteDatabasesStorage(defaults: databaseDefaults)
        let coordinator = DatabaseTreeOutlineCoordinator(
            favoriteTablesStorage: tableStorage,
            favoriteDatabasesStorage: databaseStorage
        )
        let connectionId = UUID()
        let database = DatabaseTreeNode(
            id: "database-shop",
            kind: .database(.minimal(name: "shop"))
        )
        let outlineView = NSOutlineView()
        let scrollView = SidebarOutlineScaffold.makeScrollView(
            outlineView: outlineView,
            configuration: SidebarOutlineScaffold.Configuration(
                columnIdentifier: "DatabaseFavoriteRefreshColumn",
                allowsMultipleSelection: true,
                rowSizePreference: .medium
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = scrollView

        coordinator.connectionId = connectionId
        coordinator.databaseType = .postgresql
        coordinator.childrenCache[""] = [database]
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        coordinator.attach(outlineView: outlineView)
        outlineView.reloadData()
        settle(window)

        let cell = try #require(
            outlineView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? DatabaseTreeCellView
        )
        settle(window)
        let host = cell.hostedView
        let unfavoritePixels = try trailingPixels(of: cell)

        databaseStorage.setFavorite(
            database: "shop",
            environment: .production,
            connectionId: connectionId
        )
        settle(window)

        #expect(coordinator.favoriteDatabaseEnvironments()["shop"] == .production)
        #expect(cell.hostedView === host)
        let favoritePixels = try trailingPixels(of: cell)
        #expect(unfavoritePixels != favoritePixels)

        databaseStorage.removeFavorite(database: "shop", connectionId: connectionId)
        settle(window)

        #expect(coordinator.favoriteDatabaseEnvironments()["shop"] == nil)
        #expect(cell.hostedView === host)
        #expect(try trailingPixels(of: cell) != favoritePixels)
    }

    private func settle(_ window: NSWindow) {
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        window.layoutIfNeeded()
    }

    private func trailingPixels(of view: NSView) throws -> Data {
        view.layoutSubtreeIfNeeded()
        let representation = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: representation)
        let bitmap = try #require(representation.bitmapData)
        let bytesPerPixel = try #require(representation.bitsPerPixel / 8 > 0 ? representation.bitsPerPixel / 8 : nil)
        let scale = CGFloat(representation.pixelsWide) / view.bounds.width
        let trailingWidth = min(representation.pixelsWide, Int((32 * scale).rounded(.up)))
        let startX = representation.pixelsWide - trailingWidth
        let rowByteCount = trailingWidth * bytesPerPixel
        var pixels = Data(capacity: rowByteCount * representation.pixelsHigh)
        for y in 0..<representation.pixelsHigh {
            let offset = y * representation.bytesPerRow + startX * bytesPerPixel
            pixels.append(bitmap.advanced(by: offset), count: rowByteCount)
        }
        return pixels
    }
}
