//
//  ResultStatusModel.swift
//  TablePro
//

import Foundation

/// What the status bar says about the rows on screen.
///
/// Cases rather than strings, so the view owns every localization decision. The seven flat catalog
/// keys this replaces were assembled into one sentence by `String(format:)`, which rendered "1 rows"
/// in English and translated "row" as two different Vietnamese nouns depending on which branch of the
/// sentence fired.
enum ResultStatusReadout: Equatable {
    /// A fetch is running and there is nothing loaded to describe yet.
    ///
    /// Distinct from `noRows`, which is a result: retargeting a tab empties its buffer before the
    /// replacing fetch starts, and without this case the bar spends every table switch stating that
    /// the table the user just opened is empty.
    case loading
    case noRows
    case rowCount(Int)
    /// A query result the row cap trimmed; `Fetch All` completes it.
    case partialLoad(Int)
    case range(start: Int, end: Int, total: Int, isEstimate: Bool)
    /// A paged table whose driver could not produce any total.
    case rangeOfUnknownTotal(start: Int, end: Int)
    /// A per-column value filter narrows the loaded page without re-querying, so the server-side
    /// range stops describing what the grid shows.
    case valueFiltered(shown: Int, loaded: Int)
    case selection(selected: Int, of: Int)
    case allSelected(Int)
}

/// Which controls the bar offers for a given result.
struct ResultStatusControls: Equatable {
    var showsModeSwitcher = false
    var showsReadout = false
    var showsLoadingMore = false
    var showsExactCountAction = false
    var showsCountInProgress = false
    var showsFetchAll = false
    var showsColumns = false
    var showsFilters = false
    var showsPagination = false
    /// The structure editor's add and remove pair, which is this bar's trailing cluster while the
    /// structure editor is the content.
    var showsStructureActions = false
}

/// The whole status bar, resolved from tab state before any view exists.
///
/// Pure by design: every branch the bar can take is decidable from these inputs alone, which is what
/// makes the state matrix testable without mounting SwiftUI.
struct ResultStatusModel: Equatable {
    let readout: ResultStatusReadout
    let controls: ResultStatusControls
    let statusMessage: String?

    init(snapshot: StatusBarSnapshot, viewMode: ResultsViewMode, selectedRowCount: Int) {
        let selection = Self.reportedSelection(count: selectedRowCount, viewMode: viewMode)
        controls = Self.resolveControls(snapshot: snapshot, viewMode: viewMode)
        readout = Self.resolveReadout(snapshot: snapshot, selectedRowCount: selection)
        statusMessage = controls.showsReadout ? snapshot.statusMessage : nil
    }

    /// A mode with no grid has no selection to report.
    ///
    /// Nothing clears the grid's selection when the mode changes, so a carried-over count would
    /// replace the row range with a selection the user cannot see.
    private static func reportedSelection(count: Int, viewMode: ResultsViewMode) -> Int {
        viewMode.showsColumnControls ? count : 0
    }

    private static func resolveControls(
        snapshot: StatusBarSnapshot,
        viewMode: ResultsViewMode
    ) -> ResultStatusControls {
        var controls = ResultStatusControls()
        guard snapshot.tabId != nil else { return controls }

        let pagination = snapshot.pagination
        let isTable = snapshot.tabType == .table

        controls.showsModeSwitcher = snapshot.availableModes.count > 1
        controls.showsStructureActions = viewMode == .structure && snapshot.hasStructureActions

        /// A table tab describes a table whether or not its rows have arrived, so its controls are
        /// decided by what the tab IS, never by what its buffer currently holds. Retargeting empties
        /// that buffer before the replacing fetch starts, and deriving presence from it made the
        /// readout, the Columns button and the whole pagination cluster leave the layout and come
        /// back on every table switch. A query tab has no identity until it produces columns, so it
        /// keeps the content gate.
        let describesAResult = isTable ? snapshot.hasTableName : snapshot.hasColumns

        controls.showsReadout = viewMode.showsResultScope && describesAResult
        controls.showsLoadingMore = controls.showsReadout && pagination.isLoadingMore

        /// Withheld until nothing is still resolving the total. Offered against a total that is
        /// about to be replaced, it appears the moment the rows land and disappears again when the
        /// count arrives, which is the same blink one layer down from the one above.
        if controls.showsReadout, isTable, !pagination.isLoadingMore, !pagination.hasExactRowCount {
            controls.showsCountInProgress = pagination.isCountingExact
            controls.showsExactCountAction = !pagination.isCountingExact
                && !pagination.isLoading
                && !pagination.isCountPending
        }

        controls.showsFetchAll = controls.showsReadout
            && snapshot.tabType == .query
            && pagination.hasMoreRows
            && !pagination.isLoadingMore

        controls.showsColumns = viewMode.showsColumnControls && describesAResult
        controls.showsFilters = viewMode.showsRowFilters && isTable && snapshot.hasTableName
        controls.showsPagination = viewMode.showsResultScope && isTable && snapshot.hasTableName

        return controls
    }

    private static func resolveReadout(snapshot: StatusBarSnapshot, selectedRowCount: Int) -> ResultStatusReadout {
        let displayed = snapshot.displayRowCount

        if selectedRowCount > 0 {
            guard selectedRowCount < displayed else { return .allSelected(displayed) }
            return .selection(selected: selectedRowCount, of: displayed)
        }

        /// Ordered ahead of the empty case on purpose. An in-flight fetch with an emptied buffer is
        /// indistinguishable from a table that returned nothing, and calling it "No rows" states a
        /// result the app does not have yet.
        guard !snapshot.pagination.isLoading || displayed > 0 else { return .loading }

        guard displayed > 0 else { return .noRows }

        if snapshot.isValueFiltered {
            return .valueFiltered(shown: displayed, loaded: snapshot.rowCount)
        }

        let pagination = snapshot.pagination

        if snapshot.tabType == .query, pagination.hasMoreRows {
            return .partialLoad(displayed)
        }

        if snapshot.tabType == .table {
            if let total = pagination.totalRowCount, total > 0 {
                return .range(
                    start: pagination.rangeStart,
                    end: pagination.rangeEnd(loadedRowCount: snapshot.rowCount),
                    total: total,
                    isEstimate: pagination.isApproximateRowCount
                )
            }
            /// A total that is still being worked out is reported as the range we do know, not as a
            /// bare row count. Both sentences describe the same rows, but "1,000 rows" reads as the
            /// whole answer and is then replaced by "1-1,000 of 5,000 rows", which is the blink. The
            /// range only ever gains its total, so each step adds to the last instead of retracting.
            if snapshot.isPagedWithUnknownTotal || pagination.isCountPending {
                return .rangeOfUnknownTotal(
                    start: pagination.rangeStart,
                    end: pagination.rangeEnd(loadedRowCount: snapshot.rowCount)
                )
            }
        }

        return .rowCount(displayed)
    }
}
