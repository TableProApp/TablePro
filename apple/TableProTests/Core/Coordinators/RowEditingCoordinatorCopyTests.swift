//
//  RowEditingCoordinatorCopyTests.swift
//  TableProTests
//

import AppKit
import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

extension GlobalStateSuites {
    @Suite(.recordingClipboard)
    @MainActor
    struct RowEditingCoordinatorCopyTests {
        private let fixture = CoordinatorFixture()

        private func makeCoordinator(tableRows: TableRows? = nil) -> MainContentCoordinator {
            var tab = QueryTab(title: "Q1", query: "SELECT id, name FROM users", tabType: .query)
            tab.execution.lastExecutedAt = Date()
            fixture.addTab(
                tab,
                rows: tableRows ?? TableRows.from(
                    queryRows: [
                        [.text("1"), .text("Alice")],
                        [.text("2"), .text("Bob")]
                    ],
                    columns: ["id", "name"],
                    columnTypes: [.text(rawType: nil), .text(rawType: nil)]
                )
            )
            return fixture.coordinator
        }

        private func selectedModel(_ coordinator: MainContentCoordinator) throws -> DataGridModel {
            let tabId = try #require(coordinator.tabManager.selectedTab?.id)
            return coordinator.gridModel(forTab: tabId)
        }

        // The value filter is the only thing that makes display order differ from storage order. No grid is
        // mounted, so this also covers the readers that run with none.
        private func applyNameFilter(_ names: Set<String>, to coordinator: MainContentCoordinator) throws {
            var state = GridValueFilterState()
            state.set(
                ColumnValueFilter(selectedValues: names, includesNull: false),
                columnName: "name",
                forColumn: 1
            )
            try selectedModel(coordinator).setValueFilter(state)
        }

        @Test("Copy as JSON copies the row the model selected under a value filter")
        func copyAsJsonFollowsTheFilteredSelection() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let coordinator = makeCoordinator()
            try applyNameFilter(["Bob"], to: coordinator)
            let model = try selectedModel(coordinator)

            model.setSelection(GridSelectionReducer.single(GridCoord(row: 0, displayColumn: 0)))
            coordinator.copyRowsAsJson(model.selectedRowIDs)

            #expect(model.selectedRowIDs == [.existing(1)])
            #expect(clipboard.text?.contains("Bob") == true)
            #expect(clipboard.text?.contains("Alice") != true)
        }

        @Test("the display order resolves with no grid mounted, which is what JSON mode reads")
        func displayOrderResolvesWithNoGridMounted() throws {
            let coordinator = makeCoordinator()
            try applyNameFilter(["Bob"], to: coordinator)
            let tabId = try #require(coordinator.tabManager.selectedTab?.id)

            #expect(try selectedModel(coordinator).isMounted == false)
            #expect(coordinator.displayIDs(forTab: tabId) == [.existing(1)])
        }

        @Test("replacing the rows wholesale drops the value filter")
        func newResultDropsTheValueFilter() throws {
            let coordinator = makeCoordinator()
            try applyNameFilter(["Bob"], to: coordinator)
            let tabId = try #require(coordinator.tabManager.selectedTab?.id)
            #expect(coordinator.displayIDs(forTab: tabId) != nil)

            coordinator.setActiveTableRows(
                TableRows.from(
                    queryRows: [[.text("3"), .text("Carol")]],
                    columns: ["id", "name"],
                    columnTypes: [.text(rawType: nil), .text(rawType: nil)]
                ),
                for: tabId
            )

            #expect(coordinator.displayIDs(forTab: tabId) == nil)
            #expect(try selectedModel(coordinator).displayedRowIDs == nil)
            #expect(coordinator.tabManager.selectedTab?.valueFilter.isActive == false)
        }

        // Fetch All extends the same result rather than replacing it, so the filter stays and the order is
        // resolved again over the rows that arrived.
        @Test("loading more rows into the same result keeps the value filter and re-resolves the order")
        func loadingMoreRowsKeepsTheValueFilter() throws {
            let coordinator = makeCoordinator()
            try applyNameFilter(["Bob"], to: coordinator)
            let model = try selectedModel(coordinator)
            #expect(model.displayedRowIDs == [.existing(1)])

            let tabId = try #require(coordinator.tabManager.selectedTab?.id)
            coordinator.mutateActiveTableRows(for: tabId) { rows in
                rows.replace(rows: [
                    [.text("1"), .text("Alice")],
                    [.text("2"), .text("Bob")],
                    [.text("3"), .text("Bob")]
                ])
            }

            #expect(coordinator.tabManager.selectedTab?.valueFilter.isActive == true)
            #expect(model.displayedRowIDs == [.existing(1), .existing(2)])
        }

        // The model reads the filter through its store, so a filter a new result cleared cannot come back
        // from a copy the grid kept.
        @Test("a new result with other columns leaves the model unfiltered")
        func newResultClearsTheFilterTheModelReads() throws {
            let coordinator = makeCoordinator()
            try applyNameFilter(["Bob"], to: coordinator)
            let model = try selectedModel(coordinator)
            #expect(model.store.valueFilter.isActive)
            let tabId = try #require(coordinator.tabManager.selectedTab?.id)

            coordinator.setActiveTableRows(
                TableRows.from(
                    queryRows: [[.text("9"), .text("Zoe")]],
                    columns: ["id", "nickname"],
                    columnTypes: [.text(rawType: nil), .text(rawType: nil)]
                ),
                for: tabId
            )

            #expect(coordinator.tabManager.selectedTab?.valueFilter.isActive == false)
            #expect(model.store.valueFilter.isActive == false)
            #expect(model.displayedRowIDs == nil)
            #expect(model.rowCount == 1)
        }

        @Test("Copy as JSON keeps storage order when no value filter applies")
        func copyAsJsonWithoutDisplayMapping() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let coordinator = makeCoordinator()

            coordinator.copyRowsAsJson([.existing(0)])

            #expect(clipboard.text?.contains("Alice") == true)
            #expect(clipboard.text?.contains("Bob") != true)
        }

        @Test("Copy as JSON skips rows the result does not hold")
        func copyAsJsonSkipsUnknownRows() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let coordinator = makeCoordinator()

            coordinator.copyRowsAsJson([.existing(1), .existing(99)])

            #expect(clipboard.text?.contains("Bob") == true)
            #expect(clipboard.text?.contains("Alice") != true)
        }

        @Test("Copy as JSON preserves wide integer values")
        func copyAsJsonPreservesWideInteger() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let value = "340282366920938463463374607431768211455"
            let tableRows = TableRows(
                rows: [Row(id: .existing(0), values: [.text(value)])],
                columns: ["value"],
                columnTypes: [.integer(rawType: "UINT128")]
            )
            let coordinator = makeCoordinator(tableRows: tableRows)

            coordinator.copyRowsAsJson([.existing(0)])

            #expect(clipboard.text?.contains("\"value\": \(value)") == true)
        }
    }
}
