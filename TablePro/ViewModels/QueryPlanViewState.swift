//
//  QueryPlanViewState.swift
//  TablePro
//
//  Where a plan pane was left. The view that shows a plan is rebuilt on every editor-tab, result-tab
//  and mode switch, so the editor keeps this instead: the mode and Compare baseline per editor tab,
//  and the selected step, zoom and scroll per plan.
//

import Foundation
import Observation

/// Belongs to the editor tab rather than to one plan in it, so running the statement again replaces
/// the plan and keeps the pane in Compare with the baseline that was chosen.
@MainActor
@Observable
final class QueryPlanTabState {
    var viewMode: QueryPlanViewMode = .diagram

    @ObservationIgnored let comparison = QueryPlanComparisonModel()
}

@MainActor
@Observable
final class QueryPlanViewState {
    /// Shared by the diagram and the outline, so switching view mode keeps the selected step.
    var selectedNodeId: UUID?

    @ObservationIgnored let viewport = DiagramViewportController()
}

/// A re-run replaces a plan's result set with a new one, which drops the old plan's state the next
/// time the tab asks for a plan, and closing an editor tab drops everything it held.
@MainActor
final class QueryPlanViewStateStore {
    private var tabStates: [UUID: QueryPlanTabState] = [:]
    private var planStates: [UUID: [UUID: QueryPlanViewState]] = [:]

    func tabState(forTab tabId: UUID) -> QueryPlanTabState {
        let state = tabStates[tabId] ?? QueryPlanTabState()
        tabStates[tabId] = state
        return state
    }

    func planState(forResultSet resultSetId: UUID, inTab tabId: UUID, liveResultSetIds: Set<UUID>) -> QueryPlanViewState {
        var states = (planStates[tabId] ?? [:]).filter { liveResultSetIds.contains($0.key) }
        let state = states[resultSetId] ?? QueryPlanViewState()
        states[resultSetId] = state
        planStates[tabId] = states
        return state
    }

    func retainTabs(_ openTabIds: Set<UUID>) {
        tabStates = tabStates.filter { openTabIds.contains($0.key) }
        planStates = planStates.filter { openTabIds.contains($0.key) }
    }
}
