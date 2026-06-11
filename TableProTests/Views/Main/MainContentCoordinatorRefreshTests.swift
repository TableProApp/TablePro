//
//  MainContentCoordinatorRefreshTests.swift
//  TableProTests
//
//  Tests for handleRefresh, the entry point behind the Refresh toolbar
//  button and Cmd+R. Regression coverage for #1637: a refresh issued while
//  a query was in flight was silently dropped because the in-flight
//  cancellation cleared isExecuting asynchronously.
//

import Foundation
import Testing

@testable import TablePro

@Suite("MainContentCoordinator handleRefresh")
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

    private func simulateInFlightQuery(
        _ coordinator: MainContentCoordinator,
        _ tabManager: QueryTabManager,
        at index: Int
    ) -> Task<Void, Never> {
        let inFlight = Task<Void, Never> { _ = try? await Task.sleep(for: .seconds(60)) }
        coordinator.currentQueryTask = inFlight
        tabManager.tabs[index].execution.isExecuting = true
        tabManager.tabs[index].execution.lastExecutedAt = Date()
        return inFlight
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
        let initialGeneration = coordinator.queryGeneration

        coordinator.handleRefresh(hasPendingTableOps: false, onDiscard: {})
        defer { coordinator.currentQueryTask?.cancel() }

        #expect(staleTask.isCancelled == true)
        #expect(coordinator.queryGeneration == initialGeneration + 2)
        #expect(coordinator.currentQueryTask != nil)
        #expect(tabManager.tabs[idx].execution.isExecuting == true)
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
        let initialGeneration = coordinator.queryGeneration

        coordinator.handleRefresh(hasPendingTableOps: false, onDiscard: {})
        defer { coordinator.currentQueryTask?.cancel() }

        #expect(coordinator.queryGeneration == initialGeneration + 2)
        #expect(coordinator.currentQueryTask != nil)
        #expect(tabManager.tabs[idx].execution.isExecuting == true)
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
        defer { coordinator.currentQueryTask?.cancel() }

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
        let inFlight = Task<Void, Never> { _ = try? await Task.sleep(for: .seconds(60)) }
        defer { inFlight.cancel() }
        coordinator.currentQueryTask = inFlight
        tabManager.tabs[idx].execution.isExecuting = true
        let initialGeneration = coordinator.queryGeneration

        coordinator.handleRefresh(hasPendingTableOps: false, onDiscard: {})

        #expect(inFlight.isCancelled == false)
        #expect(coordinator.queryGeneration == initialGeneration)
        #expect(tabManager.tabs[idx].execution.isExecuting == true)
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
        let initialGeneration = coordinator.queryGeneration

        coordinator.handleRefresh(hasPendingTableOps: false, onDiscard: {})

        #expect(staleTask.isCancelled == false)
        #expect(coordinator.queryGeneration == initialGeneration)
        #expect(tabManager.tabs[idx].execution.isExecuting == true)
    }

    @Test("cancelCurrentQuery leaves the driver alone when no query is in flight")
    func cancelWithoutInFlightDoesNotTouchDriver() {
        withInjectedDriver { connection, driver in
            let (coordinator, _) = makeCoordinator(connection: connection)

            coordinator.cancelCurrentQuery()

            #expect(driver.cancelQueryCallCount == 0)
        }
    }

    @Test("cancelCurrentQuery cancels the driver when a query is in flight")
    func cancelWithInFlightCancelsDriver() {
        withInjectedDriver { connection, driver in
            let (coordinator, _) = makeCoordinator(connection: connection)
            let inFlight = Task<Void, Never> { _ = try? await Task.sleep(for: .seconds(60)) }
            defer { inFlight.cancel() }
            coordinator.currentQueryTask = inFlight

            coordinator.cancelCurrentQuery()

            #expect(driver.cancelQueryCallCount == 1)
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
            defer { coordinator.currentQueryTask?.cancel() }

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

        let initialGeneration = coordinator.queryGeneration
        coordinator.handleRefresh(hasPendingTableOps: false, onDiscard: {})

        #expect(refreshCalled == true)
        #expect(coordinator.queryGeneration == initialGeneration)
        #expect(coordinator.currentQueryTask == nil)
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
            coordinator.currentQueryTask?.cancel()
        }
        let initialGeneration = coordinator.queryGeneration

        coordinator.requestRefresh(hasPendingTableOps: false, onDiscard: {})
        let generationAfterLeading = coordinator.queryGeneration
        coordinator.requestRefresh(hasPendingTableOps: false, onDiscard: {})
        let generationAfterSecond = coordinator.queryGeneration

        #expect(generationAfterLeading == initialGeneration + 2)
        #expect(generationAfterSecond == generationAfterLeading)
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
        defer { coordinator.currentQueryTask?.cancel() }

        coordinator.requestRefresh(hasPendingTableOps: false, onDiscard: {})
        let generationAfterLeading = coordinator.queryGeneration

        try? await Task.sleep(for: .milliseconds(400))

        #expect(coordinator.queryGeneration == generationAfterLeading)
        #expect(coordinator.refreshPendingTrailing == false)
        #expect(coordinator.refreshCoalesceTask == nil)
    }
}
