//
//  QuickSwitcherObjectKindTests.swift
//  TableProTests
//
//  Open Quickly groups a materialized view with views for its icon and label, and used to open it
//  as one: its tab carried no kind, so the Structure tab refused Add Index with "A view cannot have
//  indexes." The row now hands over the kind it was built from. (#2522)
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Quick Switcher object kind")
@MainActor
struct QuickSwitcherObjectKindTests {
    @Test("A cross-connection row keeps the table type it was built from")
    func crossConnectionItemsCarryTheType() {
        let target = QuickSwitcherTarget(
            connectionId: UUID(), connectionName: "Primary", databaseName: "shop", schemaName: "public"
        )
        let items = QuickSwitcherViewModel.makeCrossConnectionItems(
            tables: [
                TableInfo(name: "daily_totals", type: .materializedView, rowCount: nil),
                TableInfo(name: "orders", type: .partitionedTable, rowCount: nil)
            ],
            target: target
        )

        #expect(items.map(\.tableType) == [.materializedView, .partitionedTable])
        #expect(items.first?.kind == .view)
        #expect(items.map(\.isReadOnly) == [true, false])
    }

    @Test("Opening a materialized view from the Quick Switcher gives its tab the matview kind")
    func openingAMaterializedViewKeepsTheKind() throws {
        let connection = TestFixtures.makeConnection(database: "shop", type: .postgresql)
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        let item = QuickSwitcherItem(
            id: QuickSwitcherItem.tableItemId(name: "daily_totals", schema: "public"),
            name: "daily_totals",
            kind: .view,
            subtitle: String(localized: "Materialized View"),
            isReadOnly: true,
            schemaName: "public",
            tableType: .materializedView
        )
        coordinator.handleQuickSwitcherSelection(item)

        let tab = try #require(tabManager.selectedTab)
        #expect(tab.tableContext.tableName == "daily_totals")
        #expect(tab.tableContext.objectType == .materializedView)
        #expect(tab.tableContext.resolvedObjectKind() == .materializedView)
    }

    @Test("Opening a partitioned table from the Quick Switcher keeps it partitioned")
    func openingAPartitionedTableKeepsTheKind() throws {
        let connection = TestFixtures.makeConnection(database: "shop", type: .postgresql)
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        let item = QuickSwitcherItem(
            id: QuickSwitcherItem.tableItemId(name: "events", schema: "public"),
            name: "events",
            kind: .table,
            subtitle: String(localized: "Partitioned Table"),
            schemaName: "public",
            tableType: .partitionedTable
        )
        coordinator.handleQuickSwitcherSelection(item)

        #expect(tabManager.selectedTab?.tableContext.objectType == .partitionedTable)
    }
}
