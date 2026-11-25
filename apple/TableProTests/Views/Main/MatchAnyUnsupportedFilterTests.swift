//
//  MatchAnyUnsupportedFilterTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

// A restored Match Any on an engine without OR becomes Match All at the first build, so rows, count and cell filters agree.
@MainActor
struct MatchAnyUnsupportedFilterTests {
    private func makeTableCoordinator(type: DatabaseType) -> (MainContentCoordinator, QueryTabManager, Int) {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(type: type),
            tabManager: tabManager,
            toolbarState: ConnectionToolbarState()
        )
        var tab = QueryTab(title: "events", query: "SELECT * FROM events", tabType: .table)
        tab.tableContext.tableName = "events"
        tab.filterState = .applying([
            TableFilter(columnName: "a", filterOperator: .equal, value: "1"),
            TableFilter(columnName: "b", filterOperator: .equal, value: "2")
        ], logicMode: .or)
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
        #expect(tabManager.tabs[index].filterState.applied?.logicMode != .or)
        #expect(!tabManager.tabs[index].content.query.contains(" OR "))
    }

    @Test("An engine with OR keeps Match Any")
    func matchAnySurvivesWhereSupported() {
        let (coordinator, tabManager, index) = makeTableCoordinator(type: .postgresql)

        coordinator.rebuildTableQuery(at: index)

        #expect(tabManager.tabs[index].filterState.filterLogicMode == .or)
        #expect(tabManager.tabs[index].filterState.applied?.logicMode == .or)
        #expect(tabManager.tabs[index].content.query.contains(" OR "))
    }
}
