//
//  MainContentCoordinator+Pagination.swift
//  TablePro
//
//  Pagination operations for MainContentCoordinator
//

import Foundation

extension MainContentCoordinator {
    // MARK: - Pagination

    /// Navigate to next page
    func goToNextPage() {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count else { return }

        var tab = tabManager.tabs[tabIndex]
        guard tab.pagination.hasNextPage else { return }

        tab.pagination.goToNextPage()
        tabManager.tabs[tabIndex] = tab
        reloadCurrentPage()
    }

    /// Navigate to previous page
    func goToPreviousPage() {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count else { return }

        var tab = tabManager.tabs[tabIndex]
        guard tab.pagination.hasPreviousPage else { return }

        tab.pagination.goToPreviousPage()
        tabManager.tabs[tabIndex] = tab
        reloadCurrentPage()
    }

    /// Navigate to first page
    func goToFirstPage() {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count else { return }

        var tab = tabManager.tabs[tabIndex]
        guard tab.pagination.currentPage != 1 else { return }

        tab.pagination.goToFirstPage()
        tabManager.tabs[tabIndex] = tab
        reloadCurrentPage()
    }

    /// Navigate to last page
    func goToLastPage() {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count else { return }

        var tab = tabManager.tabs[tabIndex]
        guard tab.pagination.currentPage != tab.pagination.totalPages else { return }

        tab.pagination.goToLastPage()
        tabManager.tabs[tabIndex] = tab
        reloadCurrentPage()
    }

    /// Update page size (limit) and reload
    func updatePageSize(_ newSize: Int) {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count,
              newSize > 0 else { return }

        tabManager.tabs[tabIndex].pagination.updatePageSize(newSize)
        reloadCurrentPage()
    }

    /// Update offset and reload
    func updateOffset(_ newOffset: Int) {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count,
              newOffset >= 0 else { return }

        tabManager.tabs[tabIndex].pagination.updateOffset(newOffset)
        reloadCurrentPage()
    }

    /// Apply both limit and offset changes and reload
    func applyPaginationSettings() {
        reloadCurrentPage()
    }

    /// Reload current page data, guarding against unsaved changes
    func reloadCurrentPage() {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count,
              let tableName = tabManager.tabs[tabIndex].tableName else { return }

        let capturedTabIndex = tabIndex
        let capturedTableName = tableName
        confirmDiscardChangesIfNeeded(action: .pagination) { [weak self] confirmed in
            guard let self, confirmed else { return }
            guard capturedTabIndex < self.tabManager.tabs.count else { return }

            let tab = self.tabManager.tabs[capturedTabIndex]
            let pagination = tab.pagination

            let newQuery = self.queryBuilder.buildBaseQuery(
                tableName: capturedTableName,
                sortState: tab.sortState,
                columns: tab.resultColumns,
                limit: pagination.pageSize,
                offset: pagination.currentOffset
            )

            self.tabManager.tabs[capturedTabIndex].query = newQuery
            self.runQuery()
        }
    }
}
