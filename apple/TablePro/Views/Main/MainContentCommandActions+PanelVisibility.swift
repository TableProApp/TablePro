//
//  MainContentCommandActions+PanelVisibility.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// Each reads the state its toggle writes, so the menu title matches what the command does.
extension MainContentCommandActions {
    var isFilterBarVisible: Bool {
        guard let coordinator, let index = coordinator.tabManager.selectedTabIndex else { return false }
        return coordinator.tabManager.tabs[index].filterState.isVisible
    }

    var isQueryHistoryVisible: Bool {
        guard let connectionId = coordinator?.connectionId else { return false }
        return HistoryPanelState.forConnection(connectionId).isVisible
    }

    var isResultsVisible: Bool {
        guard let coordinator, let index = coordinator.tabManager.selectedTabIndex else { return false }
        return !coordinator.tabManager.tabs[index].display.isResultsCollapsed
    }
}

// The switcher was the only route to JSON and Chart; the HIG wants a menu command for any control not in the menu bar.
extension MainContentCommandActions {
    var resultsViewMode: ResultsViewMode? {
        coordinator?.tabManager.selectedTab?.display.resultsViewMode
    }

    // Recomputed, not read from the status bar: the View menu validates while no status bar is on screen.
    var availableResultsViewModes: [ResultsViewMode] {
        guard let coordinator, let tab = coordinator.tabManager.selectedTab else { return [] }
        let tableRows = coordinator.tabSessionRegistry.existingTableRows(for: tab.id)
        return ResultsModeAvailability.modes(
            tabType: tab.tabType,
            hasTableName: tab.tableContext.tableName != nil,
            hasColumns: !(tableRows?.columns.isEmpty ?? true),
            hasSpatialColumn: !tab.display.spatialColumns.isEmpty,
            hasServerOutput: !(tab.display.activeResultSet?.serverOutput.isEmpty ?? true)
        )
    }

    func setResultsViewMode(_ mode: ResultsViewMode) {
        guard let coordinator, let tabId = coordinator.tabManager.selectedTab?.id else { return }
        guard availableResultsViewModes.contains(mode) else { return }
        coordinator.commitActiveGridEdit()
        coordinator.tabManager.mutate(tabId: tabId) { $0.display.resultsViewMode = mode }
    }
}
