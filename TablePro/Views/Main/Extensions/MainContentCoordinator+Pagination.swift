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

    func updatePageSize(_ newSize: Int) {
        paginationCoordinator.updatePageSize(newSize)
    }

    func updateOffset(_ newOffset: Int) {
        paginationCoordinator.updateOffset(newOffset)
    }

    func applyPaginationSettings() {
        paginationCoordinator.applyPaginationSettings()
    }
}
