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

    // MARK: - Stability across a reload

    /// The instants one sidebar click on another table passes through, in order.
    ///
    /// Retargeting empties the tab's row buffer and nulls its total synchronously, before the
    /// replacing fetch starts, so every one of these is a state the bar can actually be asked to
    /// render. They are listed here as data because the defect was never one bad state: it was that
    /// consecutive states disagreed about which controls exist.
    private func makeReloadTimeline() -> [(name: String, snapshot: StatusBarSnapshot)] {
        var loading = PaginationState(pageSize: 1_000)
        loading.isLoading = true

        var counting = PaginationState(pageSize: 1_000)
        counting.isCountPending = true

        var estimated = PaginationState(totalRowCount: 4_000_000, pageSize: 1_000)
        estimated.isApproximateRowCount = true

        var timeline: [(name: String, snapshot: StatusBarSnapshot)] = []
        timeline.append((
            "settled on the outgoing table",
            makeSnapshot(rowCount: 1_000, pagination: PaginationState(totalRowCount: 5_000, pageSize: 1_000))
        ))
        timeline.append((
            "buffer cleared, load not yet claimed",
            makeSnapshot(rowCount: 0, hasColumns: false, pagination: loading)
        ))
        timeline.append((
            "rows landed, no total yet",
            makeSnapshot(rowCount: 1_000, pagination: counting)
        ))
        timeline.append((
            "estimated total posted",
            makeSnapshot(rowCount: 1_000, pagination: estimated)
        ))
        timeline.append((
            "exact total posted",
            makeSnapshot(rowCount: 1_000, pagination: PaginationState(totalRowCount: 3_812_004, pageSize: 1_000))
        ))
        return timeline
    }

    /// Everything that frames the bar. The exact-count affordance is deliberately absent: it is
    /// meant to appear exactly once, at the end, and only when the total settles on an estimate,
    /// which `exactCountAppearsOnceAtTheEndOfAReload` pins separately.
    private func framingControls(_ controls: ResultStatusControls) -> [Bool] {
        [
            controls.showsModeSwitcher,
            controls.showsReadout,
            controls.showsColumns,
            controls.showsFilters,
            controls.showsPagination,
            controls.showsFetchAll,
            controls.showsStructureActions,
        ]
    }

    @Test("A table tab keeps the same framing controls at every instant of a reload")
    func controlSetIsInvariantAcrossAReload() {
        let timeline = makeReloadTimeline()
        guard let baseline = timeline.first else { return }
        let expected = framingControls(model(baseline.snapshot).controls)

        for step in timeline.dropFirst() {
            #expect(
                framingControls(model(step.snapshot).controls) == expected,
                "control set changed at: \(step.name)"
            )
        }
    }

    /// The reported blink: the button used to show up the moment the rows landed, because the
    /// retarget had nulled the total, and disappear again when the count arrived.
    @Test("Count Exactly appears once, at the end of a reload")
    func exactCountAppearsOnceAtTheEndOfAReload() {
        let offered = makeReloadTimeline().map { model($0.snapshot).controls.showsExactCountAction }
        #expect(offered == [false, false, false, true, false])
    }

    /// The bar used to collapse to the mode switcher and Filters mid-fetch. Naming the four controls
    /// explicitly means a future change that quietly drops one fails here rather than passing the
    /// invariance test above by removing the same control from every step.
    @Test("The controls a table tab keeps through a reload are the ones worth keeping")
    func reloadKeepsTheControlsThatMatter() {
        for step in makeReloadTimeline() {
            let controls = model(step.snapshot).controls
            #expect(controls.showsReadout, "readout missing at: \(step.name)")
            #expect(controls.showsColumns, "columns missing at: \(step.name)")
            #expect(controls.showsFilters, "filters missing at: \(step.name)")
            #expect(controls.showsPagination, "pagination missing at: \(step.name)")
        }
    }

    @Test("A reloading table never reports itself empty")
    func loadingIsNotAnEmptyResult() {
        var pagination = PaginationState(pageSize: 1_000)
        pagination.isLoading = true
        let snapshot = makeSnapshot(rowCount: 0, hasColumns: false, pagination: pagination)
        #expect(model(snapshot).readout == .loading)
    }

    @Test("A settled table with no rows still reports itself empty")
    func settledEmptyTableStillReportsNoRows() {
        let snapshot = makeSnapshot(rowCount: 0, hasColumns: true, pagination: PaginationState(totalRowCount: 0))
        #expect(model(snapshot).readout == .noRows)
    }

    /// Offered while the total is still being resolved, the button appears the moment the rows land
    /// and disappears again when the count arrives.
    @Test("Count Exactly waits for the total to stop moving")
    func exactCountIsWithheldWhileTheTotalIsUnsettled() {
        var loading = PaginationState(pageSize: 1_000)
        loading.isLoading = true
        #expect(!model(makeSnapshot(rowCount: 0, hasColumns: false, pagination: loading)).controls.showsExactCountAction)

        var counting = PaginationState(pageSize: 1_000)
        counting.isCountPending = true
        #expect(!model(makeSnapshot(rowCount: 1_000, pagination: counting)).controls.showsExactCountAction)

        var settledEstimate = PaginationState(totalRowCount: 4_000_000, pageSize: 1_000)
        settledEstimate.isApproximateRowCount = true
        #expect(model(makeSnapshot(rowCount: 1_000, pagination: settledEstimate)).controls.showsExactCountAction)
    }

    /// The reported sequence was spinner, then "1,000 rows" with Count Exactly, then a jump to
    /// "1-1,000 of 1,000 rows" with the button gone. Every step has to add to the one before it.
    @Test("A reload's readout only ever gains information")
    func readoutOnlyGainsInformationAcrossAReload() {
        let readouts = makeReloadTimeline().map { model($0.snapshot).readout }

        #expect(readouts[1] == .loading, "rows not in yet, so nothing to describe")
        #expect(
            readouts[2] == .rangeOfUnknownTotal(start: 1, end: 1_000),
            "rows are in and the total is still being worked out, so report the range we know"
        )
        #expect(readouts[3] == .range(start: 1, end: 1_000, total: 4_000_000, isEstimate: true))
        #expect(readouts[4] == .range(start: 1, end: 1_000, total: 3_812_004, isEstimate: false))

        #expect(!readouts.contains(.rowCount(1_000)), "a bare row count is the sentence that gets replaced")
    }

    /// A table small enough to fit one page has no range to fall back on, so this is the case that
    /// would regress to a bare count if the pending mark were ignored.
    @Test("A single-page table reports its range while the total is pending")
    func singlePageTableReportsARangeWhilePending() {
        var pending = PaginationState(pageSize: 1_000)
        pending.isCountPending = true
        let snapshot = makeSnapshot(rowCount: 12, pagination: pending)

        #expect(model(snapshot).readout == .rangeOfUnknownTotal(start: 1, end: 12))
        #expect(!model(snapshot).controls.showsExactCountAction)
    }

    /// The driver never returns a total, so the count attempt finishes with nothing. The bar has to
    /// settle rather than keep reporting a pending total.
    @Test("A settled table with no total falls back to its row count")
    func settledTableWithNoTotalReportsRowCount() {
        let snapshot = makeSnapshot(rowCount: 12, pagination: PaginationState(pageSize: 1_000))
        #expect(model(snapshot).readout == .rowCount(12))
    }

    @Test("An unexecuted query tab is not given a table's controls")
    func queryTabKeepsItsContentGate() {
        let snapshot = makeSnapshot(tabType: .query, rowCount: 0, hasColumns: false, hasTableName: false)
        let controls = model(snapshot).controls
        #expect(!controls.showsReadout)
        #expect(!controls.showsColumns)
        #expect(!controls.showsPagination)
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
