//
//  GridSelectionOwnerTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("GridSelectionOwner")
struct GridSelectionOwnerTests {
    @Test("A table tab showing data owns a data selection")
    func tableTabWithDataMode() {
        #expect(GridSelectionOwner.resolve(tabType: .table, resultsViewMode: .data) == .dataGrid)
    }

    @Test("A table tab showing structure owns a schema selection")
    func tableTabWithStructureMode() {
        #expect(GridSelectionOwner.resolve(tabType: .table, resultsViewMode: .structure) == .schemaGrid)
    }

    @Test("JSON view still reads the data rows it renders")
    func tableTabWithJsonMode() {
        #expect(GridSelectionOwner.resolve(tabType: .table, resultsViewMode: .json) == .dataGrid)
    }

    @Test("Chart view does not inherit a stale grid selection")
    func chartModeHasNoSelectionOwner() {
        #expect(GridSelectionOwner.resolve(tabType: .table, resultsViewMode: .chart) == .none)
        #expect(GridSelectionOwner.resolve(tabType: .query, resultsViewMode: .chart) == .none)
    }

    /// Row editing follows the owner, so this is also the list of modes whose row commands stay
    /// live. JSON shows the same rows the data grid owns and keeps them; Chart has no rows to edit.
    @Test("Only a mode with an owning grid can edit rows")
    func rowEditingFollowsTheOwningGrid() {
        let owners = [ResultsViewMode.data, .structure, .json, .chart].map {
            GridSelectionOwner.resolve(tabType: .table, resultsViewMode: $0)
        }

        #expect(owners == [.dataGrid, .schemaGrid, .dataGrid, GridSelectionOwner.none])
    }

    @Test("A query tab's results are data rows")
    func queryTab() {
        #expect(GridSelectionOwner.resolve(tabType: .query, resultsViewMode: .data) == .dataGrid)
    }

    @Test("The new-table grid owns a schema selection whatever its results mode")
    func createTableTab() {
        #expect(GridSelectionOwner.resolve(tabType: .createTable, resultsViewMode: .data) == .schemaGrid)
        #expect(GridSelectionOwner.resolve(tabType: .createTable, resultsViewMode: .structure) == .schemaGrid)
    }

    @Test("Tabs with no row grid own no selection", arguments: [TabType.erDiagram, .serverDashboard, .usersRoles])
    func tabsWithoutRows(tabType: TabType) {
        #expect(GridSelectionOwner.resolve(tabType: tabType, resultsViewMode: .data) == .none)
    }

    @Test("No tab means nothing to inspect")
    func noTab() {
        #expect(GridSelectionOwner.resolve(tabType: nil, resultsViewMode: nil) == .none)
    }
}
