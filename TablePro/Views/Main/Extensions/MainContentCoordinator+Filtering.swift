//
//  MainContentCoordinator+Filtering.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension MainContentCoordinator {
    func applyFilters(_ filters: [TableFilter]) {
        filterCoordinator.applyFilters(filters)
    }

    func clearFiltersAndReload() {
        filterCoordinator.clearFiltersAndReload()
    }

    var browseFilterDescriptor: BrowseFilterDescriptor? {
        PluginManager.shared.browseFilterDescriptor(for: connection.type)
    }

    func applyBrowseSearch(_ search: BrowseSearchState) {
        filterCoordinator.applyBrowseSearch(search)
    }

    func clearBrowseSearchAndReload() {
        filterCoordinator.clearBrowseSearchAndReload()
    }

    func restoreFiltersForTable(_ tableName: String) {
        filterCoordinator.restoreFiltersForTable(tableName)
    }

    func rebuildTableQuery(at tabIndex: Int) {
        filterCoordinator.rebuildTableQuery(at: tabIndex)
    }
}
