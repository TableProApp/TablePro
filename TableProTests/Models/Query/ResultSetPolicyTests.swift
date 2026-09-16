//
//  ResultSetPolicyTests.swift
//  TableProTests
//
//  Guards the invariant behind #1982: a result the View menu says can be pinned always has a
//  control on screen to pin it from. The control used to be the result strip; it is the status
//  bar's result-set chooser now, and the invariant is unchanged.
//

import Foundation
@testable import TablePro
import Testing

@MainActor
@Suite("ResultSetPolicy")
struct ResultSetPolicyTests {
    @Test("A query tab with a result offers the chooser and can pin")
    func queryTabWithResult() {
        let display = Self.makeDisplay()

        #expect(Self.showsChooser(tabType: .query, display: display))
        #expect(ResultSetPolicy.canPin(tabType: .query, display: display))
    }

    @Test("JSON view keeps the chooser so its results stay switchable and pinnable")
    func jsonViewKeepsChooser() {
        var display = Self.makeDisplay()
        display.resultsViewMode = .json

        #expect(Self.showsChooser(tabType: .query, display: display))
        #expect(ResultSetPolicy.canPin(tabType: .query, display: display))
    }

    @Test("Chart view keeps the chooser so each result keeps its own configuration")
    func chartViewKeepsChooser() {
        var display = Self.makeDisplay()
        display.resultsViewMode = .chart

        #expect(Self.showsChooser(tabType: .query, display: display))
        #expect(ResultSetPolicy.canPin(tabType: .query, display: display))
    }

    @Test("Structure view has no chooser and nothing to pin")
    func structureViewHasNoChooser() {
        var display = Self.makeDisplay()
        display.resultsViewMode = .structure

        #expect(Self.showsChooser(tabType: .query, display: display) == false)
        #expect(ResultSetPolicy.canPin(tabType: .query, display: display) == false)
    }

    @Test("An explain result is a result set, so it offers the chooser and can be pinned")
    func explainBehavesLikeAResultSet() {
        var display = Self.makeDisplay()
        let plan = ExplainResultSetFactory.make(
            rawText: "Seq Scan on orders", plan: nil, sql: "EXPLAIN SELECT 1", executionTime: 0.2
        )
        display.resultSets = [plan]
        display.activeResultSetId = plan.id

        #expect(Self.showsChooser(tabType: .query, display: display))
        #expect(ResultSetPolicy.canPin(tabType: .query, display: display))
        #expect(display.activeExplainResult?.id == plan.id)
    }

    @Test("A tab with no results has no chooser and nothing to pin")
    func emptyResultsHaveNothingToPin() {
        let display = TabDisplayState()

        #expect(Self.showsChooser(tabType: .query, display: display) == false)
        #expect(ResultSetPolicy.canPin(tabType: .query, display: display) == false)
    }

    @Test("Only query tabs pin results")
    func onlyQueryTabsPin() {
        let display = Self.makeDisplay()
        let others: [TabType] = [.table, .createTable, .erDiagram, .serverDashboard, .usersRoles]

        for tabType in others {
            #expect(Self.showsChooser(tabType: tabType, display: display) == false)
            #expect(ResultSetPolicy.canPin(tabType: tabType, display: display) == false)
        }
    }

    @Test("Collapsing the results panel does not take pinning away")
    func collapsedResultsStayPinnable() {
        var display = Self.makeDisplay()
        display.isResultsCollapsed = true

        #expect(ResultSetPolicy.canPin(tabType: .query, display: display))
    }

    /// The whole reason the chooser is shown at a single result rather than hidden: Pin lives in
    /// its menu, so a hidden chooser is an unpinnable result.
    @Test("A result is never pinnable without a chooser to pin it from")
    func pinningNeverOutrunsTheChooser() {
        var states: [TabDisplayState] = [TabDisplayState(), Self.makeDisplay()]
        for mode in [ResultsViewMode.data, .structure, .json, .chart, .map] {
            var display = Self.makeDisplay()
            display.resultsViewMode = mode
            states.append(display)

            var withoutResults = display
            withoutResults.resultSets = []
            withoutResults.activeResultSetId = nil
            states.append(withoutResults)
        }

        let tabTypes: [TabType] = [.query, .table, .createTable, .erDiagram, .serverDashboard, .usersRoles]
        for display in states {
            for tabType in tabTypes {
                let canPin = ResultSetPolicy.canPin(tabType: tabType, display: display)
                #expect(!canPin || Self.showsChooser(tabType: tabType, display: display))
            }
        }
    }

    /// Asks the resolver, so this suite fails if the pane and the bar ever stop agreeing about
    /// whether there is a result to choose between.
    private static func showsChooser(tabType: TabType, display: TabDisplayState) -> Bool {
        var inputs = QueryResultInputs()
        inputs.tabType = tabType
        inputs.viewMode = display.resultsViewMode
        inputs.resultSetCount = display.resultSets.count
        return QueryResultPresentation(inputs: inputs).showsResultSetSelector
    }

    private static func makeDisplay() -> TabDisplayState {
        var display = TabDisplayState()
        let result = ResultSet(label: "Result")
        display.resultSets = [result]
        display.activeResultSetId = result.id
        return display
    }
}
