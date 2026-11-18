//
//  EditorTabDetachLoadTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct EditorTabDetachLoadTests {
    private func tableTab() -> QueryTab {
        QueryTab(title: "genre", query: "SELECT * FROM genre", tabType: .table, tableName: "genre")
    }

    private func queryTab() -> QueryTab {
        QueryTab(title: "Query", query: "SELECT 1", tabType: .query)
    }

    private func loadedTableTab(in fixture: CoordinatorFixture, pagination: (inout PaginationState) -> Void) -> QueryTab {
        var tab = tableTab()
        tab.execution.lastExecutedAt = Date()
        pagination(&tab.pagination)
        return fixture.addTab(tab, rows: TestFixtures.makeTableRows())
    }

    @Test("A table on its first load can move")
    func firstLoadCanMove() {
        let fixture = CoordinatorFixture()
        let tab = fixture.addTab(tableTab())

        _ = fixture.coordinator.tabExecution.claim(tab.id)

        #expect(!fixture.coordinator.holdsWorkThatCannotMove(tab))
    }

    @Test("A table waiting only on its automatic row count can move")
    func automaticCountCanMove() {
        let fixture = CoordinatorFixture()
        let tab = loadedTableTab(in: fixture) { $0.isCountPending = true }

        #expect(!fixture.coordinator.holdsWorkThatCannotMove(tab))
    }

    @Test("A table reloading the rows it shows stays")
    func reloadStays() {
        let fixture = CoordinatorFixture()
        let tab = loadedTableTab(in: fixture) { $0.isCountPending = true }

        _ = fixture.coordinator.tabExecution.claim(tab.id)

        #expect(fixture.coordinator.holdsWorkThatCannotMove(tab))
    }

    @Test("A count the user asked for stays")
    func exactCountStays() {
        let fixture = CoordinatorFixture()
        let tab = loadedTableTab(in: fixture) { $0.isCountingExact = true }

        #expect(fixture.coordinator.holdsWorkThatCannotMove(tab))
    }

    @Test("A table loading more rows stays")
    func loadMoreStays() {
        let fixture = CoordinatorFixture()
        let tab = loadedTableTab(in: fixture) { $0.isLoadingMore = true }

        #expect(fixture.coordinator.holdsWorkThatCannotMove(tab))
    }

    @Test("A running query stays")
    func runningQueryStays() {
        let fixture = CoordinatorFixture()
        let tab = fixture.addTab(queryTab())

        _ = fixture.coordinator.tabExecution.claim(tab.id)

        #expect(fixture.coordinator.holdsWorkThatCannotMove(tab))
    }

    @Test("An idle tab holds nothing back")
    func idleTabCanMove() {
        let fixture = CoordinatorFixture()
        let tab = fixture.addTab(queryTab())

        #expect(!fixture.coordinator.holdsWorkThatCannotMove(tab))
    }

    @Test("A count the user started on a table that never loaded stays")
    func exactCountOnAnUnloadedTableStays() {
        let fixture = CoordinatorFixture()
        var tab = tableTab()
        tab.pagination.isCountingExact = true
        fixture.addTab(tab)

        #expect(fixture.coordinator.holdsWorkThatCannotMove(tab))
    }

    @Test("Abandoning a first load frees the tab and discards the late result")
    func abandonedFirstLoadFreesTheTab() throws {
        let fixture = CoordinatorFixture()
        let tab = fixture.addTab(tableTab())
        let claim = fixture.coordinator.tabExecution.claim(tab.id)
        fixture.tabManager.mutate(tabId: tab.id) { $0.pagination.isLoading = true }

        let rowsLanded = fixture.coordinator.abandonAutomaticTableReads(of: tab.id)

        #expect(!rowsLanded)
        #expect(!fixture.coordinator.tabExecution.isBusy(tab.id))
        let moved = try #require(fixture.tabManager.tabs.first { $0.id == tab.id })
        #expect(!moved.pagination.isBusy)
        #expect(fixture.coordinator.canAutoLoadTableTab(moved))
        let applied = fixture.coordinator.tabExecution.settle(claim)
        #expect(!applied)
    }

    @Test("A table moved before its keys and count arrive keeps its rows and asks for the rest")
    func abandonedPhaseTwoKeepsTheRows() throws {
        let fixture = CoordinatorFixture()
        let tab = loadedTableTab(in: fixture) { $0.isCountPending = true }

        let rowsLanded = fixture.coordinator.abandonAutomaticTableReads(of: tab.id)

        #expect(rowsLanded)
        let moved = try #require(fixture.tabManager.tabs.first { $0.id == tab.id })
        #expect(!moved.pagination.isBusy)
        #expect(!fixture.coordinator.canAutoLoadTableTab(moved))
        #expect(fixture.coordinator.tabSessionRegistry.tableRows(for: tab.id).rows.count == 3)
    }

    @Test("The destination marks the total pending while it fetches the keys and count")
    func resumeMarksTheCountPending() throws {
        let fixture = CoordinatorFixture()
        let tab = loadedTableTab(in: fixture) { _ in }

        fixture.coordinator.resumeTableMetadataAndCount(of: tab)

        let resumed = try #require(fixture.tabManager.tabs.first { $0.id == tab.id })
        #expect(resumed.pagination.isCountPending)
    }

    @Test("A settled table has nothing to give up")
    func settledTableGivesUpNothing() {
        let fixture = CoordinatorFixture()
        let tab = loadedTableTab(in: fixture) { _ in }

        let rowsLanded = fixture.coordinator.abandonAutomaticTableReads(of: tab.id)

        #expect(!rowsLanded)
    }

    @Test("A reload is never abandoned")
    func abandonLeavesAReloadRunning() {
        let fixture = CoordinatorFixture()
        let tab = loadedTableTab(in: fixture) { $0.isCountPending = true }
        let claim = fixture.coordinator.tabExecution.claim(tab.id)

        let rowsLanded = fixture.coordinator.abandonAutomaticTableReads(of: tab.id)

        #expect(!rowsLanded)
        #expect(fixture.coordinator.tabExecution.isCurrent(claim))
    }

    @Test("A running query is never abandoned")
    func abandonLeavesAQueryRunning() {
        let fixture = CoordinatorFixture()
        let tab = fixture.addTab(queryTab())
        let claim = fixture.coordinator.tabExecution.claim(tab.id)

        let rowsLanded = fixture.coordinator.abandonAutomaticTableReads(of: tab.id)

        #expect(!rowsLanded)
        #expect(fixture.coordinator.tabExecution.isCurrent(claim))
    }
}
