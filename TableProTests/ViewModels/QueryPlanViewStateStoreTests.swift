//
//  QueryPlanViewStateStoreTests.swift
//  TableProTests
//
//  A plan pane's mode and Compare baseline belong to its editor tab and survive a re-run. A plan's
//  selection, zoom and scroll belong to that plan: kept while its result tab lives, never handed to
//  another plan, and dropped with the result set or the tab.
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct QueryPlanViewStateStoreTests {
    @Test("The same plan in the same tab gets back the state it was left with")
    func samePlanKeepsItsState() {
        let store = QueryPlanViewStateStore()
        let tab = UUID()
        let plan = UUID()
        let step = UUID()
        let first = store.planState(forResultSet: plan, inTab: tab, liveResultSetIds: [plan])
        first.selectedNodeId = step
        first.viewport.zoomIn()

        let again = store.planState(forResultSet: plan, inTab: tab, liveResultSetIds: [plan])

        #expect(again === first)
        #expect(again.selectedNodeId == step)
        #expect(again.viewport.magnification == DiagramZoom.stepUp(from: 1.0))
    }

    @Test("A new plan starts at 100% with nothing selected instead of taking the previous plan's")
    func newPlanStartsFresh() {
        let store = QueryPlanViewStateStore()
        let tab = UUID()
        let previous = UUID()
        let next = UUID()
        let previousState = store.planState(forResultSet: previous, inTab: tab, liveResultSetIds: [previous])
        previousState.selectedNodeId = UUID()
        previousState.viewport.zoomOut()

        let nextState = store.planState(forResultSet: next, inTab: tab, liveResultSetIds: [next])

        #expect(nextState !== previousState)
        #expect(nextState.selectedNodeId == nil)
        #expect(nextState.viewport.magnification == 1.0)
    }

    /// Compare is documented to follow a statement that is run again, which replaces the plan.
    @Test("A re-run keeps the tab's mode and Compare model")
    func tabStateOutlivesItsPlans() {
        let store = QueryPlanViewStateStore()
        let tab = UUID()
        let tabState = store.tabState(forTab: tab)
        tabState.viewMode = .compare
        _ = store.planState(forResultSet: UUID(), inTab: tab, liveResultSetIds: [])

        let afterRerun = store.tabState(forTab: tab)

        #expect(afterRerun === tabState)
        #expect(afterRerun.viewMode == .compare)
        #expect(afterRerun.comparison === tabState.comparison)
    }

    @Test("A plan replaced by a re-run is dropped, and a pinned plan beside it is kept")
    func replacedPlansAreDropped() {
        let store = QueryPlanViewStateStore()
        let tab = UUID()
        let pinned = UUID()
        let replaced = UUID()
        let rerun = UUID()
        let pinnedState = store.planState(forResultSet: pinned, inTab: tab, liveResultSetIds: [pinned, replaced])
        let replacedState = store.planState(forResultSet: replaced, inTab: tab, liveResultSetIds: [pinned, replaced])

        _ = store.planState(forResultSet: rerun, inTab: tab, liveResultSetIds: [pinned, rerun])

        #expect(store.planState(forResultSet: pinned, inTab: tab, liveResultSetIds: [pinned, rerun]) === pinnedState)
        #expect(store.planState(forResultSet: replaced, inTab: tab, liveResultSetIds: [pinned, replaced]) !== replacedState)
    }

    @Test("Each tab keeps its own state, and closing a tab drops it")
    func tabsKeepTheirOwnState() {
        let store = QueryPlanViewStateStore()
        let closedTab = UUID()
        let openTab = UUID()
        let plan = UUID()
        let planInClosedTab = store.planState(forResultSet: plan, inTab: closedTab, liveResultSetIds: [plan])
        let planInOpenTab = store.planState(forResultSet: plan, inTab: openTab, liveResultSetIds: [plan])
        let closedTabState = store.tabState(forTab: closedTab)
        let openTabState = store.tabState(forTab: openTab)
        #expect(planInClosedTab !== planInOpenTab)
        #expect(closedTabState !== openTabState)

        store.retainTabs([openTab])

        #expect(store.planState(forResultSet: plan, inTab: closedTab, liveResultSetIds: [plan]) !== planInClosedTab)
        #expect(store.planState(forResultSet: plan, inTab: openTab, liveResultSetIds: [plan]) === planInOpenTab)
        #expect(store.tabState(forTab: closedTab) !== closedTabState)
        #expect(store.tabState(forTab: openTab) === openTabState)
    }
}
