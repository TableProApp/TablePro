//
//  ResultStatusModelTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("ResultStatusModel")
struct ResultStatusModelTests {
    private func makeSnapshot(
        tabType: TabType? = .table,
        rowCount: Int = 0,
        displayRowCount: Int? = nil,
        isValueFiltered: Bool = false,
        hasColumns: Bool? = nil,
        hasTableName: Bool = true,
        hasStructureActions: Bool = false,
        pagination: PaginationState = PaginationState(),
        statusMessage: String? = nil
    ) -> StatusBarSnapshot {
        StatusBarSnapshot(
            tabId: UUID(),
            tabType: tabType,
            hasRows: rowCount > 0,
            hasColumns: hasColumns ?? (rowCount > 0),
            rowCount: rowCount,
            displayRowCount: displayRowCount,
            isValueFiltered: isValueFiltered,
            hasTableName: hasTableName,
            availableModes: ResultsModeAvailability.modes(
                tabType: tabType,
                hasTableName: hasTableName,
                hasColumns: hasColumns ?? (rowCount > 0)
            ),
            hasStructureActions: hasStructureActions,
            pagination: pagination,
            statusMessage: statusMessage
        )
    }

    private func model(
        _ snapshot: StatusBarSnapshot,
        viewMode: ResultsViewMode = .data,
        selected: Int = 0
    ) -> ResultStatusModel {
        ResultStatusModel(snapshot: snapshot, viewMode: viewMode, selectedRowCount: selected)
    }

    // MARK: - Readout

    @Test("An empty result still says so")
    func emptyResultReportsNoRows() {
        let snapshot = makeSnapshot(rowCount: 0, hasColumns: true)
        let result = model(snapshot)
        #expect(result.controls.showsReadout)
        #expect(result.readout == .noRows)
    }

    @Test("A tab with no result at all shows no readout")
    func unexecutedTabShowsNothing() {
        let snapshot = makeSnapshot(tabType: .query, rowCount: 0, hasColumns: false, hasTableName: false)
        let result = model(snapshot)
        #expect(!result.controls.showsReadout)
    }

    @Test("A table with a known total reports the offset range")
    func tableReportsRange() {
        let snapshot = makeSnapshot(
            rowCount: 1_000,
            pagination: PaginationState(totalRowCount: 5_000, pageSize: 1_000, currentPage: 3, currentOffset: 2_000)
        )
        #expect(model(snapshot).readout == .range(start: 2_001, end: 3_000, total: 5_000, isEstimate: false))
    }

    @Test("An estimated total is marked as one")
    func estimatedTotalIsMarked() {
        var pagination = PaginationState(totalRowCount: 5_000_000, pageSize: 1_000, currentPage: 1)
        pagination.isApproximateRowCount = true
        let snapshot = makeSnapshot(rowCount: 1_000, pagination: pagination)
        #expect(model(snapshot).readout == .range(start: 1, end: 1_000, total: 5_000_000, isEstimate: true))
    }

    @Test("The range stops at the rows the page actually returned")
    func rangeFollowsLoadedRows() {
        var pagination = PaginationState(totalRowCount: 1_000_000, pageSize: 1_000, currentPage: 1)
        pagination.isApproximateRowCount = true
        let snapshot = makeSnapshot(rowCount: 12, pagination: pagination)
        #expect(model(snapshot).readout == .range(start: 1, end: 12, total: 1_000_000, isEstimate: true))
    }

    @Test("A paged table with no total reports only the range it knows")
    func unknownTotalReportsRangeOnly() {
        let snapshot = makeSnapshot(
            rowCount: 50,
            pagination: PaginationState(totalRowCount: nil, pageSize: 50, currentPage: 2, currentOffset: 50)
        )
        #expect(model(snapshot).readout == .rangeOfUnknownTotal(start: 51, end: 100))
    }

    @Test("A truncated query result reports a partial load")
    func truncatedQueryReportsPartialLoad() {
        var pagination = PaginationState(pageSize: 1_000)
        pagination.hasMoreRows = true
        let snapshot = makeSnapshot(tabType: .query, rowCount: 1_000, pagination: pagination)
        let result = model(snapshot)
        #expect(result.readout == .partialLoad(1_000))
        #expect(result.controls.showsFetchAll)
    }

    // MARK: - Selection

    @Test("Selecting every displayed row says so")
    func allSelected() {
        let snapshot = makeSnapshot(rowCount: 5)
        #expect(model(snapshot, selected: 5).readout == .allSelected(5))
    }

    @Test("A partial selection counts against displayed rows")
    func partialSelection() {
        let snapshot = makeSnapshot(rowCount: 5)
        #expect(model(snapshot, selected: 2).readout == .selection(selected: 2, of: 5))
    }

    /// Selection indices are display positions, so a value filter makes the loaded buffer the wrong
    /// denominator: selecting all three visible rows of a hundred loaded used to read "3 of 100".
    @Test("A value filter is the denominator for a selection, not the loaded page")
    func selectionCountsDisplayedRows() {
        let snapshot = makeSnapshot(rowCount: 100, displayRowCount: 3, isValueFiltered: true)
        #expect(model(snapshot, selected: 3).readout == .allSelected(3))
        #expect(model(snapshot, selected: 1).readout == .selection(selected: 1, of: 3))
    }

