//
//  MainContentCoordinator+LoadMore.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    func cancelCurrentQuery() {
        paginationCoordinator.cancelCurrentQuery()
    }

    func fetchAllRows() {
        paginationCoordinator.fetchAllRows()
    }
}
