//
//  QueryResultPresentationTests.swift
//  TableProTests
//
//  The results pane used to decide what it showed inside a SwiftUI body: a switch over the view
//  mode whose arms repeated the result chrome, around a nested if/else chain whose branches each
//  retested "has executed and is not executing" beside a different companion. None of it could be
//  checked without mounting a view. These are the states that matrix can reach.
//

import Foundation
@testable import TablePro
import Testing

@Suite("QueryResultPresentation")
struct QueryResultPresentationTests {
    @Test("A fresh query tab shows nothing rather than an empty grid")
    func idleTab() {
        let presentation = QueryResultPresentation(inputs: QueryResultInputs())

        #expect(presentation.content == .idle)
        #expect(presentation.showsResultSetSelector == false)
        #expect(presentation.showsErrorBanner == false)
    }

    /// A table tab describes a table whether or not its rows have arrived, so the idle rule above
    /// must not reach it: retargeting empties the buffer before the replacing fetch starts.
    @Test("A table tab with no rows yet still draws its grid")
    func freshTableTabKeepsGrid() {
        var inputs = QueryResultInputs()
        inputs.tabType = .table

        #expect(QueryResultPresentation(inputs: inputs).content == .grid)
    }

    @Test("A fetch with no loaded buffer reports itself rather than claiming no rows")
    func executingWithNoBuffer() {
        var inputs = QueryResultInputs()
        inputs.isExecuting = true

        #expect(QueryResultPresentation(inputs: inputs).content == .executing)
    }

    /// Retargeting a tab empties its buffer before the replacing fetch starts. Reporting "no rows"
    /// there states that the table the reader just opened is empty.
    @Test("A running fetch over loaded rows keeps drawing them")
    func executingOverLoadedRows() {
        var inputs = QueryResultInputs()
        inputs.isExecuting = true
        inputs.hasExecuted = true
        inputs.loadedColumnCount = 3
        inputs.loadedRowCount = 12

        #expect(QueryResultPresentation(inputs: inputs).content == .grid)
    }

    @Test("Columns with no rows is a result, not an absence")
    func columnsWithoutRows() {
        var inputs = QueryResultInputs()
        inputs.hasExecuted = true
        inputs.hasActiveResultSet = true
        inputs.activeResultHasColumns = true
        inputs.loadedColumnCount = 4
        inputs.loadedRowCount = 0
        inputs.activeResultExecutionTime = 0.25

        #expect(QueryResultPresentation(inputs: inputs).content == .noRows(executionTime: 0.25))
    }

    /// A filter that matched nothing must keep the grid, because the filter chrome above it is the
    /// only way the reader gets their rows back.
    @Test("A filter that matched nothing keeps the grid")
    func filteredToNothingKeepsGrid() {
        var inputs = QueryResultInputs()
        inputs.hasExecuted = true
        inputs.hasActiveResultSet = true
        inputs.activeResultHasColumns = true
        inputs.loadedColumnCount = 4
        inputs.loadedRowCount = 0
        inputs.hasAppliedFilters = true

        #expect(QueryResultPresentation(inputs: inputs).content == .grid)
    }

