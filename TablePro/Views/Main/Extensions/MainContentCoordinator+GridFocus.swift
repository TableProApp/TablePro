//
//  MainContentCoordinator+GridFocus.swift
//  TablePro
//

import Foundation

internal extension MainContentCoordinator {
    func focusActiveGrid() {
        dataTabDelegate?.tableViewCoordinator?.focusGrid()
    }

    func consumePendingGridFocus() -> Bool {
        guard pendingGridFocusOnOpen else { return false }
        pendingGridFocusOnOpen = false
        return true
    }

    /// Focus the active grid now if it is already attached, otherwise defer to the grid
    /// as it appears. Use for explicit-open gestures where the target grid may or may not
    /// be rebuilt (e.g. promoting a preview tab).
    func requestGridFocus() {
        pendingGridFocusOnOpen = !(dataTabDelegate?.tableViewCoordinator?.focusGrid() ?? false)
    }
}
