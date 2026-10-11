//
//  MainContentCoordinatorRefreshTests.swift
//  TableProTests
//
//  Tests for handleRefresh, the entry point behind the Refresh toolbar
//  button and Cmd+R. Regression coverage for #1637: a refresh issued while
//  a query was in flight was silently dropped because the in-flight
//  cancellation cleared isExecuting asynchronously.
//

import Combine
import Foundation
import Testing

@testable import TablePro

@MainActor
struct MainContentCoordinatorRefreshTests {
    private func makeCoordinator() -> (MainContentCoordinator, QueryTabManager) {
        makeCoordinator(connection: TestFixtures.makeConnection())
    }

    private func makeCoordinator(
        connection: DatabaseConnection
    ) -> (MainContentCoordinator, QueryTabManager) {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        return (coordinator, tabManager)
    }

    private func withInjectedDriver(
        _ body: (DatabaseConnection, MockDatabaseDriver) -> Void
    ) {
        let connection = TestFixtures.makeConnection()
        let driver = MockDatabaseDriver(connection: connection)
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: connection, driver: driver),
            for: connection.id
        )
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        body(connection, driver)
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

    @discardableResult
    private func simulateInFlightQuery(
        _ coordinator: MainContentCoordinator,
        _ tabManager: QueryTabManager,
        at index: Int,
        lease: DriverLeaseOwner = DriverLeaseOwner()
    ) -> Task<Void, Never> {
        let inFlight = Task<Void, Never> { _ = try? await Task.sleep(for: .seconds(60)) }
        let tabId = tabManager.tabs[index].id
        let claim = coordinator.tabExecution.claim(tabId)
        coordinator.installQueryTask(inFlight, owner: .claim(claim), lease: lease)
        tabManager.tabs[index].execution.lastExecutedAt = Date()
        return inFlight
    }

    /// A tab whose lease is registered with the injected driver, which is what makes a driver cancel
    /// observable at all: without it `cancelRunningQuery` finds nothing for that owner.
    private func seedLease(
        _ driver: DatabaseDriver,
        lease: DriverLeaseOwner,
        for connectionId: UUID
    ) {
        DatabaseManager.shared.runningDrivers[connectionId, default: [:]][UUID()] =
            RunningDriver(driver: driver, policy: .cancellableRead(lease))
    }

    @Test("Refresh while a query is in flight cancels it and starts a new execution")
    func refreshWithInFlightQueryStartsNewExecution() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("expected tab to exist")
            return
        }
        let staleTask = simulateInFlightQuery(coordinator, tabManager, at: idx)
        let initialEpoch = coordinator.tabExecution.contentEpoch(for: tabId)

        coordinator.handleRefresh(hasPendingTableOps: false, onDiscard: {})
        defer { coordinator.cancelAllQueryTasks() }

        #expect(staleTask.isCancelled == true)
        #expect(coordinator.tabExecution.contentEpoch(for: tabId) != initialEpoch)
        #expect(coordinator.queryTasks.hasTask(for: tabId))
        #expect(coordinator.tabExecution.isExecuting(tabId) == true)
    }

    @Test("Refresh on an idle table tab starts an execution")
    func refreshOnIdleTabStartsExecution() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("expected tab to exist")
            return
        }
        tabManager.tabs[idx].execution.lastExecutedAt = Date()
        let initialEpoch = coordinator.tabExecution.contentEpoch(for: tabId)

        coordinator.handleRefresh(hasPendingTableOps: false, onDiscard: {})
        defer { coordinator.cancelAllQueryTasks() }

        #expect(coordinator.tabExecution.contentEpoch(for: tabId) != initialEpoch)
        #expect(coordinator.queryTasks.hasTask(for: tabId))
        #expect(coordinator.tabExecution.isExecuting(tabId) == true)
    }

    @Test("Refresh rebuilds the table query from current state before executing")
    func refreshRebuildsQuery() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager, query: "SELECT outdated FROM users")
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("expected tab to exist")
            return
        }
        tabManager.tabs[idx].execution.lastExecutedAt = Date()

        coordinator.handleRefresh(hasPendingTableOps: false, onDiscard: {})
        defer { coordinator.cancelAllQueryTasks() }

        #expect(tabManager.tabs[idx].content.query != "SELECT outdated FROM users")
        #expect(tabManager.tabs[idx].content.query.contains("users"))
    }

    @Test("Refresh on a query tab does not execute or cancel anything")
    func refreshOnQueryTabIsNoOp() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addQueryTab(to: tabManager)
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("expected tab to exist")
            return
        }
        let inFlight = simulateInFlightQuery(coordinator, tabManager, at: idx)
        defer { inFlight.cancel() }
        let initialEpoch = coordinator.tabExecution.contentEpoch(for: tabId)

        coordinator.handleRefresh(hasPendingTableOps: false, onDiscard: {})

        #expect(inFlight.isCancelled == false)
        #expect(coordinator.tabExecution.contentEpoch(for: tabId) == initialEpoch)
        #expect(coordinator.tabExecution.isExecuting(tabId) == true)
    }

    @Test("Refresh in structure view leaves execution state untouched")
    func refreshInStructureViewIsNoOp() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("expected tab to exist")
            return
        }
        tabManager.tabs[idx].display.resultsViewMode = .structure
        let staleTask = simulateInFlightQuery(coordinator, tabManager, at: idx)
        defer { staleTask.cancel() }
        let initialEpoch = coordinator.tabExecution.contentEpoch(for: tabId)

        coordinator.handleRefresh(hasPendingTableOps: false, onDiscard: {})

        #expect(staleTask.isCancelled == false)
        #expect(coordinator.tabExecution.contentEpoch(for: tabId) == initialEpoch)
        #expect(coordinator.tabExecution.isExecuting(tabId) == true)
    }

    @Test("cancelCurrentQuery leaves the driver alone when no query is in flight")
    func cancelWithoutInFlightDoesNotTouchDriver() {
        withInjectedDriver { connection, driver in
            let (coordinator, _) = makeCoordinator(connection: connection)

            coordinator.cancelCurrentQuery()

            #expect(driver.cancelQueryCallCount == 0)
        }
    }

    @Test("A finished row count leaves no handle that fakes an in-flight query")
    func cancelWithStaleRowCountHandleDoesNotTouchDriver() {
        withInjectedDriver { connection, driver in
            let (coordinator, tabManager) = makeCoordinator(connection: connection)
            let tabId = addTableTab(to: tabManager)
            coordinator.setRowCountTask(Task<Void, Never> {}, token: UUID(), for: tabId)

            coordinator.cancelCurrentQuery()

            #expect(driver.cancelQueryCallCount == 0)
            #expect(coordinator.rowCountTasks.isEmpty)
        }
    }

    @Test("Refreshing an idle table tab twice never issues a stray driver cancel")
    func repeatedIdleRefreshNeverCancelsDriver() {
        withInjectedDriver { connection, driver in
            let (coordinator, tabManager) = makeCoordinator(connection: connection)
            let tabId = addTableTab(to: tabManager)
            guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
                Issue.record("expected tab to exist")
                return
            }
            tabManager.tabs[idx].execution.lastExecutedAt = Date()

            for _ in 0..<4 {
                coordinator.setRowCountTask(Task<Void, Never> {}, token: UUID(), for: tabId)
                coordinator.handleRefresh(hasPendingTableOps: false, onDiscard: {})
                coordinator.cancelAllQueryTasks()
            }

            #expect(driver.cancelQueryCallCount == 0)
        }
    }

    @Test("cancelCurrentQuery cancels the driver when the selected tab has a query in flight")
    func cancelWithInFlightCancelsDriver() {
        withInjectedDriver { connection, driver in
            let (coordinator, tabManager) = makeCoordinator(connection: connection)
            let tabId = addTableTab(to: tabManager)
            guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
                Issue.record("expected tab to exist")
                return
            }
            let lease = DriverLeaseOwner()
            seedLease(driver, lease: lease, for: connection.id)
            let inFlight = simulateInFlightQuery(coordinator, tabManager, at: idx, lease: lease)
            defer { inFlight.cancel() }

            coordinator.cancelCurrentQuery()

            #expect(driver.cancelQueryCallCount == 1)
            #expect(inFlight.isCancelled)
        }
    }

    /// Stop acts on the selected tab, so a background tab's query is not its business. Before the
    /// per-tab change this cancelled the driver of whatever the window happened to hold.
    @Test("cancelCurrentQuery leaves a background tab's query running")
    func cancelLeavesABackgroundTabAlone() {
        withInjectedDriver { connection, driver in
            let (coordinator, tabManager) = makeCoordinator(connection: connection)
            let background = addTableTab(to: tabManager, tableName: "orders")
            let selected = addQueryTab(to: tabManager)
            guard let idx = tabManager.tabs.firstIndex(where: { $0.id == background }) else {
                Issue.record("expected tab to exist")
                return
            }
            let lease = DriverLeaseOwner()
            seedLease(driver, lease: lease, for: connection.id)
            let inFlight = simulateInFlightQuery(coordinator, tabManager, at: idx, lease: lease)
            defer { inFlight.cancel() }
            tabManager.selectedTabId = selected

            coordinator.cancelCurrentQuery()

            #expect(driver.cancelQueryCallCount == 0)
            #expect(inFlight.isCancelled == false)
            #expect(coordinator.tabExecution.isExecuting(background))
        }
    }

    @Test("Refresh on an idle table tab does not issue a stray driver cancel")
    func idleRefreshDoesNotCancelDriver() {
        withInjectedDriver { connection, driver in
            let (coordinator, tabManager) = makeCoordinator(connection: connection)
            let tabId = addTableTab(to: tabManager)
            guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
                Issue.record("expected tab to exist")
                return
            }
            tabManager.tabs[idx].execution.lastExecutedAt = Date()

            coordinator.handleRefresh(hasPendingTableOps: false, onDiscard: {})
            defer { coordinator.cancelAllQueryTasks() }

            #expect(driver.cancelQueryCallCount == 0)
        }
    }

    @Test("Refresh in structure view dispatches to the structure refresh handler")
    func refreshInStructureViewDispatchesToHandler() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("expected tab to exist")
            return
        }
        tabManager.tabs[idx].display.resultsViewMode = .structure

        let handler = StructureViewActionHandler()
        var refreshCalled = false
        handler.refresh = { refreshCalled = true }
        coordinator.structureActions = handler

        let initialEpoch = coordinator.tabExecution.contentEpoch(for: tabId)
        coordinator.handleRefresh(hasPendingTableOps: false, onDiscard: {})

        #expect(refreshCalled == true)
        #expect(coordinator.tabExecution.contentEpoch(for: tabId) == initialEpoch)
        #expect(coordinator.queryTasks.hasTask(for: tabId) == false)
    }

    @Test("requestRefresh fires immediately and coalesces a rapid second call")
    func requestRefreshCoalescesRapidCalls() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("expected tab to exist")
            return
        }
        tabManager.tabs[idx].execution.lastExecutedAt = Date()
        defer {
            coordinator.refreshCoalesceTask?.cancel()
            coordinator.cancelAllQueryTasks()
        }
        let initialEpoch = coordinator.tabExecution.contentEpoch(for: tabId)

        coordinator.requestRefresh(hasPendingTableOps: false, onDiscard: {})
        let epochAfterLeading = coordinator.tabExecution.contentEpoch(for: tabId)
        coordinator.requestRefresh(hasPendingTableOps: false, onDiscard: {})
        let epochAfterSecond = coordinator.tabExecution.contentEpoch(for: tabId)

        #expect(epochAfterLeading != initialEpoch)
        #expect(epochAfterSecond == epochAfterLeading)
        #expect(coordinator.refreshPendingTrailing == true)
        #expect(coordinator.refreshCoalesceTask != nil)
    }

    @Test("A single requestRefresh fires once and schedules no trailing refresh")
    func singleRequestRefreshHasNoTrailing() async {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("expected tab to exist")
            return
        }
        tabManager.tabs[idx].execution.lastExecutedAt = Date()
        defer { coordinator.cancelAllQueryTasks() }

        coordinator.requestRefresh(hasPendingTableOps: false, onDiscard: {})
        let epochAfterLeading = coordinator.tabExecution.contentEpoch(for: tabId)

        try? await Task.sleep(for: .milliseconds(400))

        #expect(coordinator.tabExecution.contentEpoch(for: tabId) == epochAfterLeading)
        #expect(coordinator.refreshPendingTrailing == false)
        #expect(coordinator.refreshCoalesceTask == nil)
    }

    @Test("Refresh on a history tab asks that tab to reload its versions")
    func refreshOnHistoryTabReloadsHistory() {
        let (coordinator, tabManager) = makeCoordinator()
        tabManager.addVersionHistoryTab(subject: .savedQuery(id: UUID()), title: "History: Revenue")
        let tabId = tabManager.selectedTabId
        var requested: [UUID] = []
        let subscription = AppEvents.shared.versionHistoryRefreshRequested.sink { requested.append($0) }
        defer { subscription.cancel() }

        coordinator.handleRefresh(hasPendingTableOps: false, onDiscard: {})

        #expect(requested == [tabId].compactMap { $0 })
    }
}
