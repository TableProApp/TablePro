//
//  MainContentCoordinator+Filtering.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    func applyFilters(_ filters: [TableFilter]) {
        filterCoordinator.applyFilters(filters)
    }

    func clearFiltersAndReload() {
        filterCoordinator.clearFiltersAndReload()
    }

    func restoreFiltersForTable(_ tableName: String) {
        filterCoordinator.restoreFiltersForTable(tableName)
    }

    func rebuildTableQuery(at tabIndex: Int) {
        filterCoordinator.rebuildTableQuery(at: tabIndex)
    }
}
