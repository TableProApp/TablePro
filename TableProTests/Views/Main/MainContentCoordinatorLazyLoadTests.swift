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
import TableProPluginKit
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
        let tableRows = TableRows.from(queryRows: rows.map { row in row.map(PluginCellValue.fromOptional) }, columns: columns, columnTypes: columnTypes)
        coordinator.setActiveTableRows(tableRows, for: tabId)
    }

    // MARK: - Cheap-content guards (no connection needed)

    @Test("Returns early when no tab is selected")
    func skipsWhenNoSelectedTab() {
        let (coordinator, _) = makeCoordinator()
        coordinator.lazyLoadCurrentTabIfNeeded()
        #expect(coordinator.pendingLoadTrigger == nil)
    }

    @Test("Returns early when selected tab is a query tab (not a table tab)")
    func skipsForQueryTab() {
        let (coordinator, tabManager) = makeCoordinator()
        _ = addQueryTab(to: tabManager)
        coordinator.lazyLoadCurrentTabIfNeeded()
        #expect(coordinator.pendingLoadTrigger == nil)
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
        #expect(coordinator.pendingLoadTrigger == nil)
    }

    @Test("Returns early when tab query is whitespace-only")
    func skipsForEmptyQuery() {
        let (coordinator, tabManager) = makeCoordinator()
        _ = addTableTab(to: tabManager, query: "    ")
        coordinator.lazyLoadCurrentTabIfNeeded()
        #expect(coordinator.pendingLoadTrigger == nil)
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
        #expect(coordinator.pendingLoadTrigger == nil)
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
        #expect(coordinator.pendingLoadTrigger == nil)
    }

    @Test("Returns early when a load Task is already registered for this tab")
    func skipsWhenLoadTaskRegistered() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        let inFlight = Task<Void, Never> { _ = try? await Task.sleep(for: .seconds(60)) }
        defer { inFlight.cancel() }
        coordinator.tableLoadTasks[tabId] = (UUID(), inFlight)

        coordinator.lazyLoadCurrentTabIfNeeded()

        #expect(coordinator.tableLoadTasks.count == 1)
        #expect(coordinator.tableLoadTasks[tabId] != nil)
        #expect(coordinator.pendingLoadTrigger == nil)
    }

    /// The task slot stops answering once the load hands off to an execution: `executeQueryInternal`
    /// supersedes, and `supersedeExecution` nils the slot held by the task it is running inside.
    /// Every later trigger for the same navigation then found an empty slot and started a second
    /// identical query, and the pair collided (#2342). The registry owns the other half.
    @Test("Returns early when the tab already has an execution in flight")
    func skipsWhenTheTabIsAlreadyExecuting() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        let claim = coordinator.tabExecution.claim(tabId)
        let inFlight = Task<Void, Never> { _ = try? await Task.sleep(for: .seconds(60)) }
        defer { inFlight.cancel() }
        coordinator.currentQueryTask = inFlight

        coordinator.lazyLoadCurrentTabIfNeeded()

        #expect(coordinator.tabExecution.isCurrent(claim))
        #expect(coordinator.tableLoadTasks[tabId] == nil)
        #expect(coordinator.pendingLoadTrigger == nil)
    }

    /// Fetch All runs without claiming the tab, so the narrower `isExecuting` would let a second
    /// load through beside it.
    @Test("Returns early when unclaimed work is running on the tab")
    func skipsWhenUnclaimedWorkIsRunning() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        _ = coordinator.tabExecution.beginUnclaimedWork(for: tabId)
        let inFlight = Task<Void, Never> { _ = try? await Task.sleep(for: .seconds(60)) }
        defer { inFlight.cancel() }
        coordinator.currentQueryTask = inFlight

        coordinator.lazyLoadCurrentTabIfNeeded()

        #expect(coordinator.tableLoadTasks[tabId] == nil)
        #expect(coordinator.pendingLoadTrigger == nil)
    }

    // MARK: - Connection guard

    @Test("Sets pendingLoadTrigger when a fresh table tab is not connected")
    func defersWhenDisconnected() {
        let (coordinator, tabManager) = makeCoordinator()
        _ = addTableTab(to: tabManager)
        coordinator.pendingLoadTrigger = nil

        coordinator.lazyLoadCurrentTabIfNeeded()

        #expect(coordinator.pendingLoadTrigger == .userInitiated)
    }

    @Test("Carries the restore trigger into pendingLoadTrigger when disconnected")
    func carriesRestoreTriggerWhenDisconnected() {
        let (coordinator, tabManager) = makeCoordinator()
        _ = addTableTab(to: tabManager)
        coordinator.pendingLoadTrigger = nil

        coordinator.lazyLoadCurrentTabIfNeeded(trigger: .restore)

        #expect(coordinator.pendingLoadTrigger == .restore)
    }

    @Test("A deferred restore tab does not load until its window becomes key")
    func deferredRestoreTabDoesNotLoadEagerly() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        coordinator.deferredRestoreLoadTabId = tabId
        coordinator.pendingLoadTrigger = nil

        coordinator.lazyLoadCurrentTabIfNeeded(trigger: .restore)

        #expect(coordinator.pendingLoadTrigger == nil)
        #expect(coordinator.tableLoadTasks[tabId] == nil)
    }

    @Test("consumeDeferredRestoreLoadIfNeeded is a no-op while the window is not key")
    func consumeDeferredIsNoOpWhenNotKey() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        coordinator.deferredRestoreLoadTabId = tabId
        coordinator.isKeyWindow = false
        coordinator.pendingLoadTrigger = nil

        coordinator.consumeDeferredRestoreLoadIfNeeded()

        #expect(coordinator.deferredRestoreLoadTabId == tabId)
        #expect(coordinator.pendingLoadTrigger == nil)
        #expect(coordinator.tableLoadTasks[tabId] == nil)
    }

    @Test("handleWindowDidBecomeKey consumes a deferred restore load with the restore trigger")
    func windowDidBecomeKeyConsumesDeferredRestoreLoad() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        coordinator.deferredRestoreLoadTabId = tabId
        coordinator.pendingLoadTrigger = nil

        coordinator.handleWindowDidBecomeKey()

        #expect(coordinator.deferredRestoreLoadTabId == nil)
        #expect(coordinator.pendingLoadTrigger == .restore)
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
        #expect(coordinator.pendingLoadTrigger == nil)
    }

    @Test("Clears an abandoned claim when no in-flight task remains")
    func recoversAbandonedExecutingFlag() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("expected tab to exist")
            return
        }
        _ = coordinator.tabExecution.claim(tabId)
        coordinator.currentQueryTask = nil

        coordinator.lazyLoadCurrentTabIfNeeded()

        #expect(coordinator.tabExecution.isExecuting(tabId) == false)
        #expect(coordinator.pendingLoadTrigger == .userInitiated)
    }

    // MARK: - loadEpoch bump triggers reload after eviction

    /// `.task(id:)` keys on the tab's own `loadEpoch`, so that is the one the eviction path has to
    /// move. This used to assert on a copy held by the session that nothing reads, which would
    /// have stayed green with the reload broken.
    @Test("Evicting a background tab bumps the tab's loadEpoch so .task(id:) re-fires")
    func evictionBumpsLoadEpoch() {
        let (coordinator, tabManager) = makeCoordinator()
        let background = addTableTab(to: tabManager, tableName: "orders")
        seedRows(coordinator, for: background, rowCount: 7)
        let foreground = addTableTab(to: tabManager, tableName: "customers")
        tabManager.selectedTabId = foreground
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == background }) else {
            Issue.record("expected tab to exist")
            return
        }
        tabManager.tabs[idx].execution.lastExecutedAt = Date()
        let initialEpoch = tabManager.tabs[idx].loadEpoch
        #expect(coordinator.tabSessionRegistry.tableRows(for: background).rows.count == 7)

        coordinator.evictInactiveRowData()

        guard let evictedTab = tabManager.tabs.first(where: { $0.id == background }) else {
            Issue.record("expected tab to exist")
            return
        }
        #expect(evictedTab.loadEpoch != initialEpoch)
        #expect(coordinator.tabSessionRegistry.isEvicted(background) == true)
        #expect(coordinator.tabSessionRegistry.isEvicted(foreground) == false)
    }

    /// A claim with no task behind it is healed on the next lazy load. That heal never lowered the
    /// window's stored busy flag, so the titlebar kept reporting a query that had no task and no way
    /// to finish, and only Stop could clear it (#2342). The window's state is derived now, so the
    /// heal is the whole fix.
    @Test("Healing an abandoned claim leaves the window reporting idle")
    func abandonedClaimLeavesTheWindowIdle() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        let claim = coordinator.tabExecution.claim(tabId)
        #expect(coordinator.currentQueryTask == nil)
        #expect(coordinator.tabExecution.isAnyExecuting)

        coordinator.lazyLoadCurrentTabIfNeeded()

        #expect(coordinator.tabExecution.isCurrent(claim) == false)
        #expect(coordinator.tabExecution.isAnyExecuting == false)
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
        let executingBefore = coordinator.tabExecution.isExecuting(tabId)
        let executedAtBefore = tabManager.tabs[idx].execution.lastExecutedAt
        let toolbarBefore = coordinator.tabExecution.isAnyExecuting

        coordinator.handleWindowDidBecomeKey()

        let executingAfter = coordinator.tabExecution.isExecuting(tabId)
        let executedAtAfter = tabManager.tabs[idx].execution.lastExecutedAt
        let toolbarAfter = coordinator.tabExecution.isAnyExecuting

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
