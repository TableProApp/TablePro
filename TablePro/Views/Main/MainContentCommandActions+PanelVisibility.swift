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