    @Test("A value filter replaces the server-side range")
    func valueFilterReplacesRange() {
        let snapshot = makeSnapshot(
            rowCount: 100,
            displayRowCount: 3,
            isValueFiltered: true,
            pagination: PaginationState(totalRowCount: 1_000, pageSize: 100)
        )
        #expect(model(snapshot).readout == .valueFiltered(shown: 3, loaded: 100))
    }

    @Test("A mode with no grid reports no selection")
    func selectionIgnoredWithoutAGrid() {
        let snapshot = makeSnapshot(rowCount: 5)
        #expect(model(snapshot, viewMode: .chart, selected: 2).readout == .rowCount(5))
    }

    // MARK: - Controls

    @Test("Exact count is offered only while the total is not exact")
    func exactCountOfferedOnEstimate() {
        var pagination = PaginationState(totalRowCount: 900_000, pageSize: 1_000)
        pagination.isApproximateRowCount = true
        let onEstimate = model(makeSnapshot(rowCount: 1_000, pagination: pagination))
        #expect(onEstimate.controls.showsExactCountAction)
        #expect(!onEstimate.controls.showsCountInProgress)

        let exact = model(makeSnapshot(
            rowCount: 1_000,
            pagination: PaginationState(totalRowCount: 900_000, pageSize: 1_000)
        ))
        #expect(!exact.controls.showsExactCountAction)
    }

    @Test("A running count replaces its own button")
    func countInProgressReplacesButton() {
        var pagination = PaginationState(totalRowCount: 900_000, pageSize: 1_000)
        pagination.isApproximateRowCount = true
        pagination.isCountingExact = true
        let result = model(makeSnapshot(rowCount: 1_000, pagination: pagination))
        #expect(result.controls.showsCountInProgress)
        #expect(!result.controls.showsExactCountAction)
    }

    @Test("Grid controls follow the mode, and pagination outlives them")
    func controlsByMode() {
        let pagination = PaginationState(totalRowCount: 5_000, pageSize: 1_000)
        let snapshot = makeSnapshot(rowCount: 1_000, pagination: pagination)

        for mode in [ResultsViewMode.data, .json] {
            let result = model(snapshot, viewMode: mode)
            #expect(result.controls.showsColumns)
            #expect(result.controls.showsFilters)
            #expect(result.controls.showsPagination)
        }

        let chart = model(snapshot, viewMode: .chart)
        #expect(!chart.controls.showsColumns)
        #expect(!chart.controls.showsFilters)
        #expect(chart.controls.showsPagination, "a chart draws a page, so it needs the control that turns it")

        let structure = model(snapshot, viewMode: .structure)
        #expect(!structure.controls.showsReadout)
        #expect(!structure.controls.showsPagination)
    }

    @Test("A query tab never offers table-only controls")
    func queryTabHasNoTableControls() {
        var pagination = PaginationState(pageSize: 1_000)
        pagination.hasMoreRows = true
        let snapshot = makeSnapshot(tabType: .query, rowCount: 1_000, hasTableName: false, pagination: pagination)
        let result = model(snapshot)
        #expect(!result.controls.showsFilters)
        #expect(!result.controls.showsPagination)
        #expect(!result.controls.showsExactCountAction)
        #expect(result.controls.showsColumns)
    }

    /// The pair belongs to the structure list, so it appears only while that list is the content and
    /// only once the structure editor has said what it can do.
    @Test("The structure pair appears only in Structure mode, and only when published")
    func structureActionsFollowTheMode() {
        let published = makeSnapshot(rowCount: 9, hasStructureActions: true)
        #expect(model(published, viewMode: .structure).controls.showsStructureActions)
        #expect(!model(published, viewMode: .data).controls.showsStructureActions)

        let unpublished = makeSnapshot(rowCount: 9, hasStructureActions: false)
        #expect(!model(unpublished, viewMode: .structure).controls.showsStructureActions)
    }

    @Test("A status message rides with the readout")
    func statusMessageFollowsReadout() {
        let withReadout = model(makeSnapshot(rowCount: 5, statusMessage: "OK"))
        #expect(withReadout.statusMessage == "OK")

        let structure = model(makeSnapshot(rowCount: 5, statusMessage: "OK"), viewMode: .structure)
        #expect(structure.statusMessage == nil)
    }
}

@Suite("ResultsModeAvailability")
struct ResultsModeAvailabilityTests {
    @Test("A table tab offers every mode")
    func tableTabOffersAllModes() {
        let modes = ResultsModeAvailability.modes(tabType: .table, hasTableName: true, hasColumns: true)
        #expect(modes == [.data, .structure, .json, .chart])
    }

    @Test("A query result has no structure to show")
    func queryTabHasNoStructure() {
        let modes = ResultsModeAvailability.modes(tabType: .query, hasTableName: false, hasColumns: true)
        #expect(modes == [.data, .json, .chart])
    }

    @Test("A tab that has not produced columns offers nothing")
    func unexecutedQueryOffersNothing() {
        #expect(ResultsModeAvailability.modes(tabType: .query, hasTableName: false, hasColumns: false).isEmpty)
        #expect(ResultsModeAvailability.modes(tabType: nil, hasTableName: false, hasColumns: true).isEmpty)
    }

    @Test("Every mode has a name, and JSON keeps its own")
    func everyModeIsNamed() {
        for mode in [ResultsViewMode.data, .structure, .json, .chart] {
            #expect(!mode.displayName.isEmpty)
        }
        #expect(ResultsViewMode.json.displayName == "JSON")
    }
}
