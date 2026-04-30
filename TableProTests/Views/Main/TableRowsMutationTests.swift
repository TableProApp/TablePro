//
//  TableRowsMutationTests.swift
//  TableProTests
//
//  Regression tests for the setActiveTableRows / switchActiveResultSet
//  dispatch path. Without applyFullReplace, the data grid coordinator's
//  RowID-keyed display cache survives table switches and returns stale
//  cell values for matching RowIDs across tables.
//

import AppKit
import Foundation
import Testing
@testable import TablePro

@MainActor
private final class FakeTableViewCoordinator: TableViewCoordinating {
    var fullReplaceCount = 0
    var insertedCount = 0
    var removedCount = 0
    var deltaCount = 0
    var invalidateCount = 0
    var commitEditCount = 0
    var beginEditingCalls: [(row: Int, column: Int)] = []

    func applyInsertedRows(_ indices: IndexSet) { insertedCount += 1 }
    func applyRemovedRows(_ indices: IndexSet) { removedCount += 1 }
    func applyFullReplace() { fullReplaceCount += 1 }
    func applyDelta(_ delta: Delta) { deltaCount += 1 }
    func invalidateCachesForUndoRedo() { invalidateCount += 1 }
    func commitActiveCellEdit() { commitEditCount += 1 }
    func beginEditing(displayRow: Int, column: Int) {
        beginEditingCalls.append((row: displayRow, column: column))
    }

    var refreshFKCount = 0
    var scrollToTopCount = 0
    func refreshForeignKeyColumns() { refreshFKCount += 1 }
    func scrollToTop() { scrollToTopCount += 1 }
}

@Suite("setActiveTableRows dispatch")
@MainActor
struct TableRowsMutationTests {
    private struct Fixture {
        let coordinator: MainContentCoordinator
        let tabManager: QueryTabManager
        let delegate: DataTabGridDelegate
        let fake: FakeTableViewCoordinator
    }

    private func makeFixture() -> Fixture {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            filterStateManager: FilterStateManager(),
            columnVisibilityManager: ColumnVisibilityManager(),
            toolbarState: ConnectionToolbarState()
        )
        let delegate = DataTabGridDelegate()
        let fake = FakeTableViewCoordinator()
        delegate.tableViewCoordinator = fake
        coordinator.dataTabDelegate = delegate
        return Fixture(coordinator: coordinator, tabManager: tabManager, delegate: delegate, fake: fake)
    }

    private func makeTableRows(rowCount: Int) -> TableRows {
        let columns = ["id", "name"]
        let rows = (0..<rowCount).map { ["\($0)", "row\($0)"] }
        return TableRows.from(
            queryRows: rows,
            columns: columns,
            columnTypes: Array(repeating: .text(rawType: nil), count: columns.count)
        )
    }

    @Test("setActiveTableRows on the active tab dispatches applyFullReplace")
    func dispatchesOnActiveTab() throws {
        let f = makeFixture()
        f.try tabManager.addTableTab(tableName: "users")
        let activeTabId = f.tabManager.tabs[0].id

        f.coordinator.setActiveTableRows(makeTableRows(rowCount: 3), for: activeTabId)

        #expect(f.fake.fullReplaceCount == 1)
    }

    @Test("setActiveTableRows on a background tab does not dispatch")
    func skipsOnBackgroundTab() throws {
        let f = makeFixture()
        f.try tabManager.addTableTab(tableName: "users")
        let backgroundTabId = f.tabManager.tabs[0].id
        f.try tabManager.addTableTab(tableName: "orders")

        f.coordinator.setActiveTableRows(makeTableRows(rowCount: 5), for: backgroundTabId)

        #expect(f.fake.fullReplaceCount == 0)
    }

    @Test("repeated setActiveTableRows dispatches once per call")
    func dispatchesOncePerCall() throws {
        let f = makeFixture()
        f.try tabManager.addTableTab(tableName: "users")
        let activeTabId = f.tabManager.tabs[0].id

        f.coordinator.setActiveTableRows(TableRows(), for: activeTabId)
        f.coordinator.setActiveTableRows(makeTableRows(rowCount: 3), for: activeTabId)

        #expect(f.fake.fullReplaceCount == 2)
    }

    @Test("setActiveTableRows dispatches scrollToTop when pendingScrollToTopAfterReplace contains tabId")
    func scrollToTopFiresOnPendingFlag() throws {
        let f = makeFixture()
        f.try tabManager.addTableTab(tableName: "users")
        let activeTabId = f.tabManager.tabs[0].id

        f.coordinator.pendingScrollToTopAfterReplace.insert(activeTabId)
        f.coordinator.setActiveTableRows(makeTableRows(rowCount: 3), for: activeTabId)

        #expect(f.fake.scrollToTopCount == 1)
        #expect(f.coordinator.pendingScrollToTopAfterReplace.contains(activeTabId) == false)
    }

    @Test("scrollToTop pending flag for tab A does not fire when tab B is replaced")
    func scrollToTopFlagIsScopedPerTab() throws {
        let f = makeFixture()
        f.try tabManager.addTableTab(tableName: "users")
        let firstTabId = f.tabManager.tabs[0].id
        f.try tabManager.addTableTab(tableName: "orders")
        let secondTabId = f.tabManager.tabs[1].id

        f.coordinator.pendingScrollToTopAfterReplace.insert(firstTabId)
        f.coordinator.setActiveTableRows(makeTableRows(rowCount: 3), for: secondTabId)

        #expect(f.fake.scrollToTopCount == 0)
        #expect(f.coordinator.pendingScrollToTopAfterReplace.contains(firstTabId) == true)
    }

    @Test("setActiveTableRows without pending flag does not scroll to top")
    func scrollToTopSkippedWhenFlagAbsent() throws {
        let f = makeFixture()
        f.try tabManager.addTableTab(tableName: "users")
        let activeTabId = f.tabManager.tabs[0].id

        f.coordinator.setActiveTableRows(makeTableRows(rowCount: 3), for: activeTabId)

        #expect(f.fake.scrollToTopCount == 0)
    }

    @Test("setActiveTableRows is a no-op when delegate is unwired")
    func unwiredDelegateIsNoOp() throws {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            filterStateManager: FilterStateManager(),
            columnVisibilityManager: ColumnVisibilityManager(),
            toolbarState: ConnectionToolbarState()
        )
        try tabManager.addTableTab(tableName: "users")
        let tabId = tabManager.tabs[0].id

        coordinator.setActiveTableRows(makeTableRows(rowCount: 2), for: tabId)

        #expect(coordinator.tableRowsStore.tableRows(for: tabId).count == 2)
    }
}
