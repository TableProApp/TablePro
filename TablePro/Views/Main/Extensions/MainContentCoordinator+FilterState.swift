//
//  MainContentCoordinator+FilterState.swift
//  TablePro
//

import Foundation
import SwiftUI

extension MainContentCoordinator {
    var selectedTabFilterState: TabFilterState {
        filterCoordinator.selectedTabFilterState
    }

    func addFilter(columns: [String] = [], primaryKeyColumn: String? = nil) {
        filterCoordinator.addFilter(columns: columns, primaryKeyColumn: primaryKeyColumn)
    }

    func addFilterForColumn(_ columnName: String) {
        filterCoordinator.addFilterForColumn(columnName)
    }

    func setFKFilter(_ filter: TableFilter) {
        filterCoordinator.setFKFilter(filter)
    }

    func duplicateFilter(_ filter: TableFilter) {
        filterCoordinator.duplicateFilter(filter)
    }

    func removeFilter(_ filter: TableFilter) {
        filterCoordinator.removeFilter(filter)
    }

    func updateFilter(_ filter: TableFilter) {
        filterCoordinator.updateFilter(filter)
    }

    func filterBinding(for filter: TableFilter) -> Binding<TableFilter> {
        filterCoordinator.filterBinding(for: filter)
    }

    func filterLogicModeBinding() -> Binding<FilterLogicMode> {
        filterCoordinator.filterLogicModeBinding()
    }

    func applySingleFilter(_ filter: TableFilter) {
        filterCoordinator.applySingleFilter(filter)
    }

    func applySelectedFilters() {
        filterCoordinator.applySelectedFilters()
    }

    func applyAllFilters() {
        filterCoordinator.applyAllFilters()
    }

    func clearAppliedFilters() {
        filterCoordinator.clearAppliedFilters()
    }

    func toggleFilterPanel() {
        filterCoordinator.toggleFilterPanel()
    }

    func showFilterPanel() {
        filterCoordinator.showFilterPanel()
    }

    func closeFilterPanel() {
        filterCoordinator.closeFilterPanel()
    }

    func selectAllFilters(_ selected: Bool) {
        filterCoordinator.selectAllFilters(selected)
    }

    func toggleFilterSelection(_ filter: TableFilter) {
        filterCoordinator.toggleFilterSelection(filter)
    }

    func saveLastFiltersForActiveTable() {
        filterCoordinator.saveLastFiltersForActiveTable()
    }

    func saveLastFilters(for tableName: String) {
        filterCoordinator.saveLastFilters(for: tableName)
    }

    func restoreLastFilters(for tableName: String) {
        filterCoordinator.restoreLastFilters(for: tableName)
    }

    func clearFilterState() {
        filterCoordinator.clearFilterState()
    }

    func saveFilterPreset(name: String) {
        filterCoordinator.saveFilterPreset(name: name)
    }

    func loadFilterPreset(_ preset: FilterPreset) {
        filterCoordinator.loadFilterPreset(preset)
    }

    func loadAllFilterPresets() -> [FilterPreset] {
        filterCoordinator.loadAllFilterPresets()
    }

    func deleteFilterPreset(_ preset: FilterPreset) {
        filterCoordinator.deleteFilterPreset(preset)
    }

    func generateFilterPreviewSQL(databaseType: DatabaseType) -> String {
        filterCoordinator.generateFilterPreviewSQL(databaseType: databaseType)
    }
}
