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
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count,
              let tableName = tabManager.tabs[tabIndex].tableName else { return }

        let capturedTabIndex = tabIndex
        let capturedTableName = tableName
        let capturedFilters = filters
        confirmDiscardChangesIfNeeded(action: .filter) { [weak self] confirmed in
            guard let self, confirmed else { return }
            guard capturedTabIndex < self.tabManager.tabs.count else { return }

            // Reset pagination when filters change
            self.tabManager.tabs[capturedTabIndex].pagination.reset()

            let tab = self.tabManager.tabs[capturedTabIndex]
            let exclusions = self.columnExclusions(for: capturedTableName)
            let newQuery = self.queryBuilder.buildFilteredQuery(
                tableName: capturedTableName,
                filters: capturedFilters,
                logicMode: self.filterStateManager.filterLogicMode,
                sortState: tab.sortState,
                columns: tab.resultColumns,
                limit: tab.pagination.pageSize,
                offset: tab.pagination.currentOffset,
                columnExclusions: exclusions
            )

            self.tabManager.tabs[capturedTabIndex].query = newQuery

            if !capturedFilters.isEmpty {
                self.filterStateManager.saveLastFilters(for: capturedTableName)
            }

            // Persist filter state to tab so it survives tab switches
            self.tabManager.tabs[capturedTabIndex].filterState = self.filterStateManager.saveToTabState()

            self.runQuery()
        }
    }

    func clearFiltersAndReload() {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count,
              let tableName = tabManager.tabs[tabIndex].tableName else { return }

        let capturedTabIndex = tabIndex
        let capturedTableName = tableName
        confirmDiscardChangesIfNeeded(action: .filter) { [weak self] confirmed in
            guard let self, confirmed else { return }
            guard capturedTabIndex < self.tabManager.tabs.count else { return }

            let tab = self.tabManager.tabs[capturedTabIndex]
            let exclusions = self.columnExclusions(for: capturedTableName)
            let newQuery = self.queryBuilder.buildBaseQuery(
                tableName: capturedTableName,
                sortState: tab.sortState,
                columns: tab.resultColumns,
                limit: tab.pagination.pageSize,
                offset: tab.pagination.currentOffset,
                columnExclusions: exclusions
            )

            self.tabManager.tabs[capturedTabIndex].query = newQuery
            self.tabManager.tabs[capturedTabIndex].filterState = self.filterStateManager.saveToTabState()
            self.runQuery()
        }
    }

    func restoreFiltersForTable(_ tableName: String) {
        filterStateManager.restoreLastFilters(for: tableName)
        guard let idx = tabManager.selectedTabIndex else { return }
        tabManager.tabs[idx].filterState = filterStateManager.saveToTabState()
        if filterStateManager.hasAppliedFilters {
            rebuildTableQuery(at: idx)
        }
    }

    func rebuildTableQuery(at tabIndex: Int) {
        guard tabIndex < tabManager.tabs.count,
              let tableName = tabManager.tabs[tabIndex].tableName else { return }

        let tab = tabManager.tabs[tabIndex]
        let hasFilters = filterStateManager.hasAppliedFilters
        let exclusions = columnExclusions(for: tableName)

        let newQuery: String
        if hasFilters {
            newQuery = queryBuilder.buildFilteredQuery(
                tableName: tableName,
                filters: filterStateManager.appliedFilters,
                logicMode: filterStateManager.filterLogicMode,
                sortState: tab.sortState,
                columns: tab.resultColumns,
                limit: tab.pagination.pageSize,
                offset: tab.pagination.currentOffset,
                columnExclusions: exclusions
            )
        } else {
            newQuery = queryBuilder.buildBaseQuery(
                tableName: tableName,
                sortState: tab.sortState,
                columns: tab.resultColumns,
                limit: tab.pagination.pageSize,
                offset: tab.pagination.currentOffset,
                columnExclusions: exclusions
            )
        }

        tabManager.tabs[tabIndex].query = newQuery
    }
}
