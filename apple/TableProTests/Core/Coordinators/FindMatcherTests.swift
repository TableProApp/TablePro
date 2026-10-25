//
//  FindMatcherTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct FindMatcherTests {
    @Test("binary column types are not searchable, everything else is")
    func searchableColumnTypes() {
        #expect(FindMatcher.isSearchable(.blob(rawType: "BLOB")) == false)
        #expect(FindMatcher.isSearchable(.spatial(rawType: "GEOMETRY")) == false)
        #expect(FindMatcher.isSearchable(.text(rawType: "VARCHAR")))
        #expect(FindMatcher.isSearchable(.integer(rawType: "INT")))
        #expect(FindMatcher.isSearchable(.timestamp(rawType: "TIMESTAMP")))
        #expect(FindMatcher.isSearchable(.json(rawType: "JSON")))
        #expect(FindMatcher.isSearchable(nil))
    }

    @Test("a binary column showing characters is searchable, one showing hex is not")
    func searchableBinaryFollowsItsDisplayFormat() {
        let blob = ColumnType.blob(rawType: "VARBINARY(255)")

        #expect(FindMatcher.isSearchable(blob, displayFormat: .text))
        #expect(FindMatcher.isSearchable(blob, displayFormat: .uuid))
        #expect(FindMatcher.isSearchable(blob, displayFormat: .raw) == false)
        #expect(FindMatcher.isSearchable(blob, displayFormat: nil) == false)
        #expect(FindMatcher.isSearchable(.spatial(rawType: "GEOMETRY"), displayFormat: .text) == false)
    }

    @Test("a server search sends only text columns unless the engine's patterns read every scalar column")
    func serverSearchableColumns() {
        let typed: [ColumnType] = [
            .integer(rawType: "INTEGER"), .decimal(rawType: "FLOAT"), .timestamp(rawType: "TIMESTAMP"),
            .boolean(rawType: "BOOLEAN")
        ]
        for type in typed {
            #expect(!FindMatcher.isServerSearchable(type))
            #expect(FindMatcher.isServerSearchable(type, patternReadsAnyColumn: true))
        }
        #expect(FindMatcher.isServerSearchable(.text(rawType: "ObjectId")))
        #expect(!FindMatcher.isServerSearchable(.json(rawType: "JSON"), patternReadsAnyColumn: true))
        #expect(!FindMatcher.isServerSearchable(.blob(rawType: "BLOB"), patternReadsAnyColumn: true))
        #expect(!FindMatcher.isServerSearchable(.spatial(rawType: "GEOMETRY"), patternReadsAnyColumn: true))
    }
}

// The Find menu reaches the selected tab's grid model; each tab's model keeps its own bar (#2667).
@MainActor
struct FindCoordinatorRoutingTests {
    private let fixtures = CoordinatorFixtures()

    private func makeTabs() -> (MainContentCoordinator, first: UUID, second: UUID) {
        let fixture = fixtures.make()
        let rows = TableRows.from(
            queryRows: [[.text("alice")], [.text("bob")], [.text("alina")]],
            columns: ["name"],
            columnTypes: [.text(rawType: nil)]
        )
        let first = QueryTab(title: "Album", query: "", tabType: .query)
        let second = QueryTab(title: "Artist", query: "", tabType: .query)
        fixture.addTab(first, rows: rows)
        fixture.addTab(second, rows: rows)
        fixture.tabManager.selectedTabId = first.id
        return (fixture.coordinator, first.id, second.id)
    }

    @Test("Find opens the bar on the selected tab's grid only")
    func findOpensTheSelectedTabsBar() {
        let (coordinator, first, second) = makeTabs()

        coordinator.findCoordinator.showFind()

        #expect(coordinator.gridModel(forTab: first).find.isVisible)
        #expect(!coordinator.gridModel(forTab: second).find.isVisible)
    }

