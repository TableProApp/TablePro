//
//  MainContentCoordinator+Pagination.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    func goToNextPage() {
        paginationCoordinator.goToNextPage()
    }

    func goToPreviousPage() {
        paginationCoordinator.goToPreviousPage()
    }

    func goToFirstPage() {
        paginationCoordinator.goToFirstPage()
    }

    func goToLastPage() {
        paginationCoordinator.goToLastPage()
    }

    func goToPage(_ page: Int) {
        paginationCoordinator.goToPage(page)
    }

    func updatePageSize(_ newSize: Int) {
        paginationCoordinator.updatePageSize(newSize)
    }

    func showAllRows() {
        paginationCoordinator.showAllRows()
    }
}
