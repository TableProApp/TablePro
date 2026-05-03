//
//  MainContentCoordinatorLazyLoadTests.swift
//  TableProTests
//
//  Tests for lazyLoadCurrentTabIfNeeded — the Apple-pattern visibility-scoped
//  lazy-load entry point invoked by MainEditorContentView's `.task(id:)`
//  modifier. Replaces the old in-line lazy-load block in handleWindowDidBecomeKey
//  and handleTabChange.
//

import Foundation
import Testing

@testable import TablePro

@Suite("MainContentCoordinator lazyLoadCurrentTabIfNeeded")
@MainActor
struct MainContentCoordinatorLazyLoadTests {
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

    private func addTableTab(
        to tabManager: QueryTabManager,
        tableName: String = "users",
        query: String = "SELECT * FROM users"
    ) -> UUID {
        var tab = QueryTab(
            title: tableName,
            query: query,
            tabType: .table,
            tableName: tableName
        )
        tab.tableContext.isEditable = true
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        return tab.id
    }

    private func addQueryTab(
        to tabManager: QueryTabManager,
        title: String = "Query 1",
        query: String = "SELECT 1"
    ) -> UUID {
        let tab = QueryTab(title: title, query: query, tabType: .query)
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        return tab.id
    }

    private func seedRows(
        _ coordinator: MainContentCoordinator,
        for tabId: UUID,
        columns: [String] = ["id", "name"],
        rowCount: Int = 3
    ) {
        let rows = (0..<rowCount).map { i in columns.map { "\($0)_\(i)" as String? } }
        let columnTypes: [ColumnType] = Array(repeating: .text(rawType: nil), count: columns.count)
        let tableRows = TableRows.from(queryRows: rows, columns: columns, columnTypes: columnTypes)
        coordinator.setActiveTableRows(tableRows, for: tabId)
    }

    // MARK: - Cheap-content guards (no connection needed)

    @Test("Returns early when no tab is selected")
    func skipsWhenNoSelectedTab() {
        let (coordinator, _) = makeCoordinator()
        coordinator.lazyLoadCurrentTabIfNeeded()
        #expect(coordinator.needsLazyLoad == false)
    }

    @Test("Returns early when selected tab is a query tab (not a table tab)")
    func skipsForQueryTab() {
        let (coordinator, tabManager) = makeCoordinator()
        _ = addQueryTab(to: tabManager)
        coordinator.lazyLoadCurrentTabIfNeeded()
        #expect(coordinator.needsLazyLoad == false)
    }

