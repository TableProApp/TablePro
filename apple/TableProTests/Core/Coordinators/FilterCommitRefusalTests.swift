//
//  FilterCommitRefusalTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@MainActor
struct FilterCommitRefusalTests {
    @Test("A filter the engine cannot build leaves the page, the query and the running filters as they were")
    func refusedFilterKeepsThePage() throws {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(type: .etcd),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        var tab = QueryTab(title: "(root)", query: "page three", tabType: .table, tableName: "(root)")
        tab.pagination.totalRowCount = 10_000
        tab.pagination.goToPage(3)
        tab.filterState.filters = [TestFixtures.makeTableFilter(column: "Value", op: .contains, value: "on")]
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        let pageThree = tab.pagination
        try #require(pageThree.currentPage == 3)

        coordinator.applyAllFilters()

        let refused = try #require(tabManager.tabs.first)
        #expect(refused.execution.errorMessage == String(localized: "This database cannot filter rows with these conditions."))
        #expect(refused.pagination.currentPage == pageThree.currentPage)
        #expect(refused.pagination.currentOffset == pageThree.currentOffset)
        #expect(refused.content.query == "page three")
        #expect(refused.filterState.executedFilters.isEmpty)
    }

    @Test("A raw condition the boundary check refuses is reported with its reason and never runs")
    func refusedRawConditionNamesTheReason() throws {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(type: .mysql),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        var tab = QueryTab(title: "users", query: "unfiltered", tabType: .table, tableName: "users")
        tab.filterState.filters = [TableFilter.rawCondition("status = 'a' -- temp")]
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id

        coordinator.applyAllFilters()

        let refused = try #require(tabManager.tabs.first)
        #expect(
            refused.execution.errorMessage
                == String(localized: "A raw SQL filter must be one condition: no comment, no second statement, and every quote and parenthesis closed.")
        )
        #expect(refused.content.query == "unfiltered")
        #expect(refused.filterState.executedFilters.isEmpty)
    }
}
