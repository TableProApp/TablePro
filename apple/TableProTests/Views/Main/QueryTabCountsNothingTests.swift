//
//  QueryTabCountsNothingTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import Testing

@MainActor
struct QueryTabCountsNothingTests {
    private let fixtures = CoordinatorFixtures()

    private func launch(
        on fixture: CoordinatorFixture,
        tabType: TabType,
        needsMetadataFetch: Bool
    ) -> UUID {
        let tab = QueryTab(title: "users", query: "SELECT * FROM users WHERE id = 7", tabType: tabType, tableName: "users")
        fixture.addTab(tab)
        let claim = fixture.coordinator.tabExecution.claim(tab.id)
        _ = fixture.coordinator.tabExecution.settle(claim)
        fixture.coordinator.launchPhase2AfterApply(
            tableName: "users",
            isEditable: true,
            isTableTab: tabType == .table,
            tabId: tab.id,
            trigger: .userInitiated,
            needsMetadataFetch: needsMetadataFetch,
            schemaTask: nil,
            claim: claim
        )
        return tab.id
    }

    @Test("An editable result on a query tab starts no count, with or without cached metadata", arguments: [false, true])
    func queryTabStartsNoCount(needsMetadataFetch: Bool) {
        let fixture = fixtures.make()
        let tabId = launch(on: fixture, tabType: .query, needsMetadataFetch: needsMetadataFetch)

        #expect(fixture.coordinator.rowCountTasks[tabId] == nil)
        #expect(fixture.tabManager.tabs.first { $0.id == tabId }?.pagination.isCountPending == false)
        fixture.coordinator.cancelAllPhase2Work()
    }

    @Test("A table tab still counts its rows")
    func tableTabCounts() {
        let fixture = fixtures.make()
        let tabId = launch(on: fixture, tabType: .table, needsMetadataFetch: false)

        #expect(fixture.coordinator.rowCountTasks[tabId] != nil)
        fixture.coordinator.cancelAllRowCountTasks()
    }

    @Test("Paging commands leave a query tab's SQL and pagination as they were")
    func pagingLeavesQueryTabAlone() {
        let fixture = fixtures.make()
        var tab = QueryTab(title: "Query", query: "SELECT * FROM users WHERE id = 7", tabType: .query, tableName: "users")
        tab.pagination = PaginationState(totalRowCount: 2_000, pageSize: 1_000)
        fixture.addTab(tab)
        let pagination = fixture.coordinator.paginationCoordinator!

        pagination.goToNextPage()
        pagination.goToLastPage()
        pagination.goToPage(2)
        pagination.updatePageSize(50)

        let after = fixture.tabManager.tabs.first { $0.id == tab.id }
        #expect(after?.content.query == "SELECT * FROM users WHERE id = 7")
        #expect(after?.pagination == tab.pagination)
        #expect(after?.paginationVersion == tab.paginationVersion)
    }

    @Test("The paging menu items are off on a query tab and on for a table tab")
    func pagingMenuFollowsTheTabType() {
        let fixture = fixtures.make()
        let actions = MainContentCommandActions(
            coordinator: fixture.coordinator,
            connection: fixture.connection,
            selectedTables: .constant([]),
            pendingTruncates: .constant([]),
            pendingDeletes: .constant([]),
            tableOperationOptions: .constant([:]),
            trailingPaneState: TrailingPaneState()
        )

        fixture.addTab(QueryTab(title: "Query", query: "SELECT * FROM users", tabType: .query))
        #expect(!actions.canNavigatePages)

        fixture.addTab(QueryTab(title: "users", query: "SELECT * FROM users", tabType: .table, tableName: "users"))
        #expect(actions.canNavigatePages)
    }
}
