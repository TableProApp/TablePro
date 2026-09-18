//
//  MainContentCoordinatorSelectionResetTests.swift
//  TableProTests
//
//  A row selection is a set of display positions into the result that produced it. Replacing
//  the rows wholesale, by running a query or switching result set, has to drop it: consumers
//  that keep reading it, the JSON results view and the row inspector, would otherwise resolve
//  positions that belong to rows the user never selected.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("MainContentCoordinator selection reset")
@MainActor
struct MainContentCoordinatorSelectionResetTests {
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

    @Test("a new result clears the live selection of the active tab")
    func newResultClearsLiveSelection() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addQueryTab(to: tabManager)
        coordinator.setActiveTableRows(makeRows(5), for: tabId)
        coordinator.selectionState.indices = [1, 3]

        coordinator.setActiveTableRows(makeRows(5), for: tabId)

        #expect(coordinator.selectionState.indices.isEmpty)
    }

    @Test("a new result clears the tab's persisted selection")
    func newResultClearsPersistedSelection() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addQueryTab(to: tabManager)
        tabManager.mutate(tabId: tabId) { $0.selectedRowIndices = [0, 2] }

        coordinator.setActiveTableRows(makeRows(3), for: tabId)

        let tab = try #require(tabManager.tabs.first { $0.id == tabId })
        #expect(tab.selectedRowIndices.isEmpty)
    }

    @Test("a result for a background tab leaves the active tab's live selection alone")
    func backgroundTabResultKeepsActiveSelection() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let backgroundTabId = addQueryTab(to: tabManager, select: false)
        let activeTabId = addQueryTab(to: tabManager)
        tabManager.mutate(tabId: backgroundTabId) { $0.selectedRowIndices = [4] }
        coordinator.setActiveTableRows(makeRows(5), for: activeTabId)
        coordinator.selectionState.indices = [2]

        coordinator.setActiveTableRows(makeRows(5), for: backgroundTabId)

        #expect(coordinator.selectionState.indices == [2])
        let background = try #require(tabManager.tabs.first { $0.id == backgroundTabId })
        #expect(background.selectedRowIndices.isEmpty)
    }

    @Test("an incremental row edit keeps the selection")
    func incrementalEditKeepsSelection() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addQueryTab(to: tabManager)
        coordinator.setActiveTableRows(makeRows(4), for: tabId)
        coordinator.selectionState.indices = [1]

        coordinator.mutateActiveTableRows(for: tabId) { rows in
            rows.rows[1].values[0] = .text("edited")
            return .none
        }

        #expect(coordinator.selectionState.indices == [1])
    }
}
