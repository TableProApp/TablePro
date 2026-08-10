//
//  RowCountTaskLifecycleTests.swift
//  TableProTests
//
//  A row count is per tab, so its handle is too. One shared slot per window let the second tab to
//  ask drop the first tab's task with nothing left able to cancel it, not even teardown (#2059).
//

import Foundation
@testable import TablePro
import Testing

@Suite("Row count task lifecycle")
@MainActor
struct RowCountTaskLifecycleTests {
    @Test("A tab's second row count cancels its first")
    func secondCountForTheSameTabCancelsTheFirst() {
        let (coordinator, tabManager) = Self.makeCoordinator()
        let tabId = Self.addTableTab(to: tabManager)
        let first = Self.neverEndingTask()
        defer { first.cancel() }

        coordinator.setRowCountTask(first, for: tabId)
        coordinator.setRowCountTask(Self.neverEndingTask(), for: tabId)

        #expect(first.isCancelled)
        #expect(coordinator.rowCountTasks.count == 1)
    }

    /// The bug: one slot for the whole window meant tab B's count evicted tab A's handle without
    /// cancelling it, so tab A's task ran on with no reference left to stop it.
    @Test("A count on another tab leaves the first tab's count alone")
    func countOnAnotherTabDoesNotDisturbTheFirst() {
        let (coordinator, tabManager) = Self.makeCoordinator()
        let tabA = Self.addTableTab(to: tabManager, tableName: "orders")
        let tabB = Self.addTableTab(to: tabManager, tableName: "customers")
        let countA = Self.neverEndingTask()
        let countB = Self.neverEndingTask()
        defer {
            countA.cancel()
            countB.cancel()
        }

        coordinator.setRowCountTask(countA, for: tabA)
        coordinator.setRowCountTask(countB, for: tabB)

        #expect(countA.isCancelled == false)
        #expect(coordinator.rowCountTasks.count == 2)
    }

    @Test("Retargeting a tab cancels only that tab's row count")
    func supersedingATabCancelsOnlyItsOwnCount() {
        let (coordinator, tabManager) = Self.makeCoordinator()
        let tabA = Self.addTableTab(to: tabManager, tableName: "orders")
        let tabB = Self.addTableTab(to: tabManager, tableName: "customers")
        let countA = Self.neverEndingTask()
        let countB = Self.neverEndingTask()
        defer {
            countA.cancel()
            countB.cancel()
        }
        coordinator.setRowCountTask(countA, for: tabA)
        coordinator.setRowCountTask(countB, for: tabB)

        coordinator.supersedeExecution(for: tabA)

        #expect(countA.isCancelled)
        #expect(countB.isCancelled == false)
        #expect(coordinator.rowCountTasks[tabA] == nil)
    }

    /// Closing a window used to leave every in-flight count running, each holding the coordinator
    /// alive through a strong capture until its own driver round trip returned.
    @Test("Teardown cancels every tab's row count")
    func teardownCancelsEveryRowCount() {
        let (coordinator, tabManager) = Self.makeCoordinator()
        let tabA = Self.addTableTab(to: tabManager, tableName: "orders")
        let tabB = Self.addTableTab(to: tabManager, tableName: "customers")
        let countA = Self.neverEndingTask()
        let countB = Self.neverEndingTask()
        coordinator.setRowCountTask(countA, for: tabA)
        coordinator.setRowCountTask(countB, for: tabB)

        coordinator.teardown()

        #expect(countA.isCancelled)
        #expect(countB.isCancelled)
        #expect(coordinator.rowCountTasks.isEmpty)
    }

    @Test("Stop cancels every tab's row count")
    func stopCancelsEveryRowCount() {
        let (coordinator, tabManager) = Self.makeCoordinator()
        let tabA = Self.addTableTab(to: tabManager, tableName: "orders")
        let tabB = Self.addTableTab(to: tabManager, tableName: "customers")
        let countA = Self.neverEndingTask()
        let countB = Self.neverEndingTask()
        coordinator.setRowCountTask(countA, for: tabA)
        coordinator.setRowCountTask(countB, for: tabB)

        coordinator.cancelCurrentQuery()

        #expect(countA.isCancelled)
        #expect(countB.isCancelled)
        #expect(coordinator.rowCountTasks.isEmpty)
    }

    /// A task that finished on its own drops its handle without cancelling a successor that may
    /// already have taken the slot.
    @Test("Clearing a finished count never cancels anything")
    func clearingAFinishedCountCancelsNothing() {
        let (coordinator, tabManager) = Self.makeCoordinator()
        let tabId = Self.addTableTab(to: tabManager)
        let count = Self.neverEndingTask()
        defer { count.cancel() }
        coordinator.setRowCountTask(count, for: tabId)

        coordinator.clearRowCountTask(for: tabId)

        #expect(count.isCancelled == false)
        #expect(coordinator.rowCountTasks.isEmpty)
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

    private static func addTableTab(
        to tabManager: QueryTabManager,
        tableName: String = "users"
    ) -> UUID {
        let tab = QueryTab(
            title: tableName,
            query: "SELECT * FROM \(tableName)",
            tabType: .table,
            tableName: tableName
        )
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        return tab.id
    }

    private static func neverEndingTask() -> Task<Void, Never> {
        Task { _ = try? await Task.sleep(for: .seconds(60)) }
    }
}
