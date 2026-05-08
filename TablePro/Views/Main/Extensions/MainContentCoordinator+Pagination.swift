//
//  MainContentCoordinator+Pagination.swift
//  TablePro
//
//  Pagination operations for MainContentCoordinator
//

import Foundation

extension MainContentCoordinator {
    // MARK: - Pagination

    func goToNextPage() {
        paginateIfPossible(where: \.hasNextPage) { $0.goToNextPage() }
    }

    func goToPreviousPage() {
        paginateIfPossible(where: \.hasPreviousPage) { $0.goToPreviousPage() }
    }

    func goToFirstPage() {
        paginateIfPossible(where: \.hasPreviousPage) { $0.goToFirstPage() }
    }

    func goToLastPage() {
        paginateIfPossible(where: { $0.currentPage != $0.totalPages }) { $0.goToLastPage() }
    }

    func updatePageSize(_ newSize: Int) {
        guard newSize > 0 else { return }
        paginateIfPossible { $0.updatePageSize(newSize) }
    }

    func updateOffset(_ newOffset: Int) {
        guard newOffset >= 0 else { return }
        paginateIfPossible { $0.updateOffset(newOffset) }
    }

    func applyPaginationSettings() {
        reloadCurrentPage()
    }

    // MARK: - Private

    private func paginateIfPossible(
        where condition: (PaginationState) -> Bool = { _ in true },
        mutate: @escaping (inout PaginationState) -> Void
    ) {
        guard let (tab, tabIndex) = tabManager.selectedTabAndIndex,
              condition(tab.pagination) else { return }
        paginateAfterConfirmation(tabIndex: tabIndex, mutate: mutate)
    }

    private func paginateAfterConfirmation(
        tabIndex: Int,
        mutate: @escaping (inout PaginationState) -> Void
    ) {
        let tabId = tabManager.tabs[tabIndex].id
        confirmDiscardChangesIfNeeded(action: .pagination) { [weak self] confirmed in
            guard let self, confirmed else { return }
            guard self.tabManager.mutate(tabId: tabId, { tab in
                mutate(&tab.pagination)
                tab.paginationVersion += 1
            }) else { return }
            self.pendingScrollToTopAfterReplace.insert(tabId)
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
