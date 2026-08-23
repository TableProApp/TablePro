//
//  EvictionTests.swift
//  TableProTests
//
//  Tests for cross-window tab eviction
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Cross-Window Tab Eviction")
@MainActor
struct EvictionTests {
    private func makeCoordinator() -> (MainContentCoordinator, QueryTabManager) {
        let tabManager = QueryTabManager()
        let changeManager = DataChangeManager()
        let toolbarState = ConnectionToolbarState()
        let connection = TestFixtures.makeConnection()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: changeManager,
            toolbarState: toolbarState
        )
        return (coordinator, tabManager)
    }

    private func addLoadedTab(
        to coordinator: MainContentCoordinator,
        tabManager: QueryTabManager,
        tableName: String = "users"
    ) throws {
        try tabManager.addTableTab(tableName: tableName)
        guard let index = tabManager.selectedTabIndex else { return }
        let rows = TestFixtures.makeRows(count: 10)
        let tabId = tabManager.tabs[index].id
        let columns = ["id", "name", "email"]
        let columnTypes: [ColumnType] = Array(repeating: .text(rawType: nil), count: columns.count)
        let tableRows = TableRows.from(queryRows: rows.map { row in row.map(PluginCellValue.fromOptional) }, columns: columns, columnTypes: columnTypes)
        coordinator.setActiveTableRows(tableRows, for: tabId)
        let resultSet = ResultSet(label: tableName, tableRows: tableRows)
        tabManager.mutate(at: index) { tab in
            tab.display.resultSets = [resultSet]
            tab.display.activeResultSetId = resultSet.id
            tab.execution.lastExecutedAt = Date()
        }
    }

    @Test("evictInactiveRowData evicts background tabs without pending changes")
    func evictsLoadedTabs() throws {
        let (coordinator, tabManager) = makeCoordinator()
        try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "users")
        let backgroundTabId = tabManager.tabs[0].id
        let backgroundResult = try #require(tabManager.tabs[0].display.activeResultSet)
        try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "orders")

        #expect(coordinator.tabSessionRegistry.tableRows(for: backgroundTabId).rows.count == 10)
        #expect(backgroundResult.tableRows.rows.count == 10)
        #expect(coordinator.tabSessionRegistry.isEvicted(backgroundTabId) == false)

        coordinator.evictInactiveRowData()

        #expect(coordinator.tabSessionRegistry.isEvicted(backgroundTabId) == true)
        #expect(coordinator.tabSessionRegistry.tableRows(for: backgroundTabId).rows.isEmpty)
        #expect(coordinator.tabSessionRegistry.tableRows(for: backgroundTabId).index(of: .existing(0)) == nil)
        #expect(backgroundResult.tableRows.rows.isEmpty)
        #expect(backgroundResult.tableRows.index(of: .existing(0)) == nil)
    }

    @Test("eviction helper never evicts the selected tab")
    func preservesSelectedTab() throws {
        let (coordinator, tabManager) = makeCoordinator()
        try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "users")
        let selectedTabId = try #require(tabManager.selectedTabId)
        let selectedResult = try #require(tabManager.selectedTab?.display.activeResultSet)
        let loadEpoch = try #require(tabManager.selectedTab?.loadEpoch)

        let didEvict = coordinator.evictReloadableTableRows(for: selectedTabId)

        #expect(didEvict == false)
        #expect(coordinator.tabSessionRegistry.isEvicted(selectedTabId) == false)
        #expect(coordinator.tabSessionRegistry.tableRows(for: selectedTabId).rows.count == 10)
        #expect(selectedResult.tableRows.rows.count == 10)
        #expect(tabManager.selectedTab?.loadEpoch == loadEpoch)
    }

    @Test("evictInactiveRowData skips tabs with pending changes")
    func skipsTabsWithPendingChanges() throws {
        let (coordinator, tabManager) = makeCoordinator()
        try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "users")

        tabManager.tabs[0].pendingChanges.deletedRowIndices = [0]
        let loadEpoch = tabManager.tabs[0].loadEpoch
        try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "orders")

        coordinator.evictInactiveRowData()

        let tabId = tabManager.tabs[0].id
        #expect(coordinator.tabSessionRegistry.isEvicted(tabId) == false)
        #expect(coordinator.tabSessionRegistry.tableRows(for: tabId).rows.count == 10)
        #expect(tabManager.tabs[0].loadEpoch == loadEpoch)
    }

    @Test("evictInactiveRowData skips tabs with pinned results")
    func preservesPinnedResults() throws {
        let (coordinator, tabManager) = makeCoordinator()
        try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "users")
        let backgroundTabId = tabManager.tabs[0].id
        let pinnedResult = try #require(tabManager.tabs[0].display.activeResultSet)
        pinnedResult.isPinned = true
        let loadEpoch = tabManager.tabs[0].loadEpoch
        try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "orders")

        coordinator.evictInactiveRowData()

        #expect(coordinator.tabSessionRegistry.isEvicted(backgroundTabId) == false)
        #expect(coordinator.tabSessionRegistry.tableRows(for: backgroundTabId).rows.count == 10)
        #expect(pinnedResult.tableRows.rows.count == 10)
        #expect(pinnedResult.tableRows.index(of: .existing(0)) == 0)
        #expect(tabManager.tabs[0].loadEpoch == loadEpoch)
    }

    @Test("evictInactiveRowData skips table tabs that cannot auto-reload")
    func skipsNonReloadableTableTabs() throws {
        let (coordinator, tabManager) = makeCoordinator()
        try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "users")
        let backgroundTabId = tabManager.tabs[0].id
        tabManager.tabs[0].execution.errorMessage = "connection lost"
        let loadEpoch = tabManager.tabs[0].loadEpoch
        try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "orders")

        coordinator.evictInactiveRowData()

        #expect(coordinator.tabSessionRegistry.isEvicted(backgroundTabId) == false)
        #expect(coordinator.tabSessionRegistry.tableRows(for: backgroundTabId).rows.count == 10)
        #expect(tabManager.tabs[0].loadEpoch == loadEpoch)
    }

    @Test("evictInactiveRowData skips an executing table tab")
    func skipsExecutingTableTab() throws {
        let (coordinator, tabManager) = makeCoordinator()
        try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "users")
        let backgroundTabId = tabManager.tabs[0].id
        let loadEpoch = tabManager.tabs[0].loadEpoch
        let claim = coordinator.tabExecution.claim(backgroundTabId)
        defer { _ = coordinator.tabExecution.settle(claim) }
        try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "orders")

        coordinator.evictInactiveRowData()

        #expect(coordinator.tabSessionRegistry.isEvicted(backgroundTabId) == false)
        #expect(coordinator.tabSessionRegistry.tableRows(for: backgroundTabId).rows.count == 10)
        #expect(tabManager.tabs[0].loadEpoch == loadEpoch)
    }

    @Test("evictInactiveRowData skips a table tab with an active load")
    func skipsTableTabWithActiveLoad() throws {
        let (coordinator, tabManager) = makeCoordinator()
        try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "users")
        let backgroundTabId = tabManager.tabs[0].id
        let loadEpoch = tabManager.tabs[0].loadEpoch
        let inFlight = Task<Void, Never> { _ = try? await Task.sleep(for: .seconds(60)) }
        coordinator.tableLoadTasks[backgroundTabId] = (UUID(), inFlight)
        defer {
            inFlight.cancel()
            coordinator.tableLoadTasks[backgroundTabId] = nil
        }
        try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "orders")

        coordinator.evictInactiveRowData()

        #expect(coordinator.tabSessionRegistry.isEvicted(backgroundTabId) == false)
        #expect(coordinator.tabSessionRegistry.tableRows(for: backgroundTabId).rows.count == 10)
        #expect(tabManager.tabs[0].loadEpoch == loadEpoch)
    }

    @Test("evictInactiveRowData skips tables loading rows", arguments: [false, true])
    func skipsTableTabLoadingRows(isLoadingMore: Bool) throws {
        let (coordinator, tabManager) = makeCoordinator()
        try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "users")
        let backgroundTabId = tabManager.tabs[0].id
        let loadEpoch = tabManager.tabs[0].loadEpoch
        tabManager.mutate(at: 0) { tab in
            if isLoadingMore {
                tab.pagination.isLoadingMore = true
            } else {
                tab.pagination.isLoading = true
            }
        }
        try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "orders")

        coordinator.evictInactiveRowData()

        #expect(coordinator.tabSessionRegistry.isEvicted(backgroundTabId) == false)
        #expect(coordinator.tabSessionRegistry.tableRows(for: backgroundTabId).rows.count == 10)
        #expect(tabManager.tabs[0].loadEpoch == loadEpoch)
    }

    @Test("evictInactiveRowData does not evict query results")
    func preservesQueryResults() throws {
        let (coordinator, tabManager) = makeCoordinator()
        tabManager.addTab(initialQuery: "SELECT 1")
        let queryIndex = try #require(tabManager.selectedTabIndex)
        let queryTabId = tabManager.tabs[queryIndex].id
        let queryRows = TableRows.from(
            queryRows: [[.text("1")]],
            columns: ["value"],
            columnTypes: [.integer(rawType: nil)]
        )
        coordinator.setActiveTableRows(queryRows, for: queryTabId)
        let queryResult = ResultSet(label: "SELECT 1", tableRows: queryRows)
        tabManager.mutate(at: queryIndex) { tab in
            tab.display.resultSets = [queryResult]
            tab.display.activeResultSetId = queryResult.id
            tab.execution.lastExecutedAt = Date()
        }
        let loadEpoch = tabManager.tabs[queryIndex].loadEpoch
        try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "orders")

        coordinator.evictInactiveRowData()

        #expect(coordinator.tabSessionRegistry.isEvicted(queryTabId) == false)
        #expect(coordinator.tabSessionRegistry.tableRows(for: queryTabId).rows.count == 1)
        #expect(queryResult.tableRows.rows.count == 1)
        #expect(tabManager.tabs[queryIndex].loadEpoch == loadEpoch)
    }

    @Test("evictInactiveRowData preserves column metadata after eviction")
    func preservesMetadataAfterEviction() throws {
        let (coordinator, tabManager) = makeCoordinator()
        try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "users")
        let backgroundTabId = tabManager.tabs[0].id
        try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "orders")

        coordinator.evictInactiveRowData()

        let rows = coordinator.tabSessionRegistry.tableRows(for: backgroundTabId)
        #expect(rows.columns == ["id", "name", "email"])
        #expect(coordinator.tabSessionRegistry.isEvicted(backgroundTabId) == true)
    }

    @Test("evictInactiveRowData with no tabs is no-op")
    func noTabsIsNoOp() {
        let (coordinator, _) = makeCoordinator()
        coordinator.evictInactiveRowData()
    }

    @Test("eviction skips a table tab whose query is blank")
    func skipsTableTabWithBlankQuery() throws {
        let (coordinator, tabManager) = makeCoordinator()
        try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "users")
        let backgroundTabId = tabManager.tabs[0].id
        tabManager.mutate(at: 0) { $0.content.query = "   \n\t " }
        try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "orders")

        coordinator.evictInactiveRowData()

        #expect(coordinator.tabSessionRegistry.isEvicted(backgroundTabId) == false)
        #expect(coordinator.tabSessionRegistry.tableRows(for: backgroundTabId).rows.count == 10)
    }

    @Test("eviction skips a table tab running work that took no execution claim")
    func skipsTableTabWithUnclaimedWork() throws {
        let (coordinator, tabManager) = makeCoordinator()
        try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "users")
        let backgroundTabId = tabManager.tabs[0].id
        let token = coordinator.tabExecution.beginUnclaimedWork(for: backgroundTabId)
        defer { coordinator.tabExecution.endUnclaimedWork(token, for: backgroundTabId) }
        try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "orders")

        coordinator.evictInactiveRowData()

        #expect(coordinator.tabSessionRegistry.isEvicted(backgroundTabId) == false)
        #expect(coordinator.tabSessionRegistry.tableRows(for: backgroundTabId).rows.count == 10)
    }

    @Test("metadata landing after eviction does not resurrect an empty tab")
    func lateMetadataKeepsTabEvicted() throws {
        let (coordinator, tabManager) = makeCoordinator()
        try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "users")
        let backgroundTabId = tabManager.tabs[0].id
        try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "orders")

        coordinator.evictInactiveRowData()
        #expect(coordinator.tabSessionRegistry.isEvicted(backgroundTabId) == true)

        coordinator.mutateActiveTableRows(for: backgroundTabId) { rows in
            rows.columnEnumValues["status"] = ["active", "archived"]
            return .columnsReplaced
        }

        #expect(coordinator.tabSessionRegistry.isEvicted(backgroundTabId) == true)
        #expect(coordinator.tabSessionRegistry.tableRows(for: backgroundTabId).rows.isEmpty)
    }

    @Test("rows arriving after eviction clear the evicted flag")
    func reloadedRowsClearTheEvictedFlag() throws {
        let (coordinator, tabManager) = makeCoordinator()
        try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "users")
        let backgroundTabId = tabManager.tabs[0].id
        try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "orders")

        coordinator.evictInactiveRowData()
        let reloaded = TableRows.from(
            queryRows: [[.text("1")]],
            columns: ["id"],
            columnTypes: [.integer(rawType: nil)]
        )
        coordinator.setActiveTableRows(reloaded, for: backgroundTabId)

        #expect(coordinator.tabSessionRegistry.isEvicted(backgroundTabId) == false)
        #expect(coordinator.tabSessionRegistry.tableRows(for: backgroundTabId).rows.count == 1)
    }

    @Test("evictInactiveTabs keeps the newest tabs within the memory budget")
    func budgetKeepsNewestTabs() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let budget = MemoryPressureAdvisor.budgetForInactiveTabs()
        let total = budget + 3
        var executedAt: [UUID: Date] = [:]
        for index in 0..<total {
            try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "table_\(index)")
            let tabIndex = try #require(tabManager.selectedTabIndex)
            let stamp = Date(timeIntervalSince1970: TimeInterval(1_000 + index))
            tabManager.mutate(at: tabIndex) { $0.execution.lastExecutedAt = stamp }
            executedAt[tabManager.tabs[tabIndex].id] = stamp
        }
        let selectedId = try #require(tabManager.selectedTabId)

        coordinator.evictInactiveTabs(excluding: [selectedId])

        let evictable = tabManager.tabs
            .filter { $0.id != selectedId }
            .sorted { executedAt[$0.id] ?? .distantPast < executedAt[$1.id] ?? .distantPast }
        let expectedEvicted = evictable.count - budget
        #expect(expectedEvicted > 0)
        for (position, tab) in evictable.enumerated() {
            #expect(coordinator.tabSessionRegistry.isEvicted(tab.id) == (position < expectedEvicted))
        }
        #expect(coordinator.tabSessionRegistry.isEvicted(selectedId) == false)
    }

    @Test("evictInactiveTabs never evicts a tab it was told is active")
    func budgetSkipsActiveTabs() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let budget = MemoryPressureAdvisor.budgetForInactiveTabs()
        for index in 0..<(budget + 3) {
            try addLoadedTab(to: coordinator, tabManager: tabManager, tableName: "table_\(index)")
            let tabIndex = try #require(tabManager.selectedTabIndex)
            tabManager.mutate(at: tabIndex) {
                $0.execution.lastExecutedAt = Date(timeIntervalSince1970: TimeInterval(1_000 + index))
            }
        }
        let selectedId = try #require(tabManager.selectedTabId)
        let oldestId = tabManager.tabs[0].id

        coordinator.evictInactiveTabs(excluding: [selectedId, oldestId])

        #expect(coordinator.tabSessionRegistry.isEvicted(oldestId) == false)
        #expect(coordinator.tabSessionRegistry.tableRows(for: oldestId).rows.count == 10)
    }
}
