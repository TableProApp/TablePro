//
//  MainContentCommandActions+Focus.swift
//  TablePro
//

import AppKit

internal extension MainContentCommandActions {
    /// Focus Results goes through the grid's own coordinator rather than naming a view, because the
    /// grid already owns the call and answers whether it took the keyboard.
    ///
    /// A collapsed result pane keeps its grid attached to the window, so focusing without expanding
    /// first sends the keyboard to a table clipped to nothing.
    @discardableResult
    func focusActiveGrid() -> Bool {
        expandResultsIfCollapsed()
        return coordinator?.dataTabDelegate?.tableViewCoordinator?.focusGrid() ?? false
    }

    /// A grid that is not in a window cannot take the keyboard, which is the state a query tab with
    /// no result, and every result view other than the data grid, leaves behind.
    var canFocusActiveGrid: Bool {
        coordinator?.dataTabDelegate?.tableViewCoordinator?.tableView?.window != nil
    }

    private func expandResultsIfCollapsed() {
        guard let coordinator,
              let (tab, tabIndex) = coordinator.tabManager.selectedTabAndIndex,
              tab.display.isResultsCollapsed else { return }
        coordinator.tabManager.mutate(at: tabIndex) { $0.display.isResultsCollapsed = false }
        coordinator.toolbarState.isResultsCollapsed = false
    }
}
