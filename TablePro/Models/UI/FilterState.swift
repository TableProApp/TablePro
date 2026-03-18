//
//  FilterState.swift
//  TablePro
//
//  Manages the state of the filter panel
//

import Foundation
import Observation
import SwiftUI

/// Filter logic mode for combining multiple filters
enum FilterLogicMode: String, Codable {
    case and = "AND"
    case or = "OR"

    var displayName: String {
        rawValue
    }
}

/// Observable state manager for filter panel
@MainActor @Observable
final class FilterStateManager {
    var filters: [TableFilter] = []
    var isVisible: Bool = false
    var appliedFilters: [TableFilter] = []
    var focusedFilterId: UUID?
    var quickSearchText: String = ""
    var shouldFocusQuickSearch: Bool = false
    var filterLogicMode: FilterLogicMode = .and  // AND or OR logic

    /// Settings storage reference
    private let settingsStorage = FilterSettingsStorage.shared
    private let presetStorage = FilterPresetStorage.shared

    // MARK: - Filter Management

    /// Add a new empty filter with default settings
    func addFilter(columns: [String] = [], primaryKeyColumn: String? = nil) {
        let settings = settingsStorage.loadSettings()
        var newFilter = TableFilter()

        // Apply default column setting
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

        // Apply default operator setting
        newFilter.filterOperator = settings.defaultOperator.toFilterOperator()

        // New filters should be selected by default for "Apply All"
        newFilter.isSelected = true

        filters.append(newFilter)
        focusedFilterId = newFilter.id
    }

    /// Add a new filter with a specific column pre-selected (for context menu "Filter with column")
    func addFilterForColumn(_ columnName: String) {
        let settings = settingsStorage.loadSettings()
        var newFilter = TableFilter()

        // Set the specified column
        newFilter.columnName = columnName

        // Apply default operator setting
        newFilter.filterOperator = settings.defaultOperator.toFilterOperator()

        // New filters should be selected by default for "Apply All"
        newFilter.isSelected = true

        filters.append(newFilter)
        focusedFilterId = newFilter.id

        // Show panel if hidden
        if !isVisible {
            show()
        }
    }

    /// Set a single FK navigation filter, replacing all existing state.
    /// Used by FK navigation to apply an equality filter for the referenced column.
    func setFKFilter(_ filter: TableFilter) {
        filters = [filter]
        appliedFilters = [filter]
        isVisible = true
        quickSearchText = ""
        filterLogicMode = .and
    }

    /// Duplicate a filter
    func duplicateFilter(_ filter: TableFilter) {
        var copy = filter
        copy = TableFilter(
            id: UUID(),
            columnName: filter.columnName,
            filterOperator: filter.filterOperator,
            value: filter.value,
            secondValue: filter.secondValue,
            isSelected: false,
            isEnabled: filter.isEnabled,
            rawSQL: filter.rawSQL
        )

        if let index = filters.firstIndex(where: { $0.id == filter.id }) {
            filters.insert(copy, at: index + 1)
        } else {
            filters.append(copy)
        }
        focusedFilterId = copy.id
    }

    /// Remove a filter
    func removeFilter(_ filter: TableFilter) {
        filters.removeAll { $0.id == filter.id }

        // Also remove from applied filters if it was applied
        appliedFilters.removeAll { $0.id == filter.id }

        // If we removed the focused filter, focus the previous or next one
        if focusedFilterId == filter.id {
            focusedFilterId = filters.last?.id
        }
    }

    /// Update a filter
    func updateFilter(_ filter: TableFilter) {
        if let index = filters.firstIndex(where: { $0.id == filter.id }) {
            filters[index] = filter
        }
    }

    /// Get binding for a filter
    func binding(for filter: TableFilter) -> Binding<TableFilter> {
        Binding(
            get: { [weak self] in
                self?.filters.first { $0.id == filter.id } ?? filter
            },
            set: { [weak self] newValue in
                self?.updateFilter(newValue)
            }
        )
    }

    // MARK: - Apply Filters

    /// Apply a single filter
    func applySingleFilter(_ filter: TableFilter) {
        guard filter.isValid else { return }
        appliedFilters = [filter]
    }

    /// Apply all selected filters
    func applySelectedFilters() {
        appliedFilters = filters.filter { $0.isSelected && $0.isValid }
    }

    /// Apply all valid enabled filters
    func applyAllFilters() {
        appliedFilters = filters.filter { $0.isEnabled && $0.isValid }
    }

    /// Clear all applied filters (unset)
    func clearAppliedFilters() {
        appliedFilters = []
    }

    // MARK: - Panel Visibility

    /// Toggle filter panel visibility
    func toggle() {
        let willOpen = !isVisible
        isVisible.toggle()
        if willOpen {
            shouldFocusQuickSearch = true
        }
    }

    /// Show panel
    func show() {
        isVisible = true
        shouldFocusQuickSearch = true
    }

    /// Close panel
    func close() {
        isVisible = false
    }

    // MARK: - Selection

    /// Select/deselect all filters
    func selectAll(_ selected: Bool) {
        var updated = filters
        for i in 0..<updated.count {
            updated[i].isSelected = selected
        }
        filters = updated
    }

    /// Toggle selection for a filter
    func toggleSelection(_ filter: TableFilter) {
        if let index = filters.firstIndex(where: { $0.id == filter.id }) {
            filters[index].isSelected.toggle()
        }
    }

    /// Check if any filter is selected
    var hasSelectedFilters: Bool {
        filters.contains { $0.isSelected }
    }

