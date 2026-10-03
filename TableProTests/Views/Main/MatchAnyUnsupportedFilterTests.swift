//
//  MatchAnyUnsupportedFilterTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

/// Cassandra has no `OR`, so its filter bar offers no Match Any. A logic restored from before that, from a
/// saved filter set or a persisted tab, is written back as Match All the first time the table's query is
/// built, so the rows, Count Exactly and the cell filters all read the same thing.
@MainActor
struct MatchAnyUnsupportedFilterTests {
    private func makeTableCoordinator(type: DatabaseType) -> (MainContentCoordinator, QueryTabManager, Int) {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(type: type),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        var tab = QueryTab(title: "events", query: "SELECT * FROM events", tabType: .table)
        tab.tableContext.tableName = "events"
        tab.filterState.filters = [
            TableFilter(columnName: "a", filterOperator: .equal, value: "1"),
            TableFilter(columnName: "b", filterOperator: .equal, value: "2")
        ]
        tab.filterState.commit = .all
        tab.filterState.filterLogicMode = .or
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        return (coordinator, tabManager, tabManager.tabs.count - 1)
    }

    @Test("A restored Match Any becomes Match All on an engine without it", arguments: [
        DatabaseType.cassandra, .scylladb
    ])
    func restoredMatchAnyBecomesMatchAll(type: DatabaseType) {
        let (coordinator, tabManager, index) = makeTableCoordinator(type: type)

        coordinator.rebuildTableQuery(at: index)

        #expect(tabManager.tabs[index].filterState.filterLogicMode == .and)
        #expect(!tabManager.tabs[index].content.query.contains(" OR "))
    }

    @Test("An engine with OR keeps Match Any")
    func matchAnySurvivesWhereSupported() {
        let (coordinator, tabManager, index) = makeTableCoordinator(type: .postgresql)

        coordinator.rebuildTableQuery(at: index)

        #expect(tabManager.tabs[index].filterState.filterLogicMode == .or)
        #expect(tabManager.tabs[index].content.query.contains(" OR "))
    }
}
