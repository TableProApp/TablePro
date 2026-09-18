//
//  QueryResultPresentation.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// What the results pane draws.
///
/// One value rather than a nest of conditionals. `MainEditorContentView.resultsSection` used to
/// decide this inside its own body: a switch over `ResultsViewMode` whose five arms each repeated
/// the result-set chrome, wrapped around a five-way `if/else if/else` that chose between the
/// success view, an empty `Spacer`, the no-rows view and the grid. Three of those arms tested
/// `lastExecutedAt != nil && !isExecuting` with slightly different companions, so the states were
/// only accidentally exclusive and none of them could be checked without mounting SwiftUI.
enum QueryResultContent: Equatable {
    /// Nothing has run and there is nothing to show.
    case idle
    /// A fetch is in flight with no loaded buffer to draw under it.
    case executing
    case structure(tableName: String)
    case queryPlan
    case chart
    case map
    case json
    case grid
    /// Columns came back and no rows did, which is a result rather than an absence.
    case noRows(executionTime: TimeInterval?)
    /// A statement that reports work done rather than rows: INSERT, UPDATE, DDL, and whatever it printed on the
    /// server, which for a PL/SQL block is usually the point of running it.
    case statementSucceeded(
        rowsAffected: Int,
        executionTime: TimeInterval?,
        statusMessage: String?,
        serverOutput: PluginServerOutput
    )
    /// What a statement that returned rows printed on the server, on its own in Output mode.
    case serverOutput(PluginServerOutput)
    /// The mode draws the loaded buffer and the buffer is empty, so the mode cannot draw.
    case unavailable(mode: ResultsViewMode)
}

/// Everything the results pane needs in order to decide what it is, gathered before any view exists.
///
/// A plain struct rather than a `QueryTab`, so the whole state matrix is reachable from a test
/// without a tab manager, a coordinator or a session registry behind it.
struct QueryResultInputs: Equatable {
    var tabType: TabType = .query
    var viewMode: ResultsViewMode = .data
    var tableName: String?
    var isExecuting = false
    var hasExecuted = false
    var isExplainResult = false
    var hasActiveResultSet = false
    var resultSetCount = 0
    /// The active result reported columns. A result with none is a statement that did work.
    var activeResultHasColumns = false
    var activeResultRowsAffected = 0
    var activeResultExecutionTime: TimeInterval?
    var activeResultStatusMessage: String?
    var activeResultServerOutput: PluginServerOutput = .none
    /// A failed result carries its own message, which outlives the tab's. Pin a failure, run
    /// something that works, and `executionErrorMessage` is cleared while this one is not.
    var activeResultErrorMessage: String?
    var loadedColumnCount = 0
    var loadedRowCount = 0
    var executionErrorMessage: String?
    var executionRowsAffected = 0
    var executionTime: TimeInterval?
    var executionStatusMessage: String?
    var hasAppliedFilters = false
    var isFilterPanelVisible = false
    var isFindBarVisible = false
}

/// The whole results pane, resolved from tab state before any view exists.
///
/// Pure by design, the way `ResultStatusModel` and `ResultSetPolicy` already are: every branch
/// the pane can take is decidable from `QueryResultInputs` alone.
struct QueryResultPresentation: Equatable {
    let content: QueryResultContent
    /// The result-set chooser in the status bar. One result needs no chooser, and the structure
    /// editor is not a result at all.
    let showsResultSetSelector: Bool
    let showsFilterChrome: Bool
    let showsFindBar: Bool
    /// Always. A plan used to give the bar up, which was harmless while the deleted strip carried
    /// the result chooser above it, and would now leave a plan with no way to be switched away from
    /// or pinned. The plan pane's own chrome is a header, so the bar under it is a footer rather
    /// than a second header; what the bar gives up for a plan is its row readout, decided in
    /// `ResultStatusModel` from `StatusBarSnapshot.isQueryPlan`.
    let showsStatusBar: Bool
    let showsErrorBanner: Bool

    init(inputs: QueryResultInputs) {
        content = Self.resolveContent(inputs)
        showsResultSetSelector = Self.resolvesResultSetSelector(inputs)
        showsFilterChrome = Self.resolvesFilterChrome(inputs)
        showsFindBar = inputs.isFindBarVisible
            && inputs.tabType == .table
            && inputs.viewMode.showsFindBar
        showsStatusBar = true
        showsErrorBanner = Self.resolvedError(inputs) != nil
    }

