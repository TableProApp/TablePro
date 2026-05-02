//
//  RowOperationsDispatchTests.swift
//  TableProTests
//
//  Locks the dispatch wiring from RowOperations into TableViewCoordinating.
//  These tests guard the path that PR #938 (Phase D-b) accidentally severed:
//  invalidateCachesForUndoRedo must fire on soft-delete (existing rows) so the
//  red row background and yellow modified marker propagate to NSTableView's
//  visible cell views without requiring a tab switch or scroll-recycle.
//

import Foundation
@testable import TablePro
import Testing

@MainActor
private final class FakeTableViewCoordinator: TableViewCoordinating {
    var fullReplaceCount = 0
    var insertedCount = 0
    var removedCount = 0
    var deltaCount = 0
    var invalidateCount = 0
    var commitEditCount = 0
    var refreshFKCount = 0
    var scrollToTopCount = 0
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
    func refreshForeignKeyColumns() { refreshFKCount += 1 }
    func scrollToTop() { scrollToTopCount += 1 }
}

@Suite("RowOperations dispatch")
@MainActor
struct RowOperationsDispatchTests {
    private struct Fixture {
        let coordinator: MainContentCoordinator
        let tabManager: QueryTabManager
        let delegate: DataTabGridDelegate
        let fake: FakeTableViewCoordinator
        let tabId: UUID
    }

    private func makeFixture(rowCount: Int = 5) -> Fixture {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        let delegate = DataTabGridDelegate()
        let fake = FakeTableViewCoordinator()
        delegate.tableViewCoordinator = fake
        coordinator.dataTabDelegate = delegate

        try tabManager.addTableTab(tableName: "users")
        let tabIndex = tabManager.selectedTabIndex ?? 0
        tabManager.tabs[tabIndex].tableContext.isEditable = true
        let tabId = tabManager.tabs[tabIndex].id

        let columns = ["id", "name"]
        let rows = (0..<rowCount).map { i in ["\(i)", "name\(i)"] }
        let columnTypes: [ColumnType] = Array(repeating: .text(rawType: nil), count: columns.count)
        coordinator.setActiveTableRows(
            TableRows.from(queryRows: rows, columns: columns, columnTypes: columnTypes),
            for: tabId
        )

        return Fixture(
            coordinator: coordinator,
            tabManager: tabManager,
            delegate: delegate,
            fake: fake,
            tabId: tabId
        )
    }

    @Test("Soft-delete of existing rows dispatches invalidateCachesForUndoRedo")
    func softDeleteDispatchesInvalidate() {
        let f = makeFixture(rowCount: 5)
        let beforeInvalidate = f.fake.invalidateCount

        f.coordinator.deleteSelectedRows(indices: [0, 1])

        #expect(f.fake.invalidateCount == beforeInvalidate + 1)
        #expect(f.fake.deltaCount == 0)
    }

    @Test("Physical delete of inserted rows dispatches applyDelta, not invalidate")
    func physicalDeleteDispatchesDelta() {
        let f = makeFixture(rowCount: 3)
        f.coordinator.addNewRow()
        let insertedIndex = f.coordinator.tabSessionRegistry.tableRows(for: f.tabId).count - 1
        let beforeInvalidate = f.fake.invalidateCount
        let beforeDelta = f.fake.deltaCount

        f.coordinator.deleteSelectedRows(indices: [insertedIndex])

        #expect(f.fake.invalidateCount == beforeInvalidate)
        #expect(f.fake.deltaCount == beforeDelta + 1)
    }
}
