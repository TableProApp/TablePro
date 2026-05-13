//
//  FilterCoordinator.swift
//  TablePro
//

import Foundation
import os
import SwiftUI

private let filterStateLog = Logger(subsystem: "com.TablePro", category: "FilterState")

@MainActor @Observable
final class FilterCoordinator {
    @ObservationIgnored unowned let parent: MainContentCoordinator

    init(parent: MainContentCoordinator) {
        self.parent = parent
    }

    // MARK: - Filtering

    func applyFilters(_ filters: [TableFilter]) {
        guard let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex,
              let tableName = tab.tableContext.tableName else { return }

        let capturedTabIndex = tabIndex
        let capturedTableName = tableName
        let capturedFilters = filters
        parent.confirmDiscardChangesIfNeeded(action: .filter) { [weak self] confirmed in
            guard let self, confirmed else { return }
            guard capturedTabIndex < parent.tabManager.tabs.count else { return }

            parent.tabManager.mutate(at: capturedTabIndex) { $0.pagination.reset() }

            let tab = parent.tabManager.tabs[capturedTabIndex]
            let buffer = parent.tabSessionRegistry.tableRows(for: tab.id)
            let exclusions = parent.columnExclusions(for: capturedTableName)
            let newQuery = parent.queryBuilder.buildFilteredQuery(
                tableName: capturedTableName,
                filters: capturedFilters,
                logicMode: tab.filterState.filterLogicMode,
                sortState: tab.sortState,
                columns: buffer.columns,
                limit: tab.pagination.pageSize,
                offset: tab.pagination.currentOffset,
                columnExclusions: exclusions
            )

            parent.tabManager.mutate(at: capturedTabIndex) { $0.content.query = newQuery }

            if !capturedFilters.isEmpty {
                saveLastFilters(for: capturedTableName)
            }

            parent.runQuery()
        }
    }

    func clearFiltersAndReload() {
        guard let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex,
              let tableName = tab.tableContext.tableName else { return }

        let capturedTabIndex = tabIndex
        let capturedTableName = tableName
        parent.confirmDiscardChangesIfNeeded(action: .filter) { [weak self] confirmed in
            guard let self, confirmed else { return }
            guard capturedTabIndex < parent.tabManager.tabs.count else { return }

            let tab = parent.tabManager.tabs[capturedTabIndex]
            let buffer = parent.tabSessionRegistry.tableRows(for: tab.id)
            let exclusions = parent.columnExclusions(for: capturedTableName)
            let newQuery = parent.queryBuilder.buildBaseQuery(
                tableName: capturedTableName,
                sortState: tab.sortState,
                columns: buffer.columns,
                limit: tab.pagination.pageSize,
                offset: tab.pagination.currentOffset,
                columnExclusions: exclusions
            )

            parent.tabManager.mutate(at: capturedTabIndex) { $0.content.query = newQuery }
            parent.runQuery()
        }
    }

    func restoreFiltersForTable(_ tableName: String) {
        restoreLastFilters(for: tableName)
        guard let (_, tabIndex) = parent.tabManager.selectedTabAndIndex else { return }
        if parent.tabManager.tabs[tabIndex].filterState.hasAppliedFilters {
            rebuildTableQuery(at: tabIndex)
        }
    }

