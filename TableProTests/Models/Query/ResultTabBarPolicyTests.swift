//
//  ResultTabBarPolicyTests.swift
//  TableProTests
//
//  Guards the invariant behind #1982: a result that the View menu says can be pinned
//  always has a result tab on screen to pin it from.
//

import Foundation
@testable import TablePro
import Testing

@MainActor
@Suite("ResultTabBarPolicy")
struct ResultTabBarPolicyTests {
    @Test("A query tab with a result shows the strip and can pin")
    func queryTabWithResult() {
        let display = Self.makeDisplay()

        #expect(ResultTabBarPolicy.showsTabBar(tabType: .query, display: display))
        #expect(ResultTabBarPolicy.canPin(tabType: .query, display: display))
    }

    @Test("JSON view keeps the strip so its results stay switchable and pinnable")
    func jsonViewKeepsStrip() {
        var display = Self.makeDisplay()
        display.resultsViewMode = .json

        #expect(ResultTabBarPolicy.showsTabBar(tabType: .query, display: display))
        #expect(ResultTabBarPolicy.canPin(tabType: .query, display: display))
    }

    @Test("Structure view has no result strip and nothing to pin")
    func structureViewHasNoStrip() {
        var display = Self.makeDisplay()
        display.resultsViewMode = .structure

        #expect(ResultTabBarPolicy.showsTabBar(tabType: .query, display: display) == false)
        #expect(ResultTabBarPolicy.canPin(tabType: .query, display: display) == false)
    }

    @Test("An explain result is not a result set, so nothing can be pinned")
    func explainHasNothingToPin() {
        var display = Self.makeDisplay()
        display.explainText = "Seq Scan on orders"

        #expect(ResultTabBarPolicy.showsTabBar(tabType: .query, display: display) == false)
        #expect(ResultTabBarPolicy.canPin(tabType: .query, display: display) == false)
    }

    @Test("A tab with no results has no strip and nothing to pin")
    func emptyResultsHaveNothingToPin() {
        let display = TabDisplayState()

        #expect(ResultTabBarPolicy.showsTabBar(tabType: .query, display: display) == false)
        #expect(ResultTabBarPolicy.canPin(tabType: .query, display: display) == false)
    }

    @Test("Only query tabs pin results")
    func onlyQueryTabsPin() {
        let display = Self.makeDisplay()
        let others: [TabType] = [.table, .createTable, .erDiagram, .serverDashboard, .usersRoles]

        for tabType in others {
            #expect(ResultTabBarPolicy.showsTabBar(tabType: tabType, display: display) == false)
            #expect(ResultTabBarPolicy.canPin(tabType: tabType, display: display) == false)
        }
    }

    @Test("Collapsing the results panel does not take pinning away")
    func collapsedResultsStayPinnable() {
        var display = Self.makeDisplay()
        display.isResultsCollapsed = true

        #expect(ResultTabBarPolicy.canPin(tabType: .query, display: display))
    }

    @Test("A result is never pinnable without a strip to pin it from")
    func pinningNeverOutrunsTheStrip() {
        var states: [TabDisplayState] = [TabDisplayState(), Self.makeDisplay()]
        for mode in [ResultsViewMode.data, .structure, .json] {
            var display = Self.makeDisplay()
            display.resultsViewMode = mode
            states.append(display)

            var explaining = display
            explaining.explainText = "plan"
            states.append(explaining)
        }

        let tabTypes: [TabType] = [.query, .table, .createTable, .erDiagram, .serverDashboard, .usersRoles]
        for display in states {
            for tabType in tabTypes {
                let canPin = ResultTabBarPolicy.canPin(tabType: tabType, display: display)
                let showsTabBar = ResultTabBarPolicy.showsTabBar(tabType: tabType, display: display)
                #expect(!canPin || showsTabBar)
            }
        }
    }

    private static func makeDisplay() -> TabDisplayState {
        var display = TabDisplayState()
        let result = ResultSet(label: "Result")
        display.resultSets = [result]
        display.activeResultSetId = result.id
        return display
    }
}
