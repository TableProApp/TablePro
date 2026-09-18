//
//  MainContentCoordinatorGridSelectionTests.swift
//  TableProTests
//
//  A tab's grid selection has to survive the grid being destroyed, which happens on every tab
//  switch and on every result-mode switch. `handleTabChange` always restored it; nothing ever
//  captured it, so the restore replayed an empty set over the reader's selection. (#2667)
//

import AppKit
import Foundation
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class StubColumnLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@Suite("MainContentCoordinator grid selection capture and restore")
@MainActor
struct MainContentCoordinatorGridSelectionTests {
    private func makeCoordinator() -> (MainContentCoordinator, QueryTabManager) {
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
    private func addQueryTab(to tabManager: QueryTabManager, title: String, select: Bool = true) -> UUID {
        var tab = QueryTab(title: title, query: "SELECT 1", tabType: .query)
        tab.execution.lastExecutedAt = Date()
        tabManager.tabs.append(tab)
        if select {
            tabManager.selectedTabId = tab.id
        }
        return tab.id
    }

    private func makeRows(_ count: Int) -> TableRows {
        let rows = ContiguousArray(
            (0..<count).map { index in
                Row(id: .existing(index), values: [.text("row\(index)")])
            }
        )
        return TableRows(rows: rows, columns: ["name"], columnTypes: [.text(rawType: nil)])
    }

    private func block(rows: ClosedRange<Int>, columns: ClosedRange<Int>) -> GridSelection {
        GridSelection(
            rectangles: [GridRect(rows: rows, columns: columns)],
            activeCell: GridCoord(row: rows.upperBound, displayColumn: columns.upperBound),
            anchor: GridCoord(row: rows.lowerBound, displayColumn: columns.lowerBound)
        )
    }

    // MARK: - Capture

    @Test("a grid's teardown keeps its row selection on the tab")
    func teardownKeepsRowSelection() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addQueryTab(to: tabManager, title: "A")

        coordinator.storeGridSelection(rows: [3, 5, 7], cells: .empty, forTab: tabId)

        let tab = try #require(tabManager.tabs.first { $0.id == tabId })
        #expect(tab.selectedRowIndices == [3, 5, 7])
        #expect(tab.cellSelection.isEmpty)
    }

    @Test("a grid's teardown keeps its cell rectangle on the tab")
    func teardownKeepsCellSelection() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addQueryTab(to: tabManager, title: "A")
        let cells = block(rows: 1...4, columns: 2...3)

        coordinator.storeGridSelection(rows: [1], cells: cells, forTab: tabId)

