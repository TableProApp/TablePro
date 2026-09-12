//
//  MainContentCommandActions+PanelVisibility.swift
//  TablePro
//

import Foundation

/// Read-side of the panel toggles. Each one reads the same state its `toggle` writes,
/// so the menu title describes what the command will actually do.
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

/// The result's view mode, which the results header switches and the View menu mirrors.
///
/// The switcher used to be the only route to JSON and Chart mode, so those views were reachable by
/// mouse alone. A menu command is also what the HIG asks of any control that is not in the menu bar.
extension MainContentCommandActions {
    var resultsViewMode: ResultsViewMode? {
        coordinator?.tabManager.selectedTab?.display.resultsViewMode
    }

    /// Recomputed here rather than read off the status bar's snapshot, because the View menu has
    /// to validate while no status bar is on screen. Both call sites take the same inputs so the
    /// menu and the switcher can never disagree about whether Map is offered.
    var availableResultsViewModes: [ResultsViewMode] {
        guard let coordinator, let tab = coordinator.tabManager.selectedTab else { return [] }
        let tableRows = coordinator.tabSessionRegistry.existingTableRows(for: tab.id)
        return ResultsModeAvailability.modes(
            tabType: tab.tabType,
            hasTableName: tab.tableContext.tableName != nil,
            hasColumns: !(tableRows?.columns.isEmpty ?? true),
            hasSpatialColumn: tableRows.map(SpatialColumn.hasSpatialColumn(in:)) ?? false
        )
    }

    func setResultsViewMode(_ mode: ResultsViewMode) {
        guard let coordinator, let tabId = coordinator.tabManager.selectedTab?.id else { return }
        guard availableResultsViewModes.contains(mode) else { return }
        coordinator.tabManager.mutate(tabId: tabId) { $0.display.resultsViewMode = mode }
    }
}
