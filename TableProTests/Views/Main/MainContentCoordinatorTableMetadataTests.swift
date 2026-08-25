//
//  MainContentCoordinatorTableMetadataTests.swift
//  TableProTests
//

import AppKit
import CodeEditSourceEditor
import Foundation
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("MainContentCoordinator table metadata cache")
@MainActor
struct MainContentCoordinatorTableMetadataTests {
    private func makeCoordinator() -> (MainContentCoordinator, QueryTabManager) {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        return (coordinator, tabManager)
    }

    private func addTableTab(to tabManager: QueryTabManager, tableName: String) -> QueryTab {
        var tab = QueryTab(
            title: tableName,
            query: "SELECT * FROM \(tableName)",
            tabType: .table,
            tableName: tableName
        )
        tab.execution.lastExecutedAt = Date()
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        return tab
    }

    private func metadata(_ tableName: String, rowCount: Int64) -> TableMetadata {
        TableMetadata(
            tableName: tableName,
            dataSize: nil,
            indexSize: nil,
            totalSize: nil,
            avgRowLength: nil,
            rowCount: rowCount,
            comment: nil,
            engine: nil,
            collation: nil,
            createTime: nil,
            updateTime: nil
        )
    }

    @Test("Alternating between two tables fetches once per table, not once per switch")
    func alternatingTabsHitTheCache() {
        let (coordinator, tabManager) = makeCoordinator()
        let orders = addTableTab(to: tabManager, tableName: "orders")
        let customers = addTableTab(to: tabManager, tableName: "customers")

        #expect(!coordinator.hasCurrentTableMetadata(for: orders, tableName: "orders"))
        coordinator.tableMetadataCache[orders.id] = TableMetadataCacheEntry(
            tableName: "orders",
            lastExecutedAt: orders.execution.lastExecutedAt,
            metadata: metadata("orders", rowCount: 10)
        )
        coordinator.tableMetadataCache[customers.id] = TableMetadataCacheEntry(
            tableName: "customers",
            lastExecutedAt: customers.execution.lastExecutedAt,
            metadata: metadata("customers", rowCount: 20)
        )

        #expect(coordinator.hasCurrentTableMetadata(for: orders, tableName: "orders"))
        #expect(coordinator.hasCurrentTableMetadata(for: customers, tableName: "customers"))
    }

    @Test("Re-running the tab's query makes its cached numbers stale")
    func reExecutingInvalidatesTheEntry() {
        let (coordinator, tabManager) = makeCoordinator()
        var orders = addTableTab(to: tabManager, tableName: "orders")
        coordinator.tableMetadataCache[orders.id] = TableMetadataCacheEntry(
            tableName: "orders",
            lastExecutedAt: orders.execution.lastExecutedAt,
            metadata: metadata("orders", rowCount: 10)
        )

        orders.execution.lastExecutedAt = Date(timeIntervalSince1970: 1)
        #expect(!coordinator.hasCurrentTableMetadata(for: orders, tableName: "orders"))
    }

    @Test("Retargeting a tab to another table makes its cached numbers stale")
    func retargetingInvalidatesTheEntry() {
        let (coordinator, tabManager) = makeCoordinator()
        let orders = addTableTab(to: tabManager, tableName: "orders")
        coordinator.tableMetadataCache[orders.id] = TableMetadataCacheEntry(
            tableName: "orders",
            lastExecutedAt: orders.execution.lastExecutedAt,
            metadata: metadata("orders", rowCount: 10)
        )

        #expect(!coordinator.hasCurrentTableMetadata(for: orders, tableName: "customers"))
    }

    @Test("A cached entry paints the panel without reaching the database")
    func cachedEntryPaintsThePanel() async {
        let (coordinator, tabManager) = makeCoordinator()
        let orders = addTableTab(to: tabManager, tableName: "orders")
        coordinator.tableMetadataCache[orders.id] = TableMetadataCacheEntry(
            tableName: "orders",
            lastExecutedAt: orders.execution.lastExecutedAt,
            metadata: metadata("orders", rowCount: 42)
        )

        await coordinator.loadTableMetadata(tableName: "orders", for: orders)
        #expect(coordinator.tableMetadata?.tableName == "orders")
        #expect(coordinator.tableMetadata?.rowCount == 42)
    }

    @Test("Closed tabs take their cached numbers with them")
    func closingATabPrunesTheEntry() {
        let (coordinator, tabManager) = makeCoordinator()
        let orders = addTableTab(to: tabManager, tableName: "orders")
        let customers = addTableTab(to: tabManager, tableName: "customers")
        coordinator.tableMetadataCache[orders.id] = TableMetadataCacheEntry(
            tableName: "orders",
            lastExecutedAt: orders.execution.lastExecutedAt,
            metadata: metadata("orders", rowCount: 10)
        )
        coordinator.tableMetadataCache[customers.id] = TableMetadataCacheEntry(
            tableName: "customers",
            lastExecutedAt: customers.execution.lastExecutedAt,
            metadata: metadata("customers", rowCount: 20)
        )

        coordinator.cleanupTabCaches(openTabIds: [customers.id])
        #expect(coordinator.tableMetadataCache[orders.id] == nil)
        #expect(coordinator.tableMetadataCache[customers.id] != nil)
    }
}
