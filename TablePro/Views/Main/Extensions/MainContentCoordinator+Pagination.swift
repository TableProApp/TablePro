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
              tabIndex < tabManager.tabs.count,
              tabManager.tabs[tabIndex].pagination.hasNextPage else { return }

        paginateAfterConfirmation(tabIndex: tabIndex) { pagination in
            pagination.goToNextPage()
        }
    }

    /// Navigate to previous page
    func goToPreviousPage() {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count,
              tabManager.tabs[tabIndex].pagination.hasPreviousPage else { return }

        paginateAfterConfirmation(tabIndex: tabIndex) { pagination in
            pagination.goToPreviousPage()
        }
    }

    /// Navigate to first page
    func goToFirstPage() {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count,
              tabManager.tabs[tabIndex].pagination.currentPage != 1 else { return }

        paginateAfterConfirmation(tabIndex: tabIndex) { pagination in
            pagination.goToFirstPage()
        }
    }

    /// Navigate to last page
    func goToLastPage() {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count else { return }

        let tab = tabManager.tabs[tabIndex]
        guard tab.pagination.currentPage != tab.pagination.totalPages else { return }

        paginateAfterConfirmation(tabIndex: tabIndex) { pagination in
            pagination.goToLastPage()
        }
    }

    /// Update page size (limit) and reload
    func updatePageSize(_ newSize: Int) {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count,
              newSize > 0 else { return }

        paginateAfterConfirmation(tabIndex: tabIndex) { pagination in
            pagination.updatePageSize(newSize)
        }
    }

    /// Update offset and reload
    func updateOffset(_ newOffset: Int) {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count,
              newOffset >= 0 else { return }

        paginateAfterConfirmation(tabIndex: tabIndex) { pagination in
            pagination.updateOffset(newOffset)
        }
    }

    /// Apply both limit and offset changes and reload
    func applyPaginationSettings() {
        reloadCurrentPage()
    }

    // MARK: - Private

    /// Confirm discard if needed, then mutate pagination state and reload.
    private func paginateAfterConfirmation(
        tabIndex: Int,
        mutate: @escaping (inout PaginationState) -> Void
    ) {
        let tabId = tabManager.tabs[tabIndex].id
        confirmDiscardChangesIfNeeded(action: .pagination) { [weak self] confirmed in
            guard let self, confirmed else { return }
            guard let idx = self.tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }

            mutate(&self.tabManager.tabs[idx].pagination)
            self.tabManager.tabs[idx].paginationVersion += 1
            self.reloadCurrentPage()
        }
    }

    private func reloadCurrentPage() {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count else { return }

        rebuildTableQuery(at: tabIndex)
        runQuery()
    }
}