    func rebuildTableQuery(at tabIndex: Int) {
        guard tabIndex < parent.tabManager.tabs.count,
              let tableName = parent.tabManager.tabs[tabIndex].tableContext.tableName else { return }

        let tab = parent.tabManager.tabs[tabIndex]
        let buffer = parent.tabSessionRegistry.tableRows(for: tab.id)
        let hasFilters = tab.filterState.hasAppliedFilters
        let exclusions = parent.columnExclusions(for: tableName)

        let newQuery: String
        if hasFilters {
            newQuery = parent.queryBuilder.buildFilteredQuery(
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
            newQuery = parent.queryBuilder.buildBaseQuery(
                tableName: tableName,
                sortState: tab.sortState,
                columns: buffer.columns,
                limit: tab.pagination.pageSize,
                offset: tab.pagination.currentOffset,
                columnExclusions: exclusions
            )
        }

        parent.tabManager.mutate(at: tabIndex) { $0.content.query = newQuery }
    }

    // MARK: - Filter State

    var selectedTabFilterState: TabFilterState {
        parent.tabManager.selectedTab?.filterState ?? TabFilterState()
    }

    // MARK: - Filter Management

    func addFilter(columns: [String] = [], primaryKeyColumn: String? = nil) {
        let settings = FilterSettingsStorage.shared.loadSettings()
        var newFilter = TableFilter()

        switch settings.defaultColumn {
        case .rawSQL:
            newFilter.columnName = TableFilter.rawSQLColumn
        case .primaryKey:
            if let pk = primaryKeyColumn {
                newFilter.columnName = pk
            } else if let firstColumn = columns.first {
                newFilter.columnName = firstColumn
            }
        case .anyColumn:
            if let firstColumn = columns.first {
                newFilter.columnName = firstColumn
            }
        }

        newFilter.filterOperator = settings.defaultOperator.toFilterOperator()
        newFilter.isSelected = true

        mutateSelectedTabFilterState { state in
            state.filters.append(newFilter)
        }
    }

    func addFilterForColumn(_ columnName: String) {
        let settings = FilterSettingsStorage.shared.loadSettings()
        var newFilter = TableFilter()
        newFilter.columnName = columnName
        newFilter.filterOperator = settings.defaultOperator.toFilterOperator()
        newFilter.isSelected = true

        mutateSelectedTabFilterState { state in
            state.filters.append(newFilter)
            if !state.isVisible {
                state.isVisible = true
            }
        }
    }

    func setFKFilter(_ filter: TableFilter) {
        mutateSelectedTabFilterState { state in
            state.filters = [filter]
            state.appliedFilters = [filter]
            state.isVisible = true
            state.filterLogicMode = .and
        }
    }

    func duplicateFilter(_ filter: TableFilter) {
        let copy = TableFilter(
            id: UUID(),
            columnName: filter.columnName,
            filterOperator: filter.filterOperator,
            value: filter.value,
            secondValue: filter.secondValue,
            isSelected: true,
            isEnabled: filter.isEnabled,
            rawSQL: filter.rawSQL
        )
        mutateSelectedTabFilterState { state in
            if let index = state.filters.firstIndex(where: { $0.id == filter.id }) {
                state.filters.insert(copy, at: index + 1)
            } else {
                state.filters.append(copy)
            }
        }
    }

    func removeFilter(_ filter: TableFilter) {
        mutateSelectedTabFilterState { state in
            state.filters.removeAll { $0.id == filter.id }
            state.appliedFilters.removeAll { $0.id == filter.id }
        }
    }

    func updateFilter(_ filter: TableFilter) {
        mutateSelectedTabFilterState { state in
            if let index = state.filters.firstIndex(where: { $0.id == filter.id }) {
                state.filters[index] = filter
            }
        }
    }

    func filterBinding(for filter: TableFilter) -> Binding<TableFilter> {
        Binding(
            get: { [weak self] in
                self?.selectedTabFilterState.filters.first { $0.id == filter.id } ?? filter
            },
            set: { [weak self] newValue in
                self?.updateFilter(newValue)
            }
        )
    }

    func filterLogicModeBinding() -> Binding<FilterLogicMode> {
        Binding(
            get: { [weak self] in
                self?.selectedTabFilterState.filterLogicMode ?? .and
            },
            set: { [weak self] newValue in
                self?.mutateSelectedTabFilterState { $0.filterLogicMode = newValue }
            }
        )
    }

    // MARK: - Apply

    func applySingleFilter(_ filter: TableFilter) {
        guard filter.isValid else { return }
        mutateSelectedTabFilterState { state in
            state.filters = [filter]
            state.appliedFilters = [filter]
            state.isVisible = true
        }
    }

    func applySelectedFilters() {
        mutateSelectedTabFilterState { state in
            state.appliedFilters = state.filters.filter { $0.isSelected && $0.isValid }
        }
    }

    func applyAllFilters() {
        mutateSelectedTabFilterState { state in
            state.appliedFilters = state.filters.filter { $0.isEnabled && $0.isValid }
        }
    }

    func clearAppliedFilters() {
        mutateSelectedTabFilterState { state in
            state.appliedFilters = []
        }
    }

    // MARK: - Panel Visibility

    func toggleFilterPanel() {
        withAnimation(.easeInOut(duration: 0.15)) {
            mutateSelectedTabFilterState { state in
                state.isVisible.toggle()
            }
        }
    }

    func showFilterPanel() {
        withAnimation(.easeInOut(duration: 0.15)) {
            mutateSelectedTabFilterState { state in
                state.isVisible = true
            }
        }
    }

    func closeFilterPanel() {
        withAnimation(.easeInOut(duration: 0.15)) {
            mutateSelectedTabFilterState { state in
                state.isVisible = false
            }
        }
    }

    // MARK: - Selection

    func selectAllFilters(_ selected: Bool) {
        mutateSelectedTabFilterState { state in
            for index in 0..<state.filters.count {
                state.filters[index].isSelected = selected
            }
        }
    }

    func toggleFilterSelection(_ filter: TableFilter) {
        mutateSelectedTabFilterState { state in
            if let index = state.filters.firstIndex(where: { $0.id == filter.id }) {
                state.filters[index].isSelected.toggle()
            }
        }
    }

    // MARK: - Persistence

    func saveLastFiltersForActiveTable() {
        guard let tab = parent.tabManager.selectedTab,
              let tableName = tab.tableContext.tableName else { return }
        FilterSettingsStorage.shared.saveLastFilters(
            tab.filterState.appliedFilters,
            for: tableName
        )
    }

    func saveLastFilters(for tableName: String) {
        guard let tab = parent.tabManager.selectedTab else { return }
        FilterSettingsStorage.shared.saveLastFilters(
            tab.filterState.appliedFilters,
            for: tableName
        )
    }

    func restoreLastFilters(for tableName: String) {
        let settings = FilterSettingsStorage.shared.loadSettings()
        mutateSelectedTabFilterState { state in
            if settings.panelState == .restoreLast {
                let restored = FilterSettingsStorage.shared.loadLastFilters(for: tableName)
                if !restored.isEmpty {
                    state.filters = restored
                    state.appliedFilters = restored
                }
            }
            if settings.panelState == .alwaysShow {
                state.isVisible = true
            }
        }
    }

    func clearFilterState() {
        mutateSelectedTabFilterState { state in
            state.isVisible = false
            state.filters = []
            state.appliedFilters = []
        }
    }

    // MARK: - Filter Presets

    func saveFilterPreset(name: String) {
        let preset = FilterPreset(name: name, filters: selectedTabFilterState.filters)
        FilterPresetStorage.shared.savePreset(preset)
    }

    func loadFilterPreset(_ preset: FilterPreset) {
        mutateSelectedTabFilterState { state in
            state.filters = preset.filters
        }
    }

    func loadAllFilterPresets() -> [FilterPreset] {
        FilterPresetStorage.shared.loadAllPresets()
    }

    func deleteFilterPreset(_ preset: FilterPreset) {
        FilterPresetStorage.shared.deletePreset(preset)
    }

    // MARK: - SQL Preview

    func generateFilterPreviewSQL(databaseType: DatabaseType) -> String {
        let state = selectedTabFilterState
        guard let dialect = PluginManager.shared.sqlDialect(for: databaseType) else {
            return "-- Filters are applied natively"
        }
        let generator = FilterSQLGenerator(dialect: dialect)
        let filtersToPreview = filtersForPreview(in: state)

        if filtersToPreview.isEmpty && !state.filters.isEmpty {
            let invalidCount = state.filters.count(where: { !$0.isValid })
            if invalidCount > 0 {
                return "-- No valid filters to preview\n-- Complete \(invalidCount) filter(s) by:\n--   • Selecting a column\n--   • Entering a value (if required)\n--   • Filling in second value for BETWEEN"
            }
        }

        return generator.generateWhereClause(from: filtersToPreview, logicMode: state.filterLogicMode)
    }

    private func filtersForPreview(in state: TabFilterState) -> [TableFilter] {
        var valid: [TableFilter] = []
        var selectedValid: [TableFilter] = []
        for filter in state.filters where filter.isEnabled && filter.isValid {
            valid.append(filter)
            if filter.isSelected { selectedValid.append(filter) }
        }
        if selectedValid.count == valid.count || selectedValid.isEmpty {
            return valid
        }
        return selectedValid
    }

    // MARK: - Private

    private func mutateSelectedTabFilterState(_ mutate: (inout TabFilterState) -> Void) {
        guard let index = parent.tabManager.selectedTabIndex else { return }
        var newState = parent.tabManager.tabs[index].filterState
        mutate(&newState)
        parent.tabManager.mutate(at: index) { $0.filterState = newState }
        let tabId = parent.tabManager.tabs[index].id
        if let session = parent.tabSessionRegistry.session(for: tabId) {
            session.filterState = newState
        } else {
            filterStateLog.error(
                "TabSession missing for selected tab \(tabId, privacy: .public); QueryTab updated but session mirror skipped"
            )
            assertionFailure("TabSession missing for selected tab: registry sync regression")
        }
    }
}
