//
//  QueryFailureReportingTests.swift
//  TableProTests
//
//  A failed query has one job: say so. The 0.64.0 execution-ownership refactor released the tab's
//  claim before asking whether the claim still owned the tab, and that question is always answered
//  no once the claim is released, so every failure returned before it could report anything (#2120).
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Query failure reporting", .serialized)
@MainActor
struct QueryFailureReportingTests {
    private struct DriverFailure: LocalizedError {
        let errorDescription: String? = "relation \"stu\" does not exist"
    }

    @Test("A failed query reports the database's error on the tab")
    func failureSetsTheErrorMessage() {
        let (coordinator, tabManager) = Self.makeCoordinator()
        let tabId = Self.addQueryTab(to: tabManager)
        let claim = coordinator.tabExecution.claim(tabId)

        Self.finishFailure(on: coordinator, tabId: tabId, claim: claim)

        let tab = try? #require(tabManager.tabs.first)
        #expect(tab?.execution.errorMessage == "relation \"stu\" does not exist")
        #expect(tab?.execution.errorQuery == "select * from stu")
        #expect(tab?.execution.lastExecutedAt != nil)
    }

    /// The banner is drawn at the top of the results pane, so a collapsed pane hides the only thing
    /// that says the query failed. Every success path opens it; the failure paths did not.
    @Test("A failure opens a collapsed results pane")
    func failureOpensCollapsedResults() {
        let (coordinator, tabManager) = Self.makeCoordinator()
        let tabId = Self.addQueryTab(to: tabManager)
        tabManager.mutate(tabId: tabId) { $0.display.isResultsCollapsed = true }
        let claim = coordinator.tabExecution.claim(tabId)

        Self.finishFailure(on: coordinator, tabId: tabId, claim: claim)

        #expect(tabManager.tabs.first?.display.isResultsCollapsed == false)
        #expect(coordinator.toolbarState.isResultsCollapsed == false)
    }

    /// The toolbar's duration readout is only written on success, so a failure that left it alone
    /// showed the previous run's timing beside a red banner.
    @Test("A failure clears the duration left over from the last successful run")
    func failureClearsTheStaleDuration() {
        let (coordinator, tabManager) = Self.makeCoordinator()
        let tabId = Self.addQueryTab(to: tabManager)
        coordinator.toolbarState.lastQueryDuration = 1.5
        let claim = coordinator.tabExecution.claim(tabId)

        Self.finishFailure(on: coordinator, tabId: tabId, claim: claim)

        #expect(coordinator.toolbarState.lastQueryDuration == nil)
        #expect(tabManager.tabs.first?.execution.executionTime == nil)
    }

    @Test("Reporting a failure releases the tab so the next run is not blocked")
    func failureReleasesTheTab() {
        let (coordinator, tabManager) = Self.makeCoordinator()
        let tabId = Self.addQueryTab(to: tabManager)
        let claim = coordinator.tabExecution.claim(tabId)
        #expect(coordinator.tabExecution.isExecuting(tabId))

        Self.finishFailure(on: coordinator, tabId: tabId, claim: claim)

        #expect(coordinator.tabExecution.isExecuting(tabId) == false)
    }

    @Test("A cancelled query is not reported as an error")
    func cancellationIsNotAnError() {
        let (coordinator, tabManager) = Self.makeCoordinator()
        let tabId = Self.addQueryTab(to: tabManager)
        let claim = coordinator.tabExecution.claim(tabId)

        Self.finishFailure(on: coordinator, tabId: tabId, claim: claim, error: CancellationError())

        #expect(tabManager.tabs.first?.execution.errorMessage == nil)
    }

    /// The other half of the gate. A result that lost the tab must not report into it, and must not
    /// clear the spinner belonging to the navigation that replaced it.
    @Test("A superseded failure writes nothing and leaves the successor's spinner alone")
    func supersededFailureIsSilent() {
        let (coordinator, tabManager) = Self.makeCoordinator()
        let tabId = Self.addQueryTab(to: tabManager)
        let stale = coordinator.tabExecution.claim(tabId)
        _ = coordinator.tabExecution.claim(tabId)
        coordinator.toolbarState.setExecuting(true)

        Self.finishFailure(on: coordinator, tabId: tabId, claim: stale)

        #expect(tabManager.tabs.first?.execution.errorMessage == nil)
        #expect(coordinator.toolbarState.isExecuting)
        #expect(coordinator.tabExecution.isExecuting(tabId))
    }

