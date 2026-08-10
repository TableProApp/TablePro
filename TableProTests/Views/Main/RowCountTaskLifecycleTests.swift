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

        coordinator.setRowCountTask(first, token: UUID(), for: tabId)
        coordinator.setRowCountTask(Self.neverEndingTask(), token: UUID(), for: tabId)

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

        coordinator.setRowCountTask(countA, token: UUID(), for: tabA)
        coordinator.setRowCountTask(countB, token: UUID(), for: tabB)

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
        coordinator.setRowCountTask(countA, token: UUID(), for: tabA)
        coordinator.setRowCountTask(countB, token: UUID(), for: tabB)

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
        coordinator.setRowCountTask(countA, token: UUID(), for: tabA)
        coordinator.setRowCountTask(countB, token: UUID(), for: tabB)

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
        coordinator.setRowCountTask(countA, token: UUID(), for: tabA)
        coordinator.setRowCountTask(countB, token: UUID(), for: tabB)

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
        let token = UUID()
        coordinator.setRowCountTask(count, token: token, for: tabId)

        coordinator.clearRowCountTask(for: tabId, token: token)

        #expect(count.isCancelled == false)
        #expect(coordinator.rowCountTasks.isEmpty)
    }

    /// A superseded task still runs its completion path. Once phase 2 validates content identity
    /// rather than a claim that is already settled, that path is reached, so without the token the
    /// finishing task clears the successor that replaced it and leaves it uncancellable.
    @Test("A superseded task cannot clear the handle of the one that replaced it")
    func supersededTaskCannotClearItsSuccessor() {
        let (coordinator, tabManager) = Self.makeCoordinator()
        let tabId = Self.addTableTab(to: tabManager)
        let firstToken = UUID()
        let first = Self.neverEndingTask()
        let second = Self.neverEndingTask()
        defer {
            first.cancel()
            second.cancel()
        }
        coordinator.setRowCountTask(first, token: firstToken, for: tabId)
        coordinator.setRowCountTask(second, token: UUID(), for: tabId)

        coordinator.clearRowCountTask(for: tabId, token: firstToken)

        #expect(coordinator.rowCountTasks[tabId] != nil)
        #expect(second.isCancelled == false)
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