    @Test("each tab keeps its own find term across a switch")
    func termStaysWithItsTab() {
        let (coordinator, first, second) = makeTabs()
        coordinator.findCoordinator.showFind()
        coordinator.activeGridModel?.find.term = "alice"
        coordinator.tabManager.selectedTabId = second
        coordinator.findCoordinator.showFind()
        coordinator.activeGridModel?.find.term = "berlin"

        coordinator.tabManager.selectedTabId = first

        #expect(coordinator.activeGridModel?.find.term == "alice")
        #expect(coordinator.gridModel(forTab: second).find.term == "berlin")
    }

    @Test("Find Next and Find Previous step the selected tab's matches")
    func stepsTheSelectedTabsMatches() throws {
        let (coordinator, first, _) = makeTabs()
        let model = coordinator.gridModel(forTab: first)
        coordinator.findCoordinator.showFind()
        model.find.term = "ali"
        model.findQueryDidChange()
        #expect(model.find.matches.count == 2)
        #expect(coordinator.findCoordinator.hasActiveFind)
        let start = try #require(model.find.currentIndex)

        coordinator.findCoordinator.findNext()
        #expect(model.find.currentIndex != start)

        coordinator.findCoordinator.findPrevious()
        #expect(model.find.currentIndex == start)
    }
}

// A table tab pages through `currentPage`; `hasMoreRows` is the query-tab truncation flag.
struct FindScopeFromPaginationTests {
    @Test("page 1 of a multi-page table has unloaded rows even though hasMoreRows is false")
    func firstPageOfManyIsPaged() {
        var state = PaginationState(pageSize: 1_000)
        state.totalRowCount = 12_000
        state.currentPage = 1
        #expect(state.hasMoreRows == false)
        #expect(state.hasUnloadedRows(loadedRowCount: 1_000))
    }

    @Test("the last page of a table has everything loaded")
    func lastPageIsComplete() {
        var state = PaginationState(pageSize: 1_000)
        state.totalRowCount = 1_500
        state.currentPage = 2
        #expect(state.hasUnloadedRows(loadedRowCount: 500) == false)
    }

    @Test("a table that fits on one page has everything loaded")
    func singlePageIsComplete() {
        var state = PaginationState(pageSize: 1_000)
        state.totalRowCount = 40
        state.currentPage = 1
        #expect(state.hasUnloadedRows(loadedRowCount: 40) == false)
    }

    @Test("an unknown row count with a full page is treated as paged, not as complete")
    func unknownCountWithFullPage() {
        var state = PaginationState(pageSize: 1_000)
        state.totalRowCount = nil
        state.currentPage = 1
        #expect(state.hasUnloadedRows(loadedRowCount: 1_000))
        #expect(state.hasUnloadedRows(loadedRowCount: 200) == false)
    }

    @Test("a truncated query result still counts as paged")
    func truncatedQueryResult() {
        var state = PaginationState(pageSize: 1_000)
        state.hasMoreRows = true
        #expect(state.hasUnloadedRows(loadedRowCount: 10))
    }
}

struct FindCounterTextTests {
    @Test("a paged result always names its scope")
    func pagedCounter() {
        let text = FindCounterText.text(matchCount: 12, currentIndex: 2, scope: .pageOfMore)
        #expect(text.contains("3"))
        #expect(text.contains("12"))
        #expect(text.lowercased().contains("page"))
    }

    @Test("a fully loaded result does not claim a page")
    func loadedCounter() {
        let text = FindCounterText.text(matchCount: 12, currentIndex: 2, scope: .allRowsLoaded)
        #expect(text.contains("3"))
        #expect(text.contains("12"))
        #expect(text.lowercased().contains("page") == false)
    }

    @Test("zero matches on a paged table never reads as an answer about the whole table")
    func pagedEmptyCounter() {
        let text = FindCounterText.text(matchCount: 0, currentIndex: nil, scope: .pageOfMore)
        #expect(text.lowercased().contains("page"))
        #expect(text == String(localized: "Not on this page"))
    }

    @Test("zero matches with everything loaded is a real answer")
    func loadedEmptyCounter() {
        let text = FindCounterText.text(matchCount: 0, currentIndex: nil, scope: .allRowsLoaded)
        #expect(text == String(localized: "No matches"))
    }
}
