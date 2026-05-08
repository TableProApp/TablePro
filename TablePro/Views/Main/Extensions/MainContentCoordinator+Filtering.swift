//
//  MainContentCoordinator+Filtering.swift
//  TablePro
//
//  Filtering operations for MainContentCoordinator
//

import Foundation

extension MainContentCoordinator {
    // MARK: - Filtering

    func applyFilters(_ filters: [TableFilter]) {
        guard let (tab, tabIndex) = tabManager.selectedTabAndIndex,
              let tableName = tab.tableContext.tableName else { return }

        let capturedTabIndex = tabIndex
        let capturedTableName = tableName
        let capturedFilters = filters
        confirmDiscardChangesIfNeeded(action: .filter) { [weak self] confirmed in
            guard let self, confirmed else { return }
            guard capturedTabIndex < self.tabManager.tabs.count else { return }

            self.tabManager.mutate(at: capturedTabIndex) { $0.pagination.reset() }

            let tab = self.tabManager.tabs[capturedTabIndex]
            let buffer = self.tabSessionRegistry.tableRows(for: tab.id)
            let exclusions = self.columnExclusions(for: capturedTableName)
            let newQuery = self.queryBuilder.buildFilteredQuery(
                tableName: capturedTableName,
                filters: capturedFilters,
                logicMode: tab.filterState.filterLogicMode,
                sortState: tab.sortState,
                columns: buffer.columns,
                limit: tab.pagination.pageSize,
                offset: tab.pagination.currentOffset,
                columnExclusions: exclusions
            )

            self.tabManager.mutate(at: capturedTabIndex) { $0.content.query = newQuery }

            if !capturedFilters.isEmpty {
                self.saveLastFilters(for: capturedTableName)
            }

            self.runQuery()
        }
    }

    func clearFiltersAndReload() {
        guard let (tab, tabIndex) = tabManager.selectedTabAndIndex,
              let tableName = tab.tableContext.tableName else { return }

        let capturedTabIndex = tabIndex
        let capturedTableName = tableName
        confirmDiscardChangesIfNeeded(action: .filter) { [weak self] confirmed in
            guard let self, confirmed else { return }
            guard capturedTabIndex < self.tabManager.tabs.count else { return }

            let tab = self.tabManager.tabs[capturedTabIndex]
            let buffer = self.tabSessionRegistry.tableRows(for: tab.id)
            let exclusions = self.columnExclusions(for: capturedTableName)
            let newQuery = self.queryBuilder.buildBaseQuery(
                tableName: capturedTableName,
                sortState: tab.sortState,
                columns: buffer.columns,
                limit: tab.pagination.pageSize,
                offset: tab.pagination.currentOffset,
                columnExclusions: exclusions
            )

            self.tabManager.mutate(at: capturedTabIndex) { $0.content.query = newQuery }
            self.runQuery()
        }
    }

    func restoreFiltersForTable(_ tableName: String) {
        restoreLastFilters(for: tableName)
        guard let (_, tabIndex) = tabManager.selectedTabAndIndex else { return }
        if tabManager.tabs[tabIndex].filterState.hasAppliedFilters {
            rebuildTableQuery(at: tabIndex)
        }
    }

    func rebuildTableQuery(at tabIndex: Int) {
        guard tabIndex < tabManager.tabs.count,
              let tableName = tabManager.tabs[tabIndex].tableContext.tableName else { return }

        let tab = tabManager.tabs[tabIndex]
        let buffer = tabSessionRegistry.tableRows(for: tab.id)
        let hasFilters = tab.filterState.hasAppliedFilters
        let exclusions = columnExclusions(for: tableName)

        let newQuery: String
        if hasFilters {
            newQuery = queryBuilder.buildFilteredQuery(
                tableName: tableName,
                filters: tab.filterState.appliedFilters,
                logicMode: tab.filterState.filterLogicMode,
                sortState: tab.sortState,
                columns: buffer.columns,
                limit: tab.pagination.pageSize,
                offset: tab.pagination.currentOffset,
                columnExclusions: exclusions
            )
        } else {
            newQuery = queryBuilder.buildBaseQuery(
                tableName: tableName,
                sortState: tab.sortState,
                columns: buffer.columns,
                limit: tab.pagination.pageSize,
                offset: tab.pagination.currentOffset,
                columnExclusions: exclusions
            )
        }

        tabManager.mutate(at: tabIndex) { $0.content.query = newQuery }
    }
}
