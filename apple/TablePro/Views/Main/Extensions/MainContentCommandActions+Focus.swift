//
//  MainContentCommandActions+Focus.swift
//  TablePro
//

import AppKit

internal extension MainContentCommandActions {
    // A collapsed result pane keeps its grid in the window, so focusing it unexpanded hands the keyboard to nothing.
    @discardableResult
    func focusActiveGrid() -> Bool {
        expandResultsIfCollapsed()
        return coordinator?.focusActiveGrid() ?? false
    }

    // Only a mounted grid can take the keyboard; a query tab with no result and every other result view have none.
    var canFocusActiveGrid: Bool {
        coordinator?.selectedTabGridModel?.isMounted == true
    }

    private func expandResultsIfCollapsed() {
        guard let coordinator,
              let (tab, tabIndex) = coordinator.tabManager.selectedTabAndIndex,
              tab.display.isResultsCollapsed else { return }
        coordinator.tabManager.mutate(at: tabIndex) { $0.display.isResultsCollapsed = false }
        coordinator.toolbarState.isResultsCollapsed = false
    }
}
