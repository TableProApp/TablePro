//
//  MainContentCoordinator+GridFocus.swift
//  TablePro
//

import Foundation

internal extension MainContentCoordinator {
    func focusActiveGrid() {
        dataTabDelegate?.tableViewCoordinator?.focusGrid()
    }
}
