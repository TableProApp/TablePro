//
//  MainContentCoordinator+Filtering.swift
//  TablePro
//
//  Filtering and search operations for MainContentCoordinator
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
            let newQuery: String

            // Combine with quick search if active
            if self.filterStateManager.hasActiveQuickSearch {
                newQuery = self.queryBuilder.buildCombinedQuery(
                    tableName: capturedTableName,
                    filters: capturedFilters,
                    logicMode: self.filterStateManager.filterLogicMode,
                    searchText: self.filterStateManager.quickSearchText,
                    searchColumns: tab.resultColumns,
                    sortState: tab.sortState,
                    columns: tab.resultColumns,
                    limit: tab.pagination.pageSize,
                    offset: tab.pagination.currentOffset
                )
            } else {
                newQuery = self.queryBuilder.buildFilteredQuery(
                    tableName: capturedTableName,
                    filters: capturedFilters,
                    logicMode: self.filterStateManager.filterLogicMode,
                    sortState: tab.sortState,
                    columns: tab.resultColumns,
                    limit: tab.pagination.pageSize,
                    offset: tab.pagination.currentOffset
                )
            }

            self.tabManager.tabs[capturedTabIndex].query = newQuery

            if !capturedFilters.isEmpty {
                self.filterStateManager.saveLastFilters(for: capturedTableName)
            }

            // Persist filter state to tab so it survives tab switches
            self.tabManager.tabs[capturedTabIndex].filterState = self.filterStateManager.saveToTabState()

            self.runQuery()
        }
    }

    func applyQuickSearch(_ searchText: String) {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count,
              let tableName = tabManager.tabs[tabIndex].tableName,
              !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        let capturedTabIndex = tabIndex
        let capturedTableName = tableName
        let capturedSearchText = searchText
        confirmDiscardChangesIfNeeded(action: .filter) { [weak self] confirmed in
            guard let self, confirmed else { return }
            guard capturedTabIndex < self.tabManager.tabs.count else { return }

            // Reset pagination when search changes
            self.tabManager.tabs[capturedTabIndex].pagination.reset()

            let tab = self.tabManager.tabs[capturedTabIndex]
            let newQuery: String

            // Combine with applied filters if present
            if self.filterStateManager.hasAppliedFilters {
                newQuery = self.queryBuilder.buildCombinedQuery(
                    tableName: capturedTableName,
                    filters: self.filterStateManager.appliedFilters,
                    logicMode: self.filterStateManager.filterLogicMode,
                    searchText: capturedSearchText,
                    searchColumns: tab.resultColumns,
                    sortState: tab.sortState,
                    columns: tab.resultColumns,
                    limit: tab.pagination.pageSize,
                    offset: tab.pagination.currentOffset
                )
            } else {
                newQuery = self.queryBuilder.buildQuickSearchQuery(
                    tableName: capturedTableName,
                    searchText: capturedSearchText,
                    columns: tab.resultColumns,
                    sortState: tab.sortState,
                    limit: tab.pagination.pageSize,
                    offset: tab.pagination.currentOffset
                )
            }

            self.tabManager.tabs[capturedTabIndex].query = newQuery
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
            let newQuery: String

            // Preserve active quick search when clearing filter rows
            if self.filterStateManager.hasActiveQuickSearch {
                newQuery = self.queryBuilder.buildQuickSearchQuery(
                    tableName: capturedTableName,
                    searchText: self.filterStateManager.quickSearchText,
                    columns: tab.resultColumns,
                    sortState: tab.sortState,
                    limit: tab.pagination.pageSize,
                    offset: tab.pagination.currentOffset
                )
            } else {
                newQuery = self.queryBuilder.buildBaseQuery(
                    tableName: capturedTableName,
                    sortState: tab.sortState,
                    columns: tab.resultColumns,
                    limit: tab.pagination.pageSize,
                    offset: tab.pagination.currentOffset
                )
            }

            self.tabManager.tabs[capturedTabIndex].query = newQuery
            self.tabManager.tabs[capturedTabIndex].filterState = self.filterStateManager.saveToTabState()
            self.runQuery()
        }
    }

    func rebuildTableQuery(at tabIndex: Int) {
        guard tabIndex < tabManager.tabs.count,
              let tableName = tabManager.tabs[tabIndex].tableName else { return }

        let tab = tabManager.tabs[tabIndex]
        let hasFilters = filterStateManager.hasAppliedFilters
        let hasSearch = filterStateManager.hasActiveQuickSearch

        let newQuery: String
        if hasFilters && hasSearch {
            newQuery = queryBuilder.buildCombinedQuery(
                tableName: tableName,
                filters: filterStateManager.appliedFilters,
                logicMode: filterStateManager.filterLogicMode,
                searchText: filterStateManager.quickSearchText,
                searchColumns: tab.resultColumns,
                sortState: tab.sortState,
                columns: tab.resultColumns,
                limit: tab.pagination.pageSize,
                offset: tab.pagination.currentOffset
            )
        } else if hasFilters {
            newQuery = queryBuilder.buildFilteredQuery(
                tableName: tableName,
                filters: filterStateManager.appliedFilters,
                logicMode: filterStateManager.filterLogicMode,
                sortState: tab.sortState,
                columns: tab.resultColumns,
                limit: tab.pagination.pageSize,
                offset: tab.pagination.currentOffset
            )
        } else if hasSearch {
            newQuery = queryBuilder.buildQuickSearchQuery(
                tableName: tableName,
                searchText: filterStateManager.quickSearchText,
                columns: tab.resultColumns,
                sortState: tab.sortState,
                limit: tab.pagination.pageSize,
                offset: tab.pagination.currentOffset
            )
        } else {
            newQuery = queryBuilder.buildBaseQuery(
                tableName: tableName,
                sortState: tab.sortState,
                columns: tab.resultColumns,
                limit: tab.pagination.pageSize,
                offset: tab.pagination.currentOffset
            )
        }

        tabManager.tabs[tabIndex].query = newQuery
    }
}
