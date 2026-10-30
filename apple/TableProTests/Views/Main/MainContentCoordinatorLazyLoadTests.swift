//
//  MainContentCoordinatorLazyLoadTests.swift
//  TableProTests
//
//  Tests for lazyLoadCurrentTabIfNeeded — the Apple-pattern visibility-scoped
//  lazy-load entry point invoked by MainEditorContentView's `.task(id:)`
//  modifier. Replaces the old in-line lazy-load block in handleWindowDidBecomeKey
//  and handleTabChange.
//

import AppKit
import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct MainContentCoordinatorLazyLoadTests {
    private let fixtures = CoordinatorFixtures()

    private func makeCoordinator() -> (MainContentCoordinator, QueryTabManager) {
        let fixture = fixtures.make()
        let tabManager = fixture.tabManager
        let coordinator = fixture.coordinator
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
        #expect(coordinator.parkedTableLoad == nil)
    }

    @Test("Returns early when selected tab is a query tab (not a table tab)")
    func skipsForQueryTab() {
        let (coordinator, tabManager) = makeCoordinator()
        _ = addQueryTab(to: tabManager)
        coordinator.lazyLoadCurrentTabIfNeeded()
        #expect(coordinator.parkedTableLoad == nil)
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
        #expect(coordinator.parkedTableLoad == nil)
    }

    @Test("Returns early when tab query is whitespace-only")
    func skipsForEmptyQuery() {
        let (coordinator, tabManager) = makeCoordinator()
        _ = addTableTab(to: tabManager, query: "    ")
        coordinator.lazyLoadCurrentTabIfNeeded()
        #expect(coordinator.parkedTableLoad == nil)
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
        #expect(coordinator.parkedTableLoad == nil)
        #expect(coordinator.tabSessionRegistry.tableRows(for: tabId).rows.count == 5)
    }

    @Test("A tab whose table changed after its rows were fetched asks to load again")
    func loadsAStaleTabWithRows() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        seedRows(coordinator, for: tabId, rowCount: 5)
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("expected tab to exist")
            return
        }
        tabManager.tabs[idx].execution.lastExecutedAt = Date()
        coordinator.tabSessionRegistry.recordChange(TableFreshness.Change(extent: .rows, at: .now), for: tabId)

        coordinator.lazyLoadCurrentTabIfNeeded()

        #expect(coordinator.parkedTableLoad?.trigger == .userInitiated)
        #expect(coordinator.tabSessionRegistry.tableRows(for: tabId).rows.count == 5)
    }

    @Test("A stale tab holding edits is not reloaded behind the user")
    func skipsAStaleTabWithPendingEdits() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        seedRows(coordinator, for: tabId, rowCount: 1)
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("expected tab to exist")
            return
        }
        tabManager.tabs[idx].execution.lastExecutedAt = Date()
        tabManager.tabs[idx].pendingChanges.deletedRowIDs = [.existing(0)]
        coordinator.tabSessionRegistry.recordChange(TableFreshness.Change(extent: .rows, at: .now), for: tabId)

        coordinator.lazyLoadCurrentTabIfNeeded()

        #expect(coordinator.parkedTableLoad == nil)
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
        tabManager.tabs[idx].pendingChanges.deletedRowIDs = [.existing(0)]

        coordinator.lazyLoadCurrentTabIfNeeded()
        #expect(coordinator.parkedTableLoad == nil)
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
        #expect(coordinator.parkedTableLoad == nil)
    }

    /// The task slot stops answering once the load hands off to an execution: `executeQueryInternal`
    /// supersedes, and `supersedeExecution` clears the slot held by the task it is running inside.
    /// Every later trigger for the same navigation then found an empty slot and started a second
    /// identical query, and the pair collided (#2342). The registry owns the other half.
    @Test("Returns early when the tab already has an execution in flight")
    func skipsWhenTheTabIsAlreadyExecuting() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        let claim = coordinator.tabExecution.claim(tabId)
        let inFlight = Task<Void, Never> { _ = try? await Task.sleep(for: .seconds(60)) }
        defer { inFlight.cancel() }
        coordinator.installQueryTask(inFlight, owner: .claim(claim), lease: DriverLeaseOwner())

        coordinator.lazyLoadCurrentTabIfNeeded()

        #expect(coordinator.tabExecution.isCurrent(claim))
        #expect(coordinator.tableLoadTasks[tabId] == nil)
        #expect(coordinator.parkedTableLoad == nil)
    }

    /// Fetch All runs without claiming the tab, so the narrower `isExecuting` would let a second
    /// load through beside it.
    @Test("Returns early when unclaimed work is running on the tab")
    func skipsWhenUnclaimedWorkIsRunning() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        let token = coordinator.tabExecution.beginUnclaimedWork(for: tabId)
        let inFlight = Task<Void, Never> { _ = try? await Task.sleep(for: .seconds(60)) }
        defer { inFlight.cancel() }
        coordinator.installQueryTask(
            inFlight, owner: .unclaimedWork(tabId: tabId, token: token), lease: DriverLeaseOwner()
        )

        coordinator.lazyLoadCurrentTabIfNeeded()

        #expect(coordinator.tableLoadTasks[tabId] == nil)
        #expect(coordinator.parkedTableLoad == nil)
    }

    // MARK: - Connection guard

    @Test("Parks the load with its tab when a fresh table tab is not connected")
    func defersWhenDisconnected() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        coordinator.parkedTableLoad = nil

        coordinator.lazyLoadCurrentTabIfNeeded()

        #expect(coordinator.parkedTableLoad == ParkedTableLoad(tabId: tabId, trigger: .userInitiated))
    }

    @Test("Parks the restore trigger with its tab when disconnected")
    func carriesRestoreTriggerWhenDisconnected() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        coordinator.parkedTableLoad = nil

        coordinator.lazyLoadCurrentTabIfNeeded(trigger: .restore)

        #expect(coordinator.parkedTableLoad == ParkedTableLoad(tabId: tabId, trigger: .restore))
    }

    @Test("A deferred restore tab does not load until its window becomes key")
    func deferredRestoreTabDoesNotLoadEagerly() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        coordinator.deferredRestoreLoadTabId = tabId
        coordinator.parkedTableLoad = nil

        coordinator.lazyLoadCurrentTabIfNeeded(trigger: .restore)

        #expect(coordinator.parkedTableLoad == nil)
        #expect(coordinator.tableLoadTasks[tabId] == nil)
    }

    @Test("consumeDeferredRestoreLoadIfNeeded is a no-op while the window is not key")
    func consumeDeferredIsNoOpWhenNotKey() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        coordinator.deferredRestoreLoadTabId = tabId
        coordinator.isKeyWindow = false
        coordinator.parkedTableLoad = nil

        coordinator.consumeDeferredRestoreLoadIfNeeded()

        #expect(coordinator.deferredRestoreLoadTabId == tabId)
        #expect(coordinator.parkedTableLoad == nil)
        #expect(coordinator.tableLoadTasks[tabId] == nil)
    }

    @Test("handleWindowDidBecomeKey consumes a deferred restore load with the restore trigger")
    func windowDidBecomeKeyConsumesDeferredRestoreLoad() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        coordinator.deferredRestoreLoadTabId = tabId
        coordinator.parkedTableLoad = nil

        coordinator.handleWindowDidBecomeKey()

        #expect(coordinator.deferredRestoreLoadTabId == nil)
        #expect(coordinator.parkedTableLoad?.trigger == .restore)
    }

    /// A link or an agent can select another tab before the restored window comes forward. The
    /// deferral used to outlive that, and refused every later load of the deferred tab, including
    /// a table opened into it from the sidebar.
    @Test("Becoming key ends a deferral even when another tab is selected")
    func becomingKeyEndsADeferralForAnUnselectedTab() {
        let (coordinator, tabManager) = makeCoordinator()
        let deferredId = addTableTab(to: tabManager)
        _ = addTableTab(to: tabManager, tableName: "orders", query: "SELECT * FROM orders")
        coordinator.deferredRestoreLoadTabId = deferredId

        coordinator.handleWindowDidBecomeKey()
        #expect(coordinator.deferredRestoreLoadTabId == nil)

        tabManager.selectedTabId = deferredId
        coordinator.parkedTableLoad = nil
        coordinator.lazyLoadCurrentTabIfNeeded()

        #expect(coordinator.parkedTableLoad?.trigger == .userInitiated)
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
        #expect(coordinator.parkedTableLoad == nil)
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
        #expect(coordinator.queryTasks.hasTask(for: tabId) == false)

        coordinator.lazyLoadCurrentTabIfNeeded()

        #expect(coordinator.tabExecution.isExecuting(tabId) == false)
        #expect(coordinator.parkedTableLoad?.trigger == .userInitiated)
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
        #expect(coordinator.queryTasks.hasTask(for: tabId) == false)
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

    @Test("Resigning and regaining key status runs no query")
    func keyRoundTripRunsNothing() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        seedRows(coordinator, for: tabId)
        tabManager.mutate(tabId: tabId) { $0.execution.lastExecutedAt = Date() }

        coordinator.handleWindowDidResignKey()
        #expect(coordinator.isKeyWindow == false)
        coordinator.handleWindowDidBecomeKey()

        #expect(coordinator.isKeyWindow == true)
        #expect(coordinator.tabExecution.isAnyExecuting == false)
        #expect(coordinator.tableLoadTasks[tabId] == nil)
        #expect(coordinator.tabSessionRegistry.tableRows(for: tabId).rows.count == 3)
    }

    // MARK: - Loading once the connection comes back

    /// The parked load used to be one window-wide trigger, consumed against whatever tab was
    /// selected, and a query tab took it as a Run.
    @Test("A connection coming back never runs the selected query tab's statement")
    func reconnectNeverRunsAQueryTab() {
        let (coordinator, tabManager) = makeCoordinator()
        let tableTab = addTableTab(to: tabManager)
        coordinator.parkedTableLoad = ParkedTableLoad(tabId: tableTab, trigger: .userInitiated)
        let queryTab = addQueryTab(to: tabManager, query: "DELETE FROM orders WHERE id = 7")

        coordinator.loadSelectedTableTabAfterConnect()

        #expect(coordinator.parkedTableLoad == nil)
        #expect(coordinator.tabExecution.isBusy(queryTab) == false)
        #expect(coordinator.queryTasks.hasTask(for: queryTab) == false)
    }

    @Test("A parked trigger goes only to the tab that parked it")
    func parkedTriggerStaysWithItsTab() {
        let (coordinator, tabManager) = makeCoordinator()
        let restored = addTableTab(to: tabManager)
        coordinator.parkedTableLoad = ParkedTableLoad(tabId: restored, trigger: .restore)

        coordinator.loadSelectedTableTabAfterConnect()
        #expect(coordinator.parkedTableLoad == ParkedTableLoad(tabId: restored, trigger: .restore))

        let other = addTableTab(to: tabManager, tableName: "orders", query: "SELECT * FROM orders")
        coordinator.loadSelectedTableTabAfterConnect()
        #expect(coordinator.parkedTableLoad == ParkedTableLoad(tabId: other, trigger: .userInitiated))
    }

    // MARK: - A changed table under an open cell

    @Test("A tab whose table changed waits for an open cell to close before it reloads")
    func changedTableWaitsForAnOpenCell() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        seedRows(coordinator, for: tabId)
        tabManager.mutate(tabId: tabId) { $0.execution.lastExecutedAt = Date() }
        coordinator.tabSessionRegistry.recordChange(TableFreshness.Change(extent: .rows, at: .now), for: tabId)
        let editor = EditingGridView()
        coordinator.gridModel(forTab: tabId).attach(editor)
        let tab = try #require(tabManager.selectedTab)

        editor.isEditing = true
        #expect(coordinator.canAutoLoadTableTab(tab) == false)

        editor.isEditing = false
        #expect(coordinator.canAutoLoadTableTab(tab))
    }
}

@MainActor
private final class EditingGridView: DataGridMountedView {
    var isEditing = false

    func apply(_ change: DataGridChange) {}
    func selectionDidChange() {}
    func configurationDidChange() {}
    func reveal(row: Int, displayColumn: Int?) {}
    func revealColumn(_ displayColumn: Int) {}
    func sortDidChange() {}
    func summaryRulesDidChange() {}
    func viewportSample() -> (row: Int, offset: CGFloat)? { nil }
    func beginEditing(row: Int, displayColumn: Int) -> Bool { false }
    func commitEditing() -> Bool { true }
    func discardEditing() {}
    func focus() -> Bool { false }
    func anchor(forColumn displayColumn: Int) -> (view: NSView, rect: NSRect)? { nil }
}