    /// The error the pane is actually showing. The active result's own message wins, because it
    /// describes the result on screen; the tab's is the fallback for a failure that produced no
    /// result set at all.
    static func resolvedError(_ inputs: QueryResultInputs) -> String? {
        inputs.activeResultErrorMessage ?? inputs.executionErrorMessage
    }

    private static func resolveContent(_ inputs: QueryResultInputs) -> QueryResultContent {
        if inputs.viewMode == .structure {
            guard let tableName = inputs.tableName, !tableName.isEmpty else { return .idle }
            return .structure(tableName: tableName)
        }

        if inputs.isExplainResult { return .queryPlan }

        if inputs.isExecuting, inputs.loadedColumnCount == 0 { return .executing }

        if inputs.viewMode == .output, !inputs.isExecuting, !inputs.activeResultServerOutput.isEmpty {
            return .serverOutput(inputs.activeResultServerOutput)
        }

        /// Ahead of the idle rule below, because these two modes say why they are empty rather
        /// than going blank: a reader who switched to Chart before running anything is told to run
        /// something, which is the one thing a blank pane cannot say.
        if inputs.viewMode == .chart || inputs.viewMode == .map {
            guard inputs.hasActiveResultSet else { return .unavailable(mode: inputs.viewMode) }
        }

        /// A query tab that has never run anything has no result to draw. A table tab does: it
        /// describes a table whether or not its rows have arrived, which is why the gate names the
        /// tab type rather than the buffer.
        if inputs.tabType == .query,
           !inputs.hasExecuted,
           inputs.loadedColumnCount == 0,
           inputs.resultSetCount == 0 {
            return .idle
        }

        if let settled = resolveSettledResult(inputs) { return settled }

        switch inputs.viewMode {
        case .chart:
            return .chart
        case .map:
            return .map
        case .json:
            return .json
        case .data:
            return .grid
        case .structure:
            return .idle
        default:
            return .grid
        }
    }

    /// The three outcomes a finished execution can have that are not a grid of rows. Answered in one
    /// place so they stay mutually exclusive, which they only were by accident while each arm of the
    /// old switch retested `hasExecuted && !isExecuting` beside a different companion condition.
    private static func resolveSettledResult(_ inputs: QueryResultInputs) -> QueryResultContent? {
        guard inputs.hasExecuted, !inputs.isExecuting else { return nil }

        if inputs.hasActiveResultSet, !inputs.activeResultHasColumns, resolvedError(inputs) == nil {
            return .statementSucceeded(
                rowsAffected: inputs.activeResultRowsAffected,
                executionTime: inputs.activeResultExecutionTime,
                statusMessage: inputs.activeResultStatusMessage,
                serverOutput: inputs.activeResultServerOutput
            )
        }

        guard inputs.loadedColumnCount == 0 else { return resolveEmptyRows(inputs) }
        guard resolvedError(inputs) == nil else { return nil }
        guard inputs.resultSetCount > 0 else { return .idle }

        return .statementSucceeded(
            rowsAffected: inputs.executionRowsAffected,
            executionTime: inputs.executionTime,
            statusMessage: inputs.executionStatusMessage,
            serverOutput: .none
        )
    }

    /// Columns without rows. A filtered table that filtered everything away keeps the grid, because
    /// the filter chrome is what the reader needs in order to get their rows back.
    private static func resolveEmptyRows(_ inputs: QueryResultInputs) -> QueryResultContent? {
        guard inputs.tabType == .query else { return nil }
        guard inputs.loadedRowCount == 0, !inputs.hasAppliedFilters else { return nil }
        return .noRows(executionTime: inputs.activeResultExecutionTime ?? inputs.executionTime)
    }

    /// The same condition the deleted strip used, deliberately.
    ///
    /// It would be tempting to hide the chooser at a single result, since its title then says
    /// nothing the pane does not. But Pin, Unpin and Close live in its menu, and pinning a result
    /// before re-running is exactly the workflow that matters when there is one result on screen.
    /// Hiding it there would leave the View menu as the only route to pinning, which is the
    /// capability the strip existed to offer. The chooser costs no height to keep: it is a control
    /// inside a bar that is already on screen, which is the whole difference from a 32pt band.
    private static func resolvesResultSetSelector(_ inputs: QueryResultInputs) -> Bool {
        guard inputs.tabType == .query else { return false }
        guard inputs.viewMode != .structure else { return false }
        return inputs.resultSetCount > 0
    }

    private static func resolvesFilterChrome(_ inputs: QueryResultInputs) -> Bool {
        guard inputs.isFilterPanelVisible, inputs.tabType == .table else { return false }
        return inputs.viewMode.showsRowFilters
    }
}
