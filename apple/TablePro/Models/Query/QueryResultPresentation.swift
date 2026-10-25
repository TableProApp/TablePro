//
//  QueryResultPresentation.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// One value instead of conditionals in the view body, so the states stay exclusive and testable without mounting SwiftUI.
enum QueryResultContent: Equatable {
    case idle
    // In flight with no loaded buffer to draw under it.
    case executing
    case structure(tableName: String)
    case queryPlan
    case chart
    case map
    case json
    case grid
    // Columns but no rows: a result, not an absence.
    case noRows(executionTime: TimeInterval?)
    // INSERT, UPDATE, DDL. The server output is usually the point of running a PL/SQL block.
    case statementSucceeded(
        rowsAffected: Int,
        executionTime: TimeInterval?,
        statusMessage: String?,
        serverOutput: PluginServerOutput
    )
    // What a statement that returned rows printed on the server, shown alone in Output mode.
    case serverOutput(PluginServerOutput)
    // The mode draws the loaded buffer, and the buffer is empty.
    case unavailable(mode: ResultsViewMode)
}

// A plain struct, not a `QueryTab`, so tests reach every state without a tab manager, coordinator or session registry.
struct QueryResultInputs: Equatable {
    var tabType: TabType = .query
    var viewMode: ResultsViewMode = .data
    var tableName: String?
    var isExecuting = false
    var hasExecuted = false
    var isExplainResult = false
    var hasActiveResultSet = false
    var resultSetCount = 0
    // A result with no columns is a statement that did work.
    var activeResultHasColumns = false
    var activeResultRowsAffected = 0
    var activeResultExecutionTime: TimeInterval?
    var activeResultStatusMessage: String?
    var activeResultServerOutput: PluginServerOutput = .none
    // Outlives the tab's message: pin a failure, run something that works, and only `executionErrorMessage` is cleared.
    var activeResultErrorMessage: String?
    var loadedColumnCount = 0
    var loadedRowCount = 0
    var executionErrorMessage: String?
    var executionRowsAffected = 0
    var executionTime: TimeInterval?
    var executionStatusMessage: String?
    var hasAppliedFilters = false
    var isFilterPanelVisible = false
}

// Pure: every branch is decidable from `QueryResultInputs` alone, like `ResultStatusModel` and `ResultSetPolicy`.
struct QueryResultPresentation: Equatable {
    let content: QueryResultContent
    let showsResultSetSelector: Bool
    let showsFilterChrome: Bool
    // Always: a plan without the bar can't be switched away from or pinned. Its row readout hides via `StatusBarSnapshot.isQueryPlan`.
    let showsStatusBar: Bool
    let showsErrorBanner: Bool

    init(inputs: QueryResultInputs) {
        content = Self.resolveContent(inputs)
        showsResultSetSelector = Self.resolvesResultSetSelector(inputs)
        showsFilterChrome = Self.resolvesFilterChrome(inputs)
        showsStatusBar = true
        showsErrorBanner = Self.resolvedError(inputs) != nil
    }

    // The active result's message wins since it describes the result on screen; the tab's covers a failure with no result set.
    static func resolvedError(_ inputs: QueryResultInputs) -> String? {
        inputs.activeResultErrorMessage ?? inputs.executionErrorMessage
    }

    private static func resolveContent(_ inputs: QueryResultInputs) -> QueryResultContent {
        if inputs.viewMode == .structure {
            guard let tableName = inputs.tableName, !tableName.isEmpty else { return .idle }
            return .structure(tableName: tableName)
        }

        if inputs.isExplainResult { return .queryPlan }

        // A table's grid stays mounted while its first page loads: dropping it on a retarget blanked the pane and took first responder.
        if inputs.isExecuting, inputs.loadedColumnCount == 0, !Self.keepsGridWhileLoading(inputs) {
            return .executing
        }

        if inputs.viewMode == .output, !inputs.isExecuting, !inputs.activeResultServerOutput.isEmpty {
            return .serverOutput(inputs.activeResultServerOutput)
        }

        // Before the idle rule: Chart and Map say why they are empty, so a reader who switched before running is told to run something.
        if inputs.viewMode == .chart || inputs.viewMode == .map {
            guard inputs.hasActiveResultSet else { return .unavailable(mode: inputs.viewMode) }
        }

        // Gated on tab type, not the buffer: a table tab describes its table whether or not its rows have arrived.
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

    // One place for the three non-grid outcomes, so they stay mutually exclusive.
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
        // A failed table load leaves no result set and dismissing its banner clears the error, so this is an unloaded table.
        guard inputs.resultSetCount > 0 else { return inputs.tabType == .table ? nil : .idle }

        return .statementSucceeded(
            rowsAffected: inputs.executionRowsAffected,
            executionTime: inputs.executionTime,
            statusMessage: inputs.executionStatusMessage,
            serverOutput: .none
        )
    }

    private static func keepsGridWhileLoading(_ inputs: QueryResultInputs) -> Bool {
        inputs.tabType == .table && inputs.viewMode == .data
    }

    // A filtered table that filtered everything away keeps the grid: the filter chrome is how the reader gets rows back.
    private static func resolveEmptyRows(_ inputs: QueryResultInputs) -> QueryResultContent? {
        guard inputs.tabType == .query else { return nil }
        guard inputs.loadedRowCount == 0, !inputs.hasAppliedFilters else { return nil }
        return .noRows(executionTime: inputs.activeResultExecutionTime ?? inputs.executionTime)
    }

    // Shown even for one result: Pin, Unpin and Close live in its menu, and it costs no height inside the status bar.
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
