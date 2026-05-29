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
}
