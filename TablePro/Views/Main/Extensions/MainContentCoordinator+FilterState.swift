//
//  MainContentCoordinator+FilterState.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    var selectedTabFilterState: TabFilterState {
        filterCoordinator.selectedTabFilterState
    }

    var currentTableName: String? {
        guard let tab = tabManager.selectedTab, tab.tabType == .table else { return nil }
        return tab.tableContext.tableName
    }

    func addFilterForColumn(_ columnName: String) {
        filterCoordinator.addFilterForColumn(columnName)
    }

    func applySingleFilter(_ filter: TableFilter) {
        filterCoordinator.applySingleFilter(filter)
    }

    func applyAllFilters() {
        filterCoordinator.applyAllFilters()
    }

    func applySoloFilter(_ filter: TableFilter) {
        filterCoordinator.applySoloFilter(filter)
    }

    var canFilterRows: Bool {
        filterCoordinator.canFilterRows
    }

    func applyCellFilter(_ filter: TableFilter, forTab tabId: UUID) {
        guard tabManager.selectedTab?.id == tabId else { return }
        filterCoordinator.applyCellFilter(filter)
    }

    func toggleFilterPanel() {
        filterCoordinator.toggleFilterPanel()
    }

    func showFilterPanel() {
        filterCoordinator.showFilterPanel()
    }

    func saveLastFilters(of tab: QueryTab) {
        filterCoordinator.saveLastFilters(of: tab)
    }

    func clearFilterState() {
        filterCoordinator.clearFilterState()
    }
}