        let tab = try #require(tabManager.tabs.first { $0.id == tabId })
        #expect(tab.cellSelection == cells)
    }

    /// The capture is keyed by the tab the grid was built for, not by whichever tab is selected when
    /// the teardown happens to run. SwiftUI does not order a teardown against the switch that caused
    /// it, so reading the selected tab here would sometimes write the wrong one.
    @Test("the capture writes the tab it names, not the selected one")
    func captureWritesTheNamedTab() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let outgoing = addQueryTab(to: tabManager, title: "A", select: false)
        let incoming = addQueryTab(to: tabManager, title: "B")

        coordinator.storeGridSelection(rows: [8], cells: .empty, forTab: outgoing)

        let outgoingTab = try #require(tabManager.tabs.first { $0.id == outgoing })
        let incomingTab = try #require(tabManager.tabs.first { $0.id == incoming })
        #expect(outgoingTab.selectedRowIndices == [8])
        #expect(incomingTab.selectedRowIndices.isEmpty)
    }

    /// The teardown capture is only believable while its tab is still the selected one. On a tab
    /// switch the shared selection channel is repointed at the incoming tab while the outgoing grid
    /// is still bound to it, so the outgoing table view is cleared before its teardown runs and the
    /// capture would store emptiness over what `handleTabChange` just saved (measured).
    @Test("a teardown after the tab was deselected does not overwrite the saved selection")
    func teardownAfterDeselectionDoesNotClobber() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let tabA = addQueryTab(to: tabManager, title: "A")
        let tabB = addQueryTab(to: tabManager, title: "B")
        coordinator.storeGridSelection(rows: [4, 6], cells: .empty, forTab: tabA)
        tabManager.selectedTabId = tabB

        coordinator.storeGridSelectionOnTeardown(rows: [], cells: .empty, forTab: tabA)

        let tab = try #require(tabManager.tabs.first { $0.id == tabA })
        #expect(tab.selectedRowIndices == [4, 6])
    }

    /// A result-mode switch destroys the grid without changing tabs, and there the table view still
    /// holds what the reader selected, so the teardown capture is the one that must land.
    @Test("a teardown while the tab is still selected is written through")
    func teardownWhileSelectedIsWritten() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addQueryTab(to: tabManager, title: "A")

        coordinator.storeGridSelectionOnTeardown(rows: [2, 3], cells: .empty, forTab: tabId)

        let tab = try #require(tabManager.tabs.first { $0.id == tabId })
        #expect(tab.selectedRowIndices == [2, 3])
    }

    /// The switch itself is what captures the outgoing tab, because by the time that tab's grid is
    /// torn down its table view has already been cleared through the shared channel.
    @Test("switching away captures the outgoing tab's live grid selection")
    func switchingAwayCapturesTheOutgoingSelection() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let tabA = addQueryTab(to: tabManager, title: "A")
        let tabB = addQueryTab(to: tabManager, title: "B")
        coordinator.setActiveTableRows(makeRows(20), for: tabA)
        coordinator.setActiveTableRows(makeRows(20), for: tabB)
        tabManager.selectedTabId = tabA

        let tableView = NSTableView()
        let delegate = DataTabGridDelegate()
        let gridCoordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: StubColumnLayoutPersister()
        )
        gridCoordinator.tableView = tableView
        delegate.dataGridAttach(tableViewCoordinator: gridCoordinator)
        coordinator.dataTabDelegate = delegate
        gridCoordinator.selectionController.update(block(rows: 5...8, columns: 0...1))

        tabManager.selectedTabId = tabB
        coordinator.handleTabChange(from: tabA, to: tabB, tabs: tabManager.tabs)

        let stored = try #require(tabManager.tabs.first { $0.id == tabA })
        #expect(stored.cellSelection.rectangles == [GridRect(rows: 5...8, columns: 0...1)])
        #expect(stored.selectedDisplayRows == [5, 6, 7, 8])
    }

    // MARK: - Restore

    @Test("switching back restores the row selection the tab was left with")
    func switchingBackRestoresRows() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabA = addQueryTab(to: tabManager, title: "A")
        let tabB = addQueryTab(to: tabManager, title: "B")
        coordinator.setActiveTableRows(makeRows(20), for: tabA)
        coordinator.setActiveTableRows(makeRows(20), for: tabB)

        coordinator.storeGridSelection(rows: [4, 6], cells: .empty, forTab: tabA)
        coordinator.handleTabChange(from: tabA, to: tabB, tabs: tabManager.tabs)
        #expect(coordinator.selectionState.indices.isEmpty)

        coordinator.handleTabChange(from: tabB, to: tabA, tabs: tabManager.tabs)

        #expect(coordinator.selectionState.indices == [4, 6])
    }

    /// A cell drag pins the table view's row selection to its anchor row, so restoring from the
    /// stored rows alone would shrink the reader's block to that one row.
    @Test("switching back restores every row a cell rectangle covers")
    func switchingBackRestoresCellRectangleRows() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabA = addQueryTab(to: tabManager, title: "A")
        let tabB = addQueryTab(to: tabManager, title: "B")
        coordinator.setActiveTableRows(makeRows(20), for: tabA)
        coordinator.setActiveTableRows(makeRows(20), for: tabB)

        coordinator.storeGridSelection(rows: [2], cells: block(rows: 2...5, columns: 0...1), forTab: tabA)
        coordinator.handleTabChange(from: tabA, to: tabB, tabs: tabManager.tabs)
        coordinator.handleTabChange(from: tabB, to: tabA, tabs: tabManager.tabs)

        #expect(coordinator.selectionState.indices == [2, 3, 4, 5])
    }

    @Test("two tabs keep their own selections across a round trip")
    func twoTabsKeepTheirOwnSelections() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let tabA = addQueryTab(to: tabManager, title: "A")
        let tabB = addQueryTab(to: tabManager, title: "B")
        coordinator.setActiveTableRows(makeRows(20), for: tabA)
        coordinator.setActiveTableRows(makeRows(20), for: tabB)

        coordinator.storeGridSelection(rows: [1], cells: .empty, forTab: tabA)
        coordinator.storeGridSelection(rows: [9], cells: .empty, forTab: tabB)

        coordinator.handleTabChange(from: tabA, to: tabB, tabs: tabManager.tabs)
        #expect(coordinator.selectionState.indices == [9])

        coordinator.handleTabChange(from: tabB, to: tabA, tabs: tabManager.tabs)
        #expect(coordinator.selectionState.indices == [1])

        let stored = try #require(tabManager.tabs.first { $0.id == tabB })
        #expect(stored.selectedRowIndices == [9])
    }

    // MARK: - Invalidation

    /// Display positions mean nothing against rows that were replaced wholesale, so both halves of
    /// the stored selection go, not just the rows.
    @Test("a new result clears the tab's stored cell rectangle too")
    func newResultClearsStoredCellSelection() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addQueryTab(to: tabManager, title: "A")
        coordinator.storeGridSelection(rows: [1], cells: block(rows: 1...3, columns: 0...2), forTab: tabId)

        coordinator.setActiveTableRows(makeRows(5), for: tabId)

        let tab = try #require(tabManager.tabs.first { $0.id == tabId })
        #expect(tab.selectedRowIndices.isEmpty)
        #expect(tab.cellSelection.isEmpty)
    }

    @Test("retargeting a tab to another table clears its stored selection")
    func retargetClearsStoredSelection() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addQueryTab(to: tabManager, title: "A")
        coordinator.storeGridSelection(rows: [2], cells: block(rows: 2...2, columns: 0...0), forTab: tabId)

        try tabManager.replaceTabContent(tableName: "orders")

        let tab = try #require(tabManager.tabs.first { $0.id == tabId })
        #expect(tab.selectedRowIndices.isEmpty)
        #expect(tab.cellSelection.isEmpty)
    }

    /// `selectedDisplayRows` gives a stored rectangle precedence, so a later row-only writer has to
    /// clear it or the rectangle comes back instead of the rows that writer chose.
    @Test("a stored cell rectangle does not outrank rows a paste selected")
    func pasteSupersedesAStoredCellRectangle() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addQueryTab(to: tabManager, title: "A")
        coordinator.storeGridSelection(rows: [1], cells: block(rows: 1...4, columns: 0...1), forTab: tabId)

        tabManager.mutate(tabId: tabId) { tab in
            tab.selectedRowIndices = [9]
            tab.cellSelection = .empty
        }

        let tab = try #require(tabManager.tabs.first { $0.id == tabId })
        #expect(tab.selectedDisplayRows == [9])
    }

    // MARK: - Moving a tab to another window

    /// A tab handed to another window is snapshotted while its grid is still mounted, so the
    /// teardown capture has not run and the tab's own copy is still the one from the last switch.
    @Test("a tab enriched for another window carries the live grid selection")
    func enrichedTabCarriesLiveSelection() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addQueryTab(to: tabManager, title: "A")
        let tab = tabManager.tabs[0]

        let tableView = NSTableView()
        let delegate = DataTabGridDelegate()
        let gridCoordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: StubColumnLayoutPersister()
        )
        gridCoordinator.tableView = tableView
        delegate.dataGridAttach(tableViewCoordinator: gridCoordinator)
        coordinator.dataTabDelegate = delegate
        gridCoordinator.selectionController.update(block(rows: 0...2, columns: 0...1))

        let enriched = coordinator.enrichedForPersistence(tab)

        #expect(enriched.cellSelection.rectangles == [GridRect(rows: 0...2, columns: 0...1)])
        #expect(enriched.selectedDisplayRows == [0, 1, 2])
        #expect(tabId == enriched.id)
    }

    @Test("a background tab is enriched from its own stored selection, not the mounted grid's")
    func enrichedBackgroundTabIgnoresMountedGrid() {
        let (coordinator, tabManager) = makeCoordinator()
        let background = addQueryTab(to: tabManager, title: "A", select: false)
        addQueryTab(to: tabManager, title: "B")
        coordinator.storeGridSelection(rows: [7], cells: .empty, forTab: background)

        let tableView = NSTableView()
        let delegate = DataTabGridDelegate()
        let gridCoordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: StubColumnLayoutPersister()
        )
        gridCoordinator.tableView = tableView
        delegate.dataGridAttach(tableViewCoordinator: gridCoordinator)
        coordinator.dataTabDelegate = delegate

        guard let tab = tabManager.tabs.first(where: { $0.id == background }) else {
            Issue.record("Expected the background tab to exist")
            return
        }
        let enriched = coordinator.enrichedForPersistence(tab)

        #expect(enriched.selectedRowIndices == [7])
    }
}
