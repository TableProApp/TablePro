//
//  AgentResultGridDelegate.swift
//  TablePro
//

import AppKit
import Combine

/// Carries the agent result grid's header clicks back to the view that owns the rows.
///
/// `DataGridView` announces a sort rather than performing one, because every grid it normally
/// draws re-runs its query to get the next page in the new order. The agent result pane holds the
/// whole result and has no query to re-run, so it answers the announcement itself.
@MainActor
internal final class AgentResultGridDelegate: ObservableObject, DataGridViewDelegate {
    internal var onSortStateChanged: ((SortState) -> Void)?

    internal func dataGridSortStateChanged(_ state: SortState) {
        onSortStateChanged?(state)
    }
}