    /// The window's task handle is one per window while claims are one per tab, so owning your own
    /// tab is not owning the query the window is running.
    @Test("Retiring the task handle only works for the execution that installed it")
    func onlyTheInstallerRetiresTheTaskHandle() {
        let (coordinator, tabManager) = Self.makeCoordinator()
        let tabId = Self.addQueryTab(to: tabManager)
        let otherTabId = Self.addQueryTab(to: tabManager, title: "Query 2")
        let running = coordinator.tabExecution.claim(otherTabId)
        let stranger = coordinator.tabExecution.claim(tabId)

        let task = Task<Void, Never> {}
        coordinator.installQueryTask(task, for: running)
        coordinator.toolbarState.setExecuting(true)

        coordinator.retireQueryTask(for: stranger)
        #expect(coordinator.currentQueryTask != nil)
        #expect(coordinator.toolbarState.isExecuting)

        coordinator.retireQueryTask(for: running)
        #expect(coordinator.currentQueryTask == nil)
        #expect(coordinator.toolbarState.isExecuting == false)
        task.cancel()
    }

    /// Cancelling goes through the same ownership check as any other completion. A cancelled attempt
    /// that has already been replaced would otherwise take its successor's handle and spinner down
    /// with it, leaving a running query with no spinner and nothing for Stop to reach.
    @Test("Resetting after a cancel leaves a successor's task handle alone")
    func cancelResetRespectsTheHandleOwner() {
        let (coordinator, tabManager) = Self.makeCoordinator()
        let tabId = Self.addQueryTab(to: tabManager)
        let otherTabId = Self.addQueryTab(to: tabManager, title: "Query 2")
        let cancelled = coordinator.tabExecution.claim(tabId)
        let successor = coordinator.tabExecution.claim(otherTabId)

        let task = Task<Void, Never> {}
        coordinator.installQueryTask(task, for: successor)
        coordinator.toolbarState.setExecuting(true)

        coordinator.resetExecutionState(claim: cancelled, executionTime: 0.5)

        #expect(coordinator.currentQueryTask != nil)
        #expect(coordinator.toolbarState.isExecuting)
        #expect(coordinator.tabExecution.isExecuting(tabId) == false)
        #expect(coordinator.tabExecution.isCurrent(successor))
        task.cancel()
    }

    /// The toolbar mirrors the selected tab, so a failure on a background tab must not repaint the
    /// window chrome around whatever the user is actually looking at.
    @Test("A background tab's failure leaves the toolbar describing the selected tab")
    func backgroundFailureLeavesTheToolbarAlone() {
        let (coordinator, tabManager) = Self.makeCoordinator()
        let backgroundTabId = Self.addQueryTab(to: tabManager)
        let selectedTabId = Self.addQueryTab(to: tabManager, title: "Query 2")
        tabManager.selectedTabId = selectedTabId
        coordinator.toolbarState.lastQueryDuration = 1.5
        coordinator.toolbarState.isResultsCollapsed = true
        let claim = coordinator.tabExecution.claim(backgroundTabId)

        Self.finishFailure(on: coordinator, tabId: backgroundTabId, claim: claim)

        #expect(tabManager.tabs.first?.execution.errorMessage != nil)
        #expect(coordinator.toolbarState.lastQueryDuration == 1.5)
        #expect(coordinator.toolbarState.isResultsCollapsed)
    }

    /// The change manager is one per window and holds whichever tab is selected. Clearing it from a
    /// completion on a different tab throws away edits and undo history the user can never get back.
    @Test("Clearing pending changes never reaches a tab the user has switched to")
    func pendingChangesOfAnotherTabSurvive() {
        let (coordinator, tabManager) = Self.makeCoordinator()
        let backgroundTabId = Self.addQueryTab(to: tabManager)
        let selectedTabId = Self.addQueryTab(to: tabManager, title: "Query 2")
        let claim = coordinator.tabExecution.claim(backgroundTabId)
        let settled = coordinator.tabExecution.settle(claim)
        #expect(settled)

        tabManager.selectedTabId = selectedTabId
        coordinator.changeManager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: nil,
            newValue: "edited"
        )
        #expect(coordinator.changeManager.hasChanges)

        coordinator.clearChangesIfCurrent(claim: claim)

        #expect(coordinator.changeManager.hasChanges)
    }

    private static func finishFailure(
        on coordinator: MainContentCoordinator,
        tabId: UUID,
        claim: TabExecutionClaim,
        error: Error = DriverFailure()
    ) {
        coordinator.finishFailedQuery(
            error,
            tabId: tabId,
            sql: "select * from stu",
            connection: TestFixtures.makeConnection(),
            claim: claim,
            isAutoLoad: false,
            trigger: .userInitiated,
            traceToken: nil
        )
    }

    private static func makeCoordinator() -> (MainContentCoordinator, QueryTabManager) {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        return (coordinator, tabManager)
    }

    @discardableResult
    private static func addQueryTab(to tabManager: QueryTabManager, title: String = "Query") -> UUID {
        let tab = QueryTab(title: title, query: "select * from stu", tabType: .query)
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        return tab.id
    }
}
