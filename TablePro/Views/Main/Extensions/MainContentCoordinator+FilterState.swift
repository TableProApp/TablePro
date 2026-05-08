//
//  MainContentCoordinator+FilterState.swift
//  TablePro
//

import Foundation
import os
import SwiftUI

private let filterStateLog = Logger(subsystem: "com.TablePro", category: "FilterState")

extension MainContentCoordinator {
    var selectedTabFilterState: TabFilterState {
        tabManager.selectedTab?.filterState ?? TabFilterState()
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
        guard let tab = tabManager.selectedTab,
              let tableName = tab.tableContext.tableName else { return }
        FilterSettingsStorage.shared.saveLastFilters(
            tab.filterState.appliedFilters,
            for: tableName
        )
    }

    func saveLastFilters(for tableName: String) {
        guard let tab = tabManager.selectedTab else { return }
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
        guard let index = tabManager.selectedTabIndex else { return }
        var state = tabManager.tabs[index].filterState
        mutate(&state)
        tabManager.tabs[index].filterState = state
        let tabId = tabManager.tabs[index].id
        if let session = tabSessionRegistry.session(for: tabId) {
            session.filterState = state
        } else {
            filterStateLog.error(
                "TabSession missing for selected tab \(tabId, privacy: .public); QueryTab updated but session mirror skipped"
            )
            assertionFailure("TabSession missing for selected tab: registry sync regression")
        }
    }
}
