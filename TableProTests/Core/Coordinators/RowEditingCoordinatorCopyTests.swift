//
//  RowEditingCoordinatorCopyTests.swift
//  TableProTests
//

import Foundation
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class RowEditingCopyClipboard: ClipboardProvider {
    var text: String?
    var hasGridRowsValue = false

    func readText() -> String? { text }
    func readGridRows() -> GridRowsClipboardPayload? { nil }
    func writeText(_ text: String) { self.text = text; hasGridRowsValue = false }
    func writeCsv(_ csv: String) { text = csv; hasGridRowsValue = false }
    func writeRows(tsv: String, html: String?, gridRows: GridRowsClipboardPayload) { text = tsv; hasGridRowsValue = true }
    var hasText: Bool { text != nil }
    var hasGridRows: Bool { hasGridRowsValue }
}

@MainActor
private final class RowEditingCopyLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@Suite("RowEditingCoordinator copy as JSON")
@MainActor
struct RowEditingCoordinatorCopyTests {
    private func makeCoordinator() -> MainContentCoordinator {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        var tab = QueryTab(title: "Q1", query: "SELECT id, name FROM users", tabType: .query)
        tab.execution.lastExecutedAt = Date()
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id

        let tableRows = TableRows.from(
            queryRows: [
                [.text("1"), .text("Alice")],
                [.text("2"), .text("Bob")]
            ],
            columns: ["id", "name"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil)]
        )
        coordinator.setActiveTableRows(tableRows, for: tab.id)
        return coordinator
    }

    private func attachGrid(
        to coordinator: MainContentCoordinator,
        sortedIDs: [RowID]?
    ) -> (DataTabGridDelegate, TableViewCoordinator) {
        let delegate = DataTabGridDelegate()
        let tableViewCoordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: delegate,
            layoutPersister: RowEditingCopyLayoutPersister()
        )
        tableViewCoordinator.sortedIDs = sortedIDs
        delegate.dataGridAttach(tableViewCoordinator: tableViewCoordinator)
        coordinator.dataTabDelegate = delegate
        return (delegate, tableViewCoordinator)
    }

    @Test("Copy as JSON resolves display positions through the sorted order")
    func copyAsJsonResolvesDisplayOrder() {
        let clipboard = RowEditingCopyClipboard()
        ClipboardService.shared = clipboard
        defer { ClipboardService.shared = NSPasteboardClipboardProvider() }

        let coordinator = makeCoordinator()
        let attached = attachGrid(to: coordinator, sortedIDs: [.existing(1), .existing(0)])

        coordinator.copySelectedRowsAsJson(indices: [0])

        #expect(clipboard.text?.contains("Bob") == true)
        #expect(clipboard.text?.contains("Alice") != true)
        withExtendedLifetime(attached) {}
    }

    @Test("Copy as JSON keeps storage order when no display mapping exists")
    func copyAsJsonWithoutDisplayMapping() {
        let clipboard = RowEditingCopyClipboard()
        ClipboardService.shared = clipboard
        defer { ClipboardService.shared = NSPasteboardClipboardProvider() }

        let coordinator = makeCoordinator()

        coordinator.copySelectedRowsAsJson(indices: [0])

        #expect(clipboard.text?.contains("Alice") == true)
        #expect(clipboard.text?.contains("Bob") != true)
    }

    @Test("Copy as JSON skips display positions past the current rows")
    func copyAsJsonSkipsOutOfRangeIndices() {
        let clipboard = RowEditingCopyClipboard()
        ClipboardService.shared = clipboard
        defer { ClipboardService.shared = NSPasteboardClipboardProvider() }

        let coordinator = makeCoordinator()

        coordinator.copySelectedRowsAsJson(indices: [1, 99])

        #expect(clipboard.text?.contains("Bob") == true)
    }
}