    /// Check if all filters are selected
    var allFiltersSelected: Bool {
        !filters.isEmpty && filters.allSatisfy { $0.isSelected }
    }

    /// Check if filters are currently applied
    var hasAppliedFilters: Bool {
        !appliedFilters.isEmpty
    }

    /// Check if quick search is active
    var hasActiveQuickSearch: Bool {
        quickSearchText.contains(where: { !$0.isWhitespace })
    }

    /// Count of valid filters
    var validFilterCount: Int {
        filters.count(where: \.isValid)
    }

    // MARK: - State Persistence

    /// Save current filter state to tab
    func saveToTabState() -> TabFilterState {
        TabFilterState(
            filters: filters,
            appliedFilters: appliedFilters,
            isVisible: isVisible,
            quickSearchText: quickSearchText,
            filterLogicMode: filterLogicMode
        )
    }

    /// Restore filter state from tab
    func restoreFromTabState(_ state: TabFilterState) {
        filters = state.filters
        appliedFilters = state.appliedFilters
        isVisible = state.isVisible
        quickSearchText = state.quickSearchText
        filterLogicMode = state.filterLogicMode
    }

    /// Save filters for a table (for "Restore Last Filter" setting)
    func saveLastFilters(for tableName: String) {
        settingsStorage.saveLastFilters(filters, for: tableName)
    }

    /// Restore last filters for a table
    func restoreLastFilters(for tableName: String) {
        let settings = settingsStorage.loadSettings()
        if settings.panelState == .restoreLast {
            filters = settingsStorage.loadLastFilters(for: tableName)
            isVisible = !filters.isEmpty
        } else if settings.panelState == .alwaysShow {
            isVisible = true
        }
    }

    /// Clear all filters
    func clearAll() {
        filters = []
        appliedFilters = []
        focusedFilterId = nil
    }

    // MARK: - Focus Management

    /// Focus the next filter in the list
    func focusNextFilter() {
        guard let currentId = focusedFilterId,
              let currentIndex = filters.firstIndex(where: { $0.id == currentId }) else {
            focusedFilterId = filters.first?.id
            return
        }

        let nextIndex = (currentIndex + 1) % filters.count
        focusedFilterId = filters[nextIndex].id
    }

    /// Focus the previous filter in the list
    func focusPreviousFilter() {
        guard let currentId = focusedFilterId,
              let currentIndex = filters.firstIndex(where: { $0.id == currentId }) else {
            focusedFilterId = filters.last?.id
            return
        }

        let previousIndex = currentIndex > 0 ? currentIndex - 1 : filters.count - 1
        focusedFilterId = filters[previousIndex].id
    }

    /// Get the currently focused filter
    var focusedFilter: TableFilter? {
        guard let id = focusedFilterId else { return nil }
        return filters.first { $0.id == id }
    }

    // MARK: - Filter Presets

    /// Save current filters as a named preset
    func saveAsPreset(name: String) {
        let preset = FilterPreset(name: name, filters: filters)
        presetStorage.savePreset(preset)
    }

    /// Load filters from a preset
    func loadPreset(_ preset: FilterPreset) {
        filters = preset.filters
        // Auto-focus first filter if available
        focusedFilterId = filters.first?.id
    }

    /// Get all saved presets
    func loadAllPresets() -> [FilterPreset] {
        presetStorage.loadAllPresets()
    }

    /// Delete a preset
    func deletePreset(_ preset: FilterPreset) {
        presetStorage.deletePreset(preset)
    }

    // MARK: - Quick Search

    /// Clear quick search text
    func clearQuickSearch() {
        quickSearchText = ""
    }

    // MARK: - SQL Generation

    /// Generate preview SQL for the "SQL" button
    /// Uses selected filters if any are selected, otherwise uses all valid filters
    func generatePreviewSQL(databaseType: DatabaseType) -> String {
        guard let dialect = PluginManager.shared.sqlDialect(for: databaseType) else {
            return "-- Filters are applied natively"
        }
        let generator = FilterSQLGenerator(dialect: dialect)
        let filtersToPreview = getFiltersForPreview()

        // If no valid filters but filters exist, show helpful message
        if filtersToPreview.isEmpty && !filters.isEmpty {
            let invalidCount = filters.count(where: { !$0.isValid })
            if invalidCount > 0 {
                return "-- No valid filters to preview\n-- Complete \(invalidCount) filter(s) by:\n--   • Selecting a column\n--   • Entering a value (if required)\n--   • Filling in second value for BETWEEN"
            }
        }

        return generator.generateWhereClause(from: filtersToPreview, logicMode: filterLogicMode)
    }

    /// Get filters to use for preview/application
    /// If some (but not all) filters are selected, use only those
    /// Otherwise use all valid filters (single-pass)
    private func getFiltersForPreview() -> [TableFilter] {
        var valid: [TableFilter] = []
        var selectedValid: [TableFilter] = []
        for filter in filters where filter.isValid {
            valid.append(filter)
            if filter.isSelected { selectedValid.append(filter) }
        }
        // Only use selective mode when SOME (but not all) are selected
        if selectedValid.count == valid.count || selectedValid.isEmpty {
            return valid
        }
        return selectedValid
    }
}

// MARK: - TabFilterState Extension

extension TabFilterState {
    init(filters: [TableFilter], appliedFilters: [TableFilter], isVisible: Bool, quickSearchText: String, filterLogicMode: FilterLogicMode) {
        self.filters = filters
        self.appliedFilters = appliedFilters
        self.isVisible = isVisible
        self.quickSearchText = quickSearchText
        self.filterLogicMode = filterLogicMode
    }
}
