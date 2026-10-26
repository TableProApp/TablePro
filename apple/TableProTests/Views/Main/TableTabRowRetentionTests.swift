//
//  TableTabRowRetentionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import TableProUtilities
import Testing

@MainActor
struct TableTabRowRetentionTests {
    private let fixtures = CoordinatorFixtures()
    private static let rowCount = 10

    private func makeCoordinator() -> (MainContentCoordinator, QueryTabManager) {
        let fixture = fixtures.make()
        return (fixture.coordinator, fixture.tabManager)
    }

    private func addLoadedTableTab(
        _ coordinator: MainContentCoordinator,
        _ tabManager: QueryTabManager,
        tableName: String
    ) -> UUID {
        var tab = QueryTab(title: tableName, query: "SELECT * FROM \(tableName)", tabType: .table, tableName: tableName)
        tab.execution.lastExecutedAt = Date()
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        let rows = (0..<Self.rowCount).map { [PluginCellValue.text("\($0)"), PluginCellValue.text("row \($0)")] }
        let tableRows = TableRows.from(
            queryRows: rows,
            columns: ["id", "name"],
            columnTypes: [.integer(rawType: nil), .text(rawType: nil)]
        )
        coordinator.setActiveTableRows(tableRows, for: tab.id)
        return tab.id
    }

    private func tab(_ id: UUID, in tabManager: QueryTabManager) throws -> QueryTab {
        try #require(tabManager.tabs.first { $0.id == id })
    }

    // The old budget eviction ran in the same deferred task as the cache prune, so the prune finishing means it would have run.
    @Test("Switching through more table tabs than the cache budget keeps every tab's rows")
    func switchingKeepsEveryTabsRows() async throws {
        let (coordinator, tabManager) = makeCoordinator()
        let ids = (0..<(GridDisplayCacheBudget.unmountedGrids() + 3)).map {
            addLoadedTableTab(coordinator, tabManager, tableName: "table_\($0)")
        }
        let oldestCache = coordinator.gridModel(forTab: ids[0]).display.cache
        oldestCache.setBox(RowDisplayBox(["formatted", nil]), forID: .existing(0))
        for id in ids.dropFirst() {
            _ = coordinator.gridModel(forTab: id)
        }

        let outgoing = ids[ids.count - 1]
        let incoming = ids[ids.count - 2]
        tabManager.selectedTabId = incoming
        coordinator.handleTabChange(from: outgoing, to: incoming, tabs: tabManager.tabs)
        try await waitUntil { oldestCache.box(forID: .existing(0)) == nil }

        for id in ids {
            let current = try tab(id, in: tabManager)
            #expect(coordinator.tabSessionRegistry.tableRows(for: id).rows.count == Self.rowCount)
            #expect(coordinator.canAutoLoadTableTab(current) == false)
        }
    }

    @Test("The prune releases only formatted text of grids off screen and used longest ago")
    func pruneReleasesOnlyOldUnmountedText() {
        let (coordinator, tabManager) = makeCoordinator()
        let ids = (0..<(GridDisplayCacheBudget.unmountedGrids() + 2)).map {
            addLoadedTableTab(coordinator, tabManager, tableName: "table_\($0)")
        }
        let caches = ids.map { id in
            let cache = coordinator.gridModel(forTab: id).display.cache
            cache.setBox(RowDisplayBox(["formatted", nil]), forID: .existing(0))
            return cache
        }

        coordinator.pruneGridDisplayCaches()

        #expect(caches[0].box(forID: .existing(0)) == nil)
        for cache in caches.dropFirst() {
            #expect(cache.box(forID: .existing(0)) != nil)
        }
        for id in ids {
            #expect(coordinator.tabSessionRegistry.tableRows(for: id).rows.count == Self.rowCount)
        }
    }

    // Holds without waiting: the old 5 s eviction would need a fixed sleep to observe, which the test rules forbid.
    @Test("Losing key status keeps every background table tab's rows")
    func resigningKeyKeepsRows() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let background = addLoadedTableTab(coordinator, tabManager, tableName: "orders")
        let selected = addLoadedTableTab(coordinator, tabManager, tableName: "customers")
        coordinator.handleWindowDidBecomeKey()

        coordinator.handleWindowDidResignKey()

        #expect(coordinator.isKeyWindow == false)
        for id in [background, selected] {
            let current = try tab(id, in: tabManager)
            #expect(coordinator.tabSessionRegistry.tableRows(for: id).rows.count == Self.rowCount)
            #expect(coordinator.canAutoLoadTableTab(current) == false)
        }
    }

    @Test("Rows cannot be edited while a load that replaces them is running")
    func rowsAreReadOnlyWhileReplaced() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addLoadedTableTab(coordinator, tabManager, tableName: "orders")
        tabManager.mutate(tabId: tabId) { $0.tableContext.isEditable = true }
        #expect(coordinator.canEditActiveResult)

        let claim = coordinator.tabExecution.claim(tabId)
        let loading = try tab(tabId, in: tabManager)
        #expect(coordinator.canEditActiveResult == false)
        #expect(coordinator.gridConfiguration(for: loading).isEditable == false)

        let settled = coordinator.tabExecution.settle(claim)
        #expect(settled)
        #expect(coordinator.canEditActiveResult)
    }

    @Test("A tab whose table TablePro changed keeps its rows and reloads when shown")
    func changedTableReloadsOverItsRows() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let background = addLoadedTableTab(coordinator, tabManager, tableName: "orders")
        _ = addLoadedTableTab(coordinator, tabManager, tableName: "customers")

        coordinator.tabSessionRegistry.recordChange(
            TableFreshness.Change(extent: .rows, at: .now),
            for: background
        )

        let current = try tab(background, in: tabManager)
        #expect(coordinator.tabSessionRegistry.tableRows(for: background).rows.count == Self.rowCount)
        #expect(coordinator.canAutoLoadTableTab(current))
    }
}
