//
//  SortCacheInvalidationTests.swift
//  TableProTests
//
//  Locks the contract that row mutations invalidate querySortCache for the
//  affected tab. Pre-merge, only the coordinator-side cache was invalidated;
//  the view-side @State sortCache stayed stale, so a sorted small table
//  returned out-of-date sortedIDs after add / undo / paste / delete. After
//  the merge there is one cache and these tests guard the invalidation set.
//

import Foundation
@testable import TablePro
import Testing

@Suite("querySortCache invalidation on row mutations")
@MainActor
struct SortCacheInvalidationTests {
    private func makeCoordinator() throws -> (MainContentCoordinator, QueryTabManager, UUID) {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        try tabManager.addTableTab(tableName: "users")
        let tabIndex = tabManager.selectedTabIndex ?? 0
        tabManager.tabs[tabIndex].tableContext.isEditable = true
        let tabId = tabManager.tabs[tabIndex].id
        return (coordinator, tabManager, tabId)
    }

    private func seedCache(_ coordinator: MainContentCoordinator, for tabId: UUID) {
        coordinator.querySortCache[tabId] = QuerySortCacheEntry(
            sortedIDs: [.existing(0), .existing(1), .existing(2)],
            columnIndex: 1,
            direction: .ascending,
            schemaVersion: 0
        )
    }

    private func seedRows(_ coordinator: MainContentCoordinator, for tabId: UUID, count: Int) {
        let columns = ["id", "name"]
        let rows = (0..<count).map { i in ["\(i)", "name\(i)"] }
        let columnTypes: [ColumnType] = Array(repeating: .text(rawType: nil), count: columns.count)
        let tableRows = TableRows.from(queryRows: rows, columns: columns, columnTypes: columnTypes)
        coordinator.setActiveTableRows(tableRows, for: tabId)
    }

    @Test("addNewRow clears querySortCache for the tab")
    func addNewRowInvalidatesCache() throws {
        let (coordinator, _, tabId) = try makeCoordinator()
        seedRows(coordinator, for: tabId, count: 3)
        seedCache(coordinator, for: tabId)

        coordinator.addNewRow()

        #expect(coordinator.querySortCache[tabId] == nil)
    }

    @Test("deleteSelectedRows clears querySortCache when physically removing inserted rows")
    func physicalDeleteInvalidatesCache() throws {
        let (coordinator, _, tabId) = try makeCoordinator()
        seedRows(coordinator, for: tabId, count: 3)
        coordinator.addNewRow()
        let insertedIndex = coordinator.tabSessionRegistry.tableRows(for: tabId).count - 1
        seedCache(coordinator, for: tabId)

        coordinator.deleteSelectedRows(indices: [insertedIndex])

        #expect(coordinator.querySortCache[tabId] == nil)
    }

    @Test("deleteSelectedRows preserves querySortCache on soft delete of existing rows")
    func softDeletePreservesCache() throws {
        let (coordinator, _, tabId) = try makeCoordinator()
        seedRows(coordinator, for: tabId, count: 5)
        seedCache(coordinator, for: tabId)

        coordinator.deleteSelectedRows(indices: [0, 1])

        #expect(coordinator.querySortCache[tabId] != nil)
    }

    @Test("duplicateSelectedRow clears querySortCache for the tab")
    func duplicateRowInvalidatesCache() throws {
        let (coordinator, _, tabId) = try makeCoordinator()
        seedRows(coordinator, for: tabId, count: 3)
        seedCache(coordinator, for: tabId)

        coordinator.duplicateSelectedRow(index: 0)

        #expect(coordinator.querySortCache[tabId] == nil)
    }
}
