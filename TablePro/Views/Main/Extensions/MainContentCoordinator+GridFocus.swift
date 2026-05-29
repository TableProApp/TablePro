//
//  MainContentCoordinator+GridFocus.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    func focusActiveGrid() {
        dataTabDelegate?.tableViewCoordinator?.focusGrid()
    }
}