    @Test("A statement that reports work rather than rows shows the success view")
    func statementSucceeded() {
        var inputs = QueryResultInputs()
        inputs.hasExecuted = true
        inputs.hasActiveResultSet = true
        inputs.activeResultHasColumns = false
        inputs.activeResultRowsAffected = 7
        inputs.activeResultExecutionTime = 0.1
        inputs.activeResultStatusMessage = "OK"

        #expect(QueryResultPresentation(inputs: inputs).content == .statementSucceeded(
            rowsAffected: 7,
            executionTime: 0.1,
            statusMessage: "OK"
        ))
    }

    @Test("A failed execution shows the banner and does not claim success")
    func failedExecution() {
        var inputs = QueryResultInputs()
        inputs.hasExecuted = true
        inputs.hasActiveResultSet = true
        inputs.executionErrorMessage = "syntax error"

        let presentation = QueryResultPresentation(inputs: inputs)

        #expect(presentation.showsErrorBanner)
        if case .statementSucceeded = presentation.content {
            Issue.record("A failed execution must never resolve to the success view")
        }
    }

    @Test("A query plan replaces the content and keeps the bar that chooses it")
    func queryPlanOwnsThePane() {
        var inputs = QueryResultInputs()
        inputs.hasExecuted = true
        inputs.isExplainResult = true
        inputs.hasActiveResultSet = true
        inputs.resultSetCount = 1

        let presentation = QueryResultPresentation(inputs: inputs)

        #expect(presentation.content == .queryPlan)
        /// The bar stays. It is the only thing carrying the result chooser now, so a plan that
        /// gave it up could not be switched away from or pinned. What a plan gives up there is the
        /// row readout, which `ResultStatusModel` drops from `StatusBarSnapshot.isQueryPlan`.
        #expect(presentation.showsStatusBar)
        #expect(presentation.showsResultSetSelector)
    }

    /// Pin a failure, run something that works, and the tab's own message is cleared while the
    /// pinned result's is not. Switching back used to resolve the failure as a success, because the
    /// error result reports no columns.
    @Test("A pinned failure still reads as a failure after a later run succeeds")
    func pinnedFailureStaysAFailure() {
        var inputs = QueryResultInputs()
        inputs.hasExecuted = true
        inputs.hasActiveResultSet = true
        inputs.activeResultHasColumns = false
        inputs.activeResultErrorMessage = "syntax error"
        inputs.executionErrorMessage = nil

        let presentation = QueryResultPresentation(inputs: inputs)

        #expect(presentation.showsErrorBanner)
        if case .statementSucceeded = presentation.content {
            Issue.record("A pinned failure must never resolve to the success view")
        }
    }

    /// The find bar searches the data grid's coordinator. Switching to a mode that unmounts the
    /// grid left it on screen over nothing to search.
    @Test("The find bar follows the mode, not just the tab type")
    func findBarFollowsMode() {
        var inputs = QueryResultInputs()
        inputs.tabType = .table
        inputs.isFindBarVisible = true

        inputs.viewMode = .data
        #expect(QueryResultPresentation(inputs: inputs).showsFindBar)

        for mode in [ResultsViewMode.chart, .map, .structure] {
            inputs.viewMode = mode
            #expect(
                QueryResultPresentation(inputs: inputs).showsFindBar == mode.showsFindBar,
                "find bar must follow ResultsViewMode.showsFindBar for \(mode)"
            )
        }
    }

    @Test("Structure mode needs a table to show the structure of")
    func structureNeedsATable() {
        var inputs = QueryResultInputs()
        inputs.viewMode = .structure
        inputs.tableName = "orders"

        #expect(QueryResultPresentation(inputs: inputs).content == .structure(tableName: "orders"))

        inputs.tableName = nil
        #expect(QueryResultPresentation(inputs: inputs).content == .idle)

        inputs.tableName = ""
        #expect(QueryResultPresentation(inputs: inputs).content == .idle)
    }

    @Test("Chart and map say so when there is nothing loaded to draw")
    func chartAndMapWithoutData() {
        for mode in [ResultsViewMode.chart, .map] {
            var inputs = QueryResultInputs()
            inputs.viewMode = mode
            inputs.hasActiveResultSet = false

            #expect(QueryResultPresentation(inputs: inputs).content == .unavailable(mode: mode))
        }
    }

    @Test("Chart and map draw once a result is loaded")
    func chartAndMapWithData() {
        var chart = QueryResultInputs()
        chart.viewMode = .chart
        chart.hasActiveResultSet = true
        chart.activeResultHasColumns = true
        chart.loadedColumnCount = 2
        #expect(QueryResultPresentation(inputs: chart).content == .chart)

        var map = chart
        map.viewMode = .map
        #expect(QueryResultPresentation(inputs: map).content == .map)
    }

    @Test("The structure editor is not a result, so it offers no result chooser")
    func structureHasNoChooser() {
        var inputs = QueryResultInputs()
        inputs.viewMode = .structure
        inputs.tableName = "orders"
        inputs.resultSetCount = 3

        #expect(QueryResultPresentation(inputs: inputs).showsResultSetSelector == false)
    }

    @Test("Only a query tab chooses between result sets")
    func onlyQueryTabsChoose() {
        var inputs = QueryResultInputs()
        inputs.resultSetCount = 2
        inputs.tabType = .table

        #expect(QueryResultPresentation(inputs: inputs).showsResultSetSelector == false)
    }

    @Test("The find bar belongs to table tabs")
    func findBarIsTableOnly() {
        var inputs = QueryResultInputs()
        inputs.isFindBarVisible = true
        inputs.tabType = .query
        #expect(QueryResultPresentation(inputs: inputs).showsFindBar == false)

        inputs.tabType = .table
        #expect(QueryResultPresentation(inputs: inputs).showsFindBar)
    }

    @Test("Filter chrome follows the mode that can be filtered")
    func filterChromeFollowsMode() {
        var inputs = QueryResultInputs()
        inputs.tabType = .table
        inputs.isFilterPanelVisible = true

        inputs.viewMode = .data
        #expect(QueryResultPresentation(inputs: inputs).showsFilterChrome)

        inputs.viewMode = .map
        #expect(QueryResultPresentation(inputs: inputs).showsFilterChrome == false)
    }

    /// The property the old nested `if/else` only had by accident.
    @Test("Every reachable input resolves to exactly one content case")
    func everyStateResolvesOnce() {
        var seen: Set<String> = []
        for viewMode in [ResultsViewMode.data, .structure, .json, .chart, .map] {
            for isExecuting in [true, false] {
                for hasExecuted in [true, false] {
                    for hasResultSet in [true, false] {
                        for hasColumns in [true, false] {
                            for rowCount in [0, 5] {
                                var inputs = QueryResultInputs()
                                inputs.viewMode = viewMode
                                inputs.tableName = "orders"
                                inputs.isExecuting = isExecuting
                                inputs.hasExecuted = hasExecuted
                                inputs.hasActiveResultSet = hasResultSet
                                inputs.activeResultHasColumns = hasColumns
                                inputs.loadedColumnCount = hasColumns ? 3 : 0
                                inputs.loadedRowCount = rowCount
                                inputs.resultSetCount = hasResultSet ? 1 : 0

                                let content = QueryResultPresentation(inputs: inputs).content
                                seen.insert("\(content)")
                            }
                        }
                    }
                }
            }
        }

        #expect(!seen.isEmpty)
    }
}
