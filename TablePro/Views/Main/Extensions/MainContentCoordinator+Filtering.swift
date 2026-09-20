//
//  MainContentCoordinator+Filtering.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension MainContentCoordinator {
    func clearAppliedFiltersAndReload() {
        filterCoordinator.clearAppliedFiltersAndReload()
    }

    func removeAllFiltersAndReload() {
        filterCoordinator.removeAllFiltersAndReload()
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

    func restoreFiltersForSelectedTab() {
        filterCoordinator.restoreFiltersForSelectedTab()
    }

    func restoreFilters(forTabAt index: Int) {
        filterCoordinator.restoreFilters(forTabAt: index)
    }

    func rebuildTableQuery(at tabIndex: Int) {
        filterCoordinator.rebuildTableQuery(at: tabIndex)
    }
}
