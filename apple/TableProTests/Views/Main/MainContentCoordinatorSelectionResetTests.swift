//
//  MainContentCoordinatorSelectionResetTests.swift
//  TableProTests
//
//  Row ids are positional per page, so a selection means nothing once its rows are replaced
//  wholesale. The JSON view and the inspector would otherwise read rows the user never selected.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct MainContentCoordinatorSelectionResetTests {
    private let fixtures = CoordinatorFixtures()

    private func makeCoordinator() -> (MainContentCoordinator, QueryTabManager) {
        let fixture = fixtures.make()
        let tabManager = fixture.tabManager
        let coordinator = fixture.coordinator
        return (coordinator, tabManager)
    }

    @discardableResult
    private func addQueryTab(to tabManager: QueryTabManager, select: Bool = true) -> UUID {
        var tab = QueryTab(title: "Query", query: "SELECT 1", tabType: .query)
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

    private func snapshot(rows: [Int]) -> GridSelectionSnapshot {
        GridSelectionSnapshot(rowIDs: rows.map { RowID.existing($0) }, rectangles: [], activeCell: nil, anchor: nil)
    }

    @Test("a new result clears the active tab's model selection")
    func newResultClearsLiveSelection() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addQueryTab(to: tabManager)
        coordinator.setActiveTableRows(makeRows(5), for: tabId)
        let model = coordinator.gridModel(forTab: tabId)
        model.selectRows([.existing(1), .existing(3)])

        coordinator.setActiveTableRows(makeRows(5), for: tabId)

        #expect(model.selection.isEmpty)
        #expect(model.store.selectionSnapshot.isEmpty)
    }

    @Test("a new result clears the selection the tab carries")
    func newResultClearsPersistedSelection() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addQueryTab(to: tabManager)
        tabManager.mutate(tabId: tabId) { $0.selectionSnapshot = snapshot(rows: [0, 2]) }

        coordinator.setActiveTableRows(makeRows(3), for: tabId)

        let tab = try #require(tabManager.tabs.first { $0.id == tabId })
        #expect(tab.selectionSnapshot.isEmpty)
    }

    @Test("a result for a background tab clears that tab's selection and leaves the active tab's alone")
    func backgroundTabResultKeepsActiveSelection() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let backgroundTabId = addQueryTab(to: tabManager, select: false)
        let activeTabId = addQueryTab(to: tabManager)
        coordinator.setActiveTableRows(makeRows(5), for: backgroundTabId)
        coordinator.setActiveTableRows(makeRows(5), for: activeTabId)
        let background = coordinator.gridModel(forTab: backgroundTabId)
        background.selectRows([.existing(4)])
        let active = coordinator.gridModel(forTab: activeTabId)
        active.selectRows([.existing(2)])

        coordinator.setActiveTableRows(makeRows(5), for: backgroundTabId)

        #expect(active.selectedRowIDs == [.existing(2)])
        #expect(background.selection.isEmpty)
    }

    @Test("an incremental row edit keeps the selection")
    func incrementalEditKeepsSelection() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addQueryTab(to: tabManager)
        coordinator.setActiveTableRows(makeRows(4), for: tabId)
        let model = coordinator.gridModel(forTab: tabId)
        model.selectRows([.existing(1)])

        coordinator.mutateActiveTableRows(for: tabId) { rows in
            rows.edit(row: 1, column: 0, value: .text("edited"))
        }

        #expect(model.selectedRowIDs == [.existing(1)])
    }
}
