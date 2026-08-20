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

        /// Gated on columns rather than rows: a result that matched nothing still carries its column
        /// metadata, and gating on rows made the readout vanish exactly when the user needed to be
        /// told the result was empty.
        controls.showsReadout = viewMode.showsResultScope && snapshot.hasColumns
        controls.showsLoadingMore = controls.showsReadout && pagination.isLoadingMore

        if controls.showsReadout, isTable, !pagination.isLoadingMore, !pagination.hasExactRowCount {
            controls.showsCountInProgress = pagination.isCountingExact
            controls.showsExactCountAction = !pagination.isCountingExact
        }

        controls.showsFetchAll = controls.showsReadout
            && snapshot.tabType == .query
            && pagination.hasMoreRows
            && !pagination.isLoadingMore

        controls.showsColumns = viewMode.showsColumnControls && snapshot.hasColumns
        controls.showsFilters = viewMode.showsRowFilters && isTable && snapshot.hasTableName
        controls.showsPagination = viewMode.showsResultScope
            && isTable
            && snapshot.hasTableName
            && snapshot.showsPaginationControls

        return controls
    }

    private static func resolveReadout(snapshot: StatusBarSnapshot, selectedRowCount: Int) -> ResultStatusReadout {
        let displayed = snapshot.displayRowCount

        if selectedRowCount > 0 {
            guard selectedRowCount < displayed else { return .allSelected(displayed) }
            return .selection(selected: selectedRowCount, of: displayed)
        }

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
            if snapshot.isPagedWithUnknownTotal {
                return .rangeOfUnknownTotal(
                    start: pagination.rangeStart,
                    end: pagination.rangeEnd(loadedRowCount: snapshot.rowCount)
                )
            }
        }

        return .rowCount(displayed)
    }
}
