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
    private func makeCoordinator(tableRows: TableRows? = nil) -> MainContentCoordinator {
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

        coordinator.setActiveTableRows(
            tableRows ?? TableRows.from(
                queryRows: [
                    [.text("1"), .text("Alice")],
                    [.text("2"), .text("Bob")]
                ],
                columns: ["id", "name"],
                columnTypes: [.text(rawType: nil), .text(rawType: nil)]
            ),
            for: tab.id
        )
        return coordinator
    }

    /// Narrows the tab to the rows whose `name` is one of `names`, which is what a value filter
    /// does and the only thing in the shipping app that makes display order differ from storage
    /// order. No grid is attached, so this also covers the readers that run with none.
    private func applyNameFilter(_ names: Set<String>, to coordinator: MainContentCoordinator) {
        guard let tabId = coordinator.tabManager.selectedTab?.id else { return }
        var state = GridValueFilterState()
        state.set(
            ColumnValueFilter(selectedValues: names, includesNull: false),
            columnName: "name",
            forColumn: 1
        )
        coordinator.setValueFilter(state, forTab: tabId)
    }

    @Test("Copy as JSON resolves display positions through the value-filtered order")
    func copyAsJsonResolvesDisplayOrder() {
        let clipboard = RowEditingCopyClipboard()
        ClipboardService.shared = clipboard
        defer { ClipboardService.shared = NSPasteboardClipboardProvider() }

        let coordinator = makeCoordinator()
        applyNameFilter(["Bob"], to: coordinator)

        coordinator.copySelectedRowsAsJson(indices: [0])

        #expect(clipboard.text?.contains("Bob") == true)
        #expect(clipboard.text?.contains("Alice") != true)
    }

    @Test("the display order survives with no grid mounted, which is what JSON mode reads")
    func displayOrderResolvesWithNoGridAttached() {
        let coordinator = makeCoordinator()
        applyNameFilter(["Bob"], to: coordinator)

        #expect(coordinator.dataTabDelegate == nil)
        #expect(coordinator.activeGridDisplayIDs == [.existing(1)])
    }

    @Test("replacing the rows wholesale drops the value filter")
    func newResultDropsTheValueFilter() {
        let coordinator = makeCoordinator()
        applyNameFilter(["Bob"], to: coordinator)
        #expect(coordinator.activeGridDisplayIDs != nil)

        guard let tabId = coordinator.tabManager.selectedTab?.id else {
            Issue.record("no selected tab")
            return
        }
        coordinator.setActiveTableRows(
            TableRows.from(
                queryRows: [[.text("3"), .text("Carol")]],
                columns: ["id", "name"],
                columnTypes: [.text(rawType: nil), .text(rawType: nil)]
            ),
            for: tabId
        )

        #expect(coordinator.activeGridDisplayIDs == nil)
        #expect(coordinator.tabManager.selectedTab?.valueFilter.isActive == false)
    }

    /// Fetch All extends the same result rather than replacing it, so the filter stays and the
    /// order is re-resolved over the rows that arrived. The memo keys on the registry's data
    /// revision, so this holds with no grid mounted to recompute it.
    @Test("loading more rows into the same result keeps the value filter and re-resolves the order")
    func loadingMoreRowsKeepsTheValueFilter() {
        let coordinator = makeCoordinator()
        applyNameFilter(["Bob"], to: coordinator)
        #expect(coordinator.activeGridDisplayIDs == [.existing(1)])

        guard let tabId = coordinator.tabManager.selectedTab?.id else {
            Issue.record("no selected tab")
            return
        }
        coordinator.mutateActiveTableRows(for: tabId) { rows in
            rows.replace(rows: [
                [.text("1"), .text("Alice")],
                [.text("2"), .text("Bob")],
                [.text("3"), .text("Bob")]
            ])
        }

        #expect(coordinator.tabManager.selectedTab?.valueFilter.isActive == true)
        #expect(coordinator.activeGridDisplayIDs == [.existing(1), .existing(2)])
    }

    /// The clear runs one line before `setActiveTableRows` drives the grid's full reload, and the
    /// grid keeps its own mirror of the filter. Left un-adopted, the reload resolved the new rows
    /// through the old filter and pruning it against the new columns wrote it back onto the tab.
    @Test("a mounted grid does not resurrect the value filter a new result cleared")
    func newResultClearsTheFilterOnTheMountedGridToo() {
        let coordinator = makeCoordinator()
        let delegate = DataTabGridDelegate()
        let grid = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: delegate,
            layoutPersister: RowEditingCopyLayoutPersister()
        )
        delegate.dataGridAttach(tableViewCoordinator: grid)
        coordinator.dataTabDelegate = delegate

        guard let tabId = coordinator.tabManager.selectedTab?.id else {
            Issue.record("no selected tab")
            return
        }
        grid.tableRowsProvider = { [weak coordinator] in
            coordinator?.tabSessionRegistry.tableRows(for: tabId) ?? TableRows()
        }
        grid.valueFilterBinding = Binding(
            get: { coordinator.tabManager.selectedTab?.valueFilter ?? GridValueFilterState() },
            set: { coordinator.setValueFilter($0, forTab: tabId) }
        )
        applyNameFilter(["Bob"], to: coordinator)
        grid.adoptValueFilter(coordinator.tabManager.selectedTab?.valueFilter ?? GridValueFilterState())
        #expect(grid.valueFilterState.isActive)

        coordinator.setActiveTableRows(
            TableRows.from(
                queryRows: [[.text("9"), .text("Zoe")]],
                columns: ["id", "nickname"],
                columnTypes: [.text(rawType: nil), .text(rawType: nil)]
            ),
            for: tabId
        )

        #expect(coordinator.tabManager.selectedTab?.valueFilter.isActive == false)
        #expect(grid.valueFilterState.isActive == false)
        #expect(coordinator.activeGridDisplayIDs == nil)
        withExtendedLifetime((delegate, grid)) {}
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

    @Test("Copy as JSON preserves wide integer values")
    func copyAsJsonPreservesWideInteger() {
        let clipboard = RowEditingCopyClipboard()
        ClipboardService.shared = clipboard
        defer { ClipboardService.shared = NSPasteboardClipboardProvider() }
        let value = "340282366920938463463374607431768211455"
        let tableRows = TableRows(
            rows: [Row(id: .existing(0), values: [.text(value)])],
            columns: ["value"],
            columnTypes: [.integer(rawType: "UINT128")]
        )
        let coordinator = makeCoordinator(tableRows: tableRows)

        coordinator.copySelectedRowsAsJson(indices: [0])

        #expect(clipboard.text?.contains("\"value\": \(value)") == true)
    }
}
