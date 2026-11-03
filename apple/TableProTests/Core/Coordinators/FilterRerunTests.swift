//
//  FilterRerunTests.swift
//  TableProTests
//
//  A page turn, sort or refresh rebuilds the table's query. It reruns the filters the rows on
//  screen were fetched with: a row edited after Apply, or switched between a raw condition and a
//  column with its text kept, is the panel's draft and runs only once Apply runs it.
//

import Foundation
import Testing

@testable import TablePro

@MainActor
struct FilterRerunTests {
    private func makeTableCoordinator(
        _ filters: [TableFilter],
        type: DatabaseType = .postgresql
    ) -> (MainContentCoordinator, QueryTabManager) {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(type: type),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        var tab = QueryTab(title: "users", query: "SELECT * FROM users", tabType: .table)
        tab.tableContext.tableName = "users"
        tab.filterState.filters = filters
        tab.filterState.commit = .all
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        return (coordinator, tabManager)
    }

    @Test("A rebuild reruns what ran, not a row edited after Apply")
    func rebuildIgnoresUnappliedEdit() {
        let (coordinator, tabManager) = makeTableCoordinator([TableFilter(columnName: "name", value: "bob")])
        coordinator.rebuildTableQuery(at: 0)
        #expect(tabManager.tabs[0].content.query.contains("'bob'"))

        tabManager.mutate(at: 0) {
            $0.filterState.filters[0] = $0.filterState.filters[0].selectingRawCondition()
        }
        coordinator.rebuildTableQuery(at: 0)

        let query = tabManager.tabs[0].content.query
        #expect(query.contains("'bob'"))
        #expect(!query.contains("(bob)"), "the switched row has not been applied")
    }

    @Test("A rebuild keeps the logic the filters ran with, not one changed in the panel since")
    func rebuildKeepsRunningLogicMode() {
        let (coordinator, tabManager) = makeTableCoordinator([
            TableFilter(columnName: "a", value: "1"),
            TableFilter(columnName: "b", value: "2"),
        ])
        coordinator.rebuildTableQuery(at: 0)
        #expect(tabManager.tabs[0].content.query.contains(" AND "))

        tabManager.mutate(at: 0) { $0.filterState.filterLogicMode = .or }
        coordinator.rebuildTableQuery(at: 0)

        #expect(tabManager.tabs[0].content.query.contains(" AND "))
        #expect(!tabManager.tabs[0].content.query.contains(" OR "))
    }

    @Test("Restored filters a rebuild cannot build stop counting as applied")
    func rebuildDropsRefusedCommit() {
        let (coordinator, tabManager) = makeTableCoordinator([
            TableFilter.rawCondition("status = 'a' -- temp"),
        ])

        coordinator.rebuildTableQuery(at: 0)

        let tab = tabManager.tabs[0]
        #expect(tab.filterState.commit == nil)
        #expect(tab.filterState.executedFilters.isEmpty)
        #expect(!tab.content.query.contains("temp"))
        #expect(tab.filterState.filters.count == 1, "the row stays in the panel for the reader to fix")
    }
}
