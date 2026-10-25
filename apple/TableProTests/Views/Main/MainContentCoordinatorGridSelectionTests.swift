//
//  MainContentCoordinatorGridSelectionTests.swift
//  TableProTests
//
//  A tab's grid selection lives on the tab's model, which outlives every mount of its grid, so a
//  tab switch or a result-mode switch never loses it (#2667).
//

import AppKit
import Foundation
import SwiftUI
import TableProPluginKit
import TableProTestSupport
import Testing

@testable import TablePro

@MainActor
struct MainContentCoordinatorGridSelectionTests {
    private let fixtures = CoordinatorFixtures()

    private func makeCoordinator() -> (MainContentCoordinator, QueryTabManager) {
        let fixture = fixtures.make()
        return (fixture.coordinator, fixture.tabManager)
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
                Row(id: .existing(index), values: [.text("row\(index)"), .text("value\(index)")])
            }
        )
        return TableRows(rows: rows, columns: ["name", "value"], columnTypes: [.text(rawType: nil), .text(rawType: nil)])
    }

    private func block(rows: ClosedRange<Int>, columns: ClosedRange<Int>) -> GridSelection {
        GridSelection(
            rectangles: [GridRect(rows: rows, columns: columns)],
            activeCell: GridCoord(row: rows.upperBound, displayColumn: columns.upperBound),
            anchor: GridCoord(row: rows.lowerBound, displayColumn: columns.lowerBound)
        )
    }

    private func switchTab(_ coordinator: MainContentCoordinator, from old: UUID, to new: UUID) {
        coordinator.tabManager.selectedTabId = new
        coordinator.handleTabChange(from: old, to: new, tabs: coordinator.tabManager.tabs)
    }

    // MARK: - Across a switch

    @Test("switching back finds the row selection the tab was left with")
    func switchingBackKeepsRows() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabA = addQueryTab(to: tabManager, title: "A")
        let tabB = addQueryTab(to: tabManager, title: "B")
        coordinator.setActiveTableRows(makeRows(20), for: tabA)
        coordinator.setActiveTableRows(makeRows(20), for: tabB)
        coordinator.gridModel(forTab: tabA).selectRows([.existing(4), .existing(6)])

        switchTab(coordinator, from: tabB, to: tabA)

        #expect(coordinator.activeGridModel?.selectedRowIDs == [.existing(4), .existing(6)])
    }

    // A cell drag selects a block of cells, and restoring it as whole rows would make Copy copy whole rows.
    @Test("switching back finds the cell rectangle, not only its rows")
    func switchingBackKeepsTheCellRectangle() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabA = addQueryTab(to: tabManager, title: "A")
        let tabB = addQueryTab(to: tabManager, title: "B")
        coordinator.setActiveTableRows(makeRows(20), for: tabA)
        coordinator.setActiveTableRows(makeRows(20), for: tabB)
        switchTab(coordinator, from: tabB, to: tabA)
        coordinator.gridModel(forTab: tabA).setSelection(block(rows: 2...5, columns: 1...1))

        switchTab(coordinator, from: tabA, to: tabB)
        switchTab(coordinator, from: tabB, to: tabA)

        let selection = coordinator.activeGridModel?.selection
        #expect(selection?.rectangles == [GridRect(rows: 2...5, columns: 1...1)])
        #expect(selection?.affectedRows == IndexSet(integersIn: 2...5))
    }

    @Test("two tabs keep their own selections across a round trip")
    func twoTabsKeepTheirOwnSelections() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabA = addQueryTab(to: tabManager, title: "A")
        let tabB = addQueryTab(to: tabManager, title: "B")
        coordinator.setActiveTableRows(makeRows(20), for: tabA)
        coordinator.setActiveTableRows(makeRows(20), for: tabB)
        coordinator.gridModel(forTab: tabA).selectRows([.existing(1)])
        coordinator.gridModel(forTab: tabB).selectRows([.existing(9)])

        switchTab(coordinator, from: tabB, to: tabA)
        #expect(coordinator.activeGridModel?.selectedRowIDs == [.existing(1)])

        switchTab(coordinator, from: tabA, to: tabB)
        #expect(coordinator.activeGridModel?.selectedRowIDs == [.existing(9)])
    }

    @Test("a result-mode switch keeps the selection the grid had")
    func resultModeSwitchKeepsTheSelection() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addQueryTab(to: tabManager, title: "A")
        coordinator.setActiveTableRows(makeRows(5), for: tabId)
        coordinator.gridModel(forTab: tabId).selectRows([.existing(3)])

        tabManager.mutate(tabId: tabId) { $0.display.resultsViewMode = .json }
        #expect(coordinator.activeGridModel?.selectedRowIDs == [.existing(3)])
        tabManager.mutate(tabId: tabId) { $0.display.resultsViewMode = .data }

        #expect(coordinator.activeGridModel?.selectedRowIDs == [.existing(3)])
    }

    @Test("the active grid model is the data tab's in Data, JSON and Map, and nobody's in Chart")
    func activeGridModelFollowsTheResultMode() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addQueryTab(to: tabManager, title: "A")
        coordinator.setActiveTableRows(makeRows(3), for: tabId)
        let model = coordinator.gridModel(forTab: tabId)

        for mode in [ResultsViewMode.data, .json, .map] {
            tabManager.mutate(tabId: tabId) { $0.display.resultsViewMode = mode }
            #expect(coordinator.activeGridModel === model, "\(mode)")
        }
        tabManager.mutate(tabId: tabId) { $0.display.resultsViewMode = .chart }
        #expect(coordinator.activeGridModel == nil)
    }

    // MARK: - Watching from outside the grid

    private final class WatchedChanges {
        var appeared = false
        var rowsChanged: [Bool] = []
    }

    private func settle(_ window: NSWindow, until condition: () -> Bool) async throws {
        try await waitUntil {
            window.contentView?.layoutSubtreeIfNeeded()
            return condition()
        }
    }

    // The window reopens the inspector only when other rows are picked, so a closed one stays closed under arrow keys.
    @Test("the selection watcher tells a move of the cursor within the selected row from picking another row")
    func watcherReportsWhetherTheSelectedRowsChanged() async throws {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addQueryTab(to: tabManager, title: "A")
        coordinator.setActiveTableRows(makeRows(5), for: tabId)
        let model = coordinator.gridModel(forTab: tabId)
        let changes = WatchedChanges()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 40, height: 40),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: GridSelectionWatcher(
            model: model,
            onAttach: { changes.appeared = true },
            onChange: { changes.rowsChanged.append($0) }
        ))
        defer { window.orderOut(nil) }
        try await settle(window) { changes.appeared }

        model.selectCell(GridCoord(row: 1, displayColumn: 0))
        try await settle(window) { changes.rowsChanged.count == 1 }
        model.selectCell(GridCoord(row: 1, displayColumn: 1))
        try await settle(window) { changes.rowsChanged.count == 2 }
        model.selectCell(GridCoord(row: 2, displayColumn: 1))
        try await settle(window) { changes.rowsChanged.count == 3 }

        #expect(changes.rowsChanged == [true, false, true])
    }

    // MARK: - Invalidation

    // Row ids are positional per page, so a selection means nothing against rows replaced wholesale.
    @Test("a new result clears the model's selection and its stored snapshot")
    func newResultClearsTheSelection() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addQueryTab(to: tabManager, title: "A")
        coordinator.setActiveTableRows(makeRows(5), for: tabId)
        let model = coordinator.gridModel(forTab: tabId)
        model.setSelection(block(rows: 1...3, columns: 0...1))

        coordinator.setActiveTableRows(makeRows(5), for: tabId)

        #expect(model.selection.isEmpty)
        #expect(model.store.selectionSnapshot.isEmpty)
    }

    @Test("retargeting a tab to another table clears the selection it carries")
    func retargetClearsStoredSelection() throws {
        let (_, tabManager) = makeCoordinator()
        let tabId = addQueryTab(to: tabManager, title: "A")
        tabManager.mutate(tabId: tabId) {
            $0.selectionSnapshot = GridSelectionSnapshot(rowIDs: [.existing(2)], rectangles: [], activeCell: nil, anchor: nil)
        }

        try tabManager.replaceTabContent(tableName: "orders")

        let tab = try #require(tabManager.tabs.first { $0.id == tabId })
        #expect(tab.selectionSnapshot.isEmpty)
    }

    // MARK: - Moving a tab to another window

    @Test("a tab enriched for another window carries its model's selection")
    func enrichedTabCarriesTheSelection() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addQueryTab(to: tabManager, title: "A")
        coordinator.setActiveTableRows(makeRows(5), for: tabId)
        coordinator.gridModel(forTab: tabId).setSelection(block(rows: 0...2, columns: 0...1))
        let tab = try #require(tabManager.tabs.first { $0.id == tabId })

        let enriched = coordinator.enrichedForPersistence(tab)

        #expect(enriched.selectionSnapshot.rowIDs == [.existing(0), .existing(1), .existing(2)])
        #expect(enriched.selectionSnapshot.rectangles.count == 1)
    }

    @Test("a background tab is enriched from its own model, not the selected tab's")
    func enrichedBackgroundTabUsesItsOwnModel() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let background = addQueryTab(to: tabManager, title: "A", select: false)
        let selected = addQueryTab(to: tabManager, title: "B")
        coordinator.setActiveTableRows(makeRows(10), for: background)
        coordinator.setActiveTableRows(makeRows(10), for: selected)
        coordinator.gridModel(forTab: background).selectRows([.existing(7)])
        coordinator.gridModel(forTab: selected).selectRows([.existing(1)])
        let tab = try #require(tabManager.tabs.first { $0.id == background })

        let enriched = coordinator.enrichedForPersistence(tab)

        #expect(enriched.selectionSnapshot.rowIDs == [.existing(7)])
    }

    // The model's store starts from the selection a tab carried in from another window.
    @Test("a model created for a tab starts from the selection the tab carries")
    func modelStartsFromTheCarriedSelection() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addQueryTab(to: tabManager, title: "A")
        coordinator.setActiveTableRows(makeRows(5), for: tabId)
        tabManager.mutate(tabId: tabId) {
            $0.selectionSnapshot = GridSelectionSnapshot(
                rowIDs: [.existing(2), .existing(3)],
                rectangles: [],
                activeCell: nil,
                anchor: nil
            )
        }

        let model = coordinator.gridModel(forTab: tabId)

        #expect(model.selectedRowIDs == [.existing(2), .existing(3)])
    }
}
