//
//  MainContentCoordinator+GridFocus.swift
//  TablePro
//

import Foundation

internal extension MainContentCoordinator {
    @discardableResult
    func focusActiveGrid() -> Bool {
        selectedTabGridModel?.focus() ?? false
    }

    func consumePendingGridFocus() -> Bool {
        guard pendingGridFocusOnOpen else { return false }
        pendingGridFocusOnOpen = false
        return true
    }

    // For an explicit open: focus a grid already on screen, or let the grid take it as it mounts.
    func requestGridFocus() {
        pendingGridFocusOnOpen = !focusActiveGrid()
    }
}