    @Test("Returns early when tab has an error message")
    func skipsWhenTabHasError() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("expected tab to exist")
            return
        }
        tabManager.tabs[idx].execution.errorMessage = "boom"
        coordinator.lazyLoadCurrentTabIfNeeded()
        #expect(coordinator.needsLazyLoad == false)
    }

    @Test("Returns early when tab query is whitespace-only")
    func skipsForEmptyQuery() {
        let (coordinator, tabManager) = makeCoordinator()
        _ = addTableTab(to: tabManager, query: "    ")
        coordinator.lazyLoadCurrentTabIfNeeded()
        #expect(coordinator.needsLazyLoad == false)
    }

    @Test("Returns early when tab has fresh row data already loaded")
    func skipsWhenFreshRowsPresent() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        seedRows(coordinator, for: tabId, rowCount: 5)
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("expected tab to exist")
            return
        }
        tabManager.tabs[idx].execution.lastExecutedAt = Date()

        coordinator.lazyLoadCurrentTabIfNeeded()
        #expect(coordinator.needsLazyLoad == false)
        #expect(coordinator.tabSessionRegistry.tableRows(for: tabId).rows.count == 5)
    }

    @Test("Returns early when tab has pending edits in the change manager")
    func skipsWhenPendingChangesPresent() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        seedRows(coordinator, for: tabId, rowCount: 1)
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("expected tab to exist")
            return
        }
        tabManager.tabs[idx].pendingChanges.deletedRowIndices = [0]

        coordinator.lazyLoadCurrentTabIfNeeded()
        #expect(coordinator.needsLazyLoad == false)
    }

    @Test("Returns early when tab is already executing")
    func skipsWhenAlreadyExecuting() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("expected tab to exist")
            return
        }
        tabManager.tabs[idx].execution.isExecuting = true

        coordinator.lazyLoadCurrentTabIfNeeded()
        #expect(coordinator.needsLazyLoad == false)
    }

    // MARK: - Connection guard

    @Test("Sets needsLazyLoad when a fresh table tab is not connected")
    func defersWhenDisconnected() {
        let (coordinator, tabManager) = makeCoordinator()
        _ = addTableTab(to: tabManager)
        coordinator.needsLazyLoad = false

        coordinator.lazyLoadCurrentTabIfNeeded()

        #expect(coordinator.needsLazyLoad == true)
    }

    // MARK: - Idempotency

    @Test("Idempotent: repeated calls with the same loaded state are no-ops")
    func idempotentWhenAlreadyLoaded() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        seedRows(coordinator, for: tabId, rowCount: 4)
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("expected tab to exist")
            return
        }
        tabManager.tabs[idx].execution.lastExecutedAt = Date()

        for _ in 0..<5 {
            coordinator.lazyLoadCurrentTabIfNeeded()
        }
        #expect(coordinator.tabSessionRegistry.tableRows(for: tabId).rows.count == 4)
        #expect(coordinator.needsLazyLoad == false)
    }

    // MARK: - loadEpoch bump triggers reload after eviction

    @Test("Eviction bumps the tab's loadEpoch so .task(id:) re-fires")
    func evictionBumpsLoadEpoch() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager, tableName: "orders")
        seedRows(coordinator, for: tabId, rowCount: 7)
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("expected tab to exist")
            return
        }
        tabManager.tabs[idx].execution.lastExecutedAt = Date()
        #expect(coordinator.tabSessionRegistry.tableRows(for: tabId).rows.count == 7)

        guard let session = coordinator.tabSessionRegistry.session(for: tabId) else {
            Issue.record("expected session to exist after seedRows")
            return
        }
        let initialEpoch = session.loadEpoch

        coordinator.tabSessionRegistry.evict(for: tabId)

        #expect(session.loadEpoch != initialEpoch)
        #expect(coordinator.tabSessionRegistry.isEvicted(tabId) == true)
    }

    // MARK: - Regression: handleWindowDidBecomeKey does NOT trigger query work

    @Test("handleWindowDidBecomeKey does not change tab execution state")
    func windowDidBecomeKeyDoesNotRunQuery() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("expected tab to exist")
            return
        }
        let executingBefore = tabManager.tabs[idx].execution.isExecuting
        let executedAtBefore = tabManager.tabs[idx].execution.lastExecutedAt
        let toolbarBefore = coordinator.toolbarState.isExecuting

        coordinator.handleWindowDidBecomeKey()

        let executingAfter = tabManager.tabs[idx].execution.isExecuting
        let executedAtAfter = tabManager.tabs[idx].execution.lastExecutedAt
        let toolbarAfter = coordinator.toolbarState.isExecuting

        #expect(executingAfter == executingBefore)
        #expect(executedAtAfter == executedAtBefore)
        #expect(toolbarAfter == toolbarBefore)
        #expect(coordinator.isKeyWindow == true)
    }

    @Test("handleWindowDidBecomeKey cancels a pending eviction task")
    func windowDidBecomeKeyCancelsEviction() {
        let (coordinator, _) = makeCoordinator()
        coordinator.handleWindowDidResignKey()
        #expect(coordinator.evictionTask != nil)

        coordinator.handleWindowDidBecomeKey()
        #expect(coordinator.evictionTask == nil)
        #expect(coordinator.isKeyWindow == true)
    }
}
