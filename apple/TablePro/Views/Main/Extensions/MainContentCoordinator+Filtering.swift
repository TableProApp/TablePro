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

    var supportsColumnSort: Bool {
        services.pluginManager.supportsColumnSort(for: connection.type)
    }

    var supportsMatchAnyFilters: Bool {
        services.pluginManager.supportsMatchAnyFilters(for: connection.type)
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

    func handleSortStateChanged(_ newState: SortState) {
        guard let (tab, _) = tabManager.selectedTabAndIndex else { return }
        guard newState != tab.sortState else { return }

        if tab.tabType == .query {
            sortQueryResult(by: newState, tabId: tab.id)
            return
        }

        guard supportsColumnSort else { return }
        let tabId = tab.id
        let capturedSort = newState
        confirmDiscardChangesIfNeeded(action: .sort) { [weak self] confirmed in
            guard let self, confirmed else { return }
            guard self.tabManager.mutate(tabId: tabId, { tab in
                tab.sortState = capturedSort
                tab.hasUserInteraction = true
                tab.pagination.reset()
                // A header sort runs at once, so the filter panel's Sort By section shows it rather
                // than an edit made before it.
                tab.filterState.sortDraft = nil
            }) else { return }
            guard let tabIndex = self.tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
            self.rebuildTableQuery(at: tabIndex)
            self.runQuery(viewport: .firstRow)
        }
    }
}
