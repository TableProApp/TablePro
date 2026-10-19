//
//  HeldRowsGridDelegate.swift
//  TablePro
//

import AppKit
import Combine

/// Carries a grid's header clicks back to the view that holds its rows.
///
/// `DataGridView` announces a sort rather than performing one, because every grid it normally
/// draws re-runs its query to get the next page in the new order. The agent result pane and a table
/// listing hold their whole result and have no query to re-run, so they answer the announcement
/// themselves.
@MainActor
internal final class HeldRowsGridDelegate: ObservableObject, DataGridViewDelegate {
    internal var onSortStateChanged: ((SortState) -> Void)?

    internal func dataGridSortStateChanged(_ state: SortState) {
        onSortStateChanged?(state)
    }
}
