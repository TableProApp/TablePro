//
//  MainSplitViewController+ViewMenuActions.swift
//  TablePro
//

import AppKit

extension MainSplitViewController {
    @objc func toggleWorkspaceRail(_ sender: Any?) {
        toggleWorkspaceRail()
    }

    /// Switching which connection the window shows is the window's own business, so it acts on the
    /// registry directly the way `toggleWorkspaceRail(_:)` already does. Routing it through the
    /// selected connection's `commandActions` made it a no-op exactly when it was needed: that
    /// connection losing its session is what leaves the others unreachable.
    @objc func showPreviousWorkspace(_ sender: Any?) {
        activateWorkspace(offsetBy: -1)
    }

    @objc func showNextWorkspace(_ sender: Any?) {
        activateWorkspace(offsetBy: 1)
    }

    @objc func setResultView(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
              let mode = ResultsViewMode(rawValue: raw) else { return }
        commandActions?.setResultsViewMode(mode)
    }

    /// The mode's menu equivalent. Until these, the toolbar's segmented control was the only way to
    /// switch a window between Browse and Assistant: there was no menu item and no shortcut, so a
    /// user whose window was narrow enough to push the control into the overflow, or who works from
    /// the keyboard, had no route the HIG expects every command to have.
    @objc func useBrowseMode(_ sender: Any?) {
        setContentMode(.browse)
    }

    @objc func useAssistantMode(_ sender: Any?) {
        setContentMode(.assistant)
    }

    @objc func useFlatSidebarLayout(_ sender: Any?) {
        commandActions?.setSidebarLayout(.flat)
    }

    @objc func useTreeSidebarLayout(_ sender: Any?) {
        commandActions?.setSidebarLayout(.tree)
    }

    @objc func focusSidebarFilter(_ sender: Any?) {
        commandActions?.focusSidebarSearch()
    }

    @objc func filterDatabases(_ sender: Any?) {
        presentDatabaseFilter()
    }

    @objc func showAllDatabases(_ sender: Any?) {
        clearDatabaseFilter()
    }

    @objc func toggleFilterBar(_ sender: Any?) {
        commandActions?.toggleFilterPanel()
    }

    @objc func toggleQueryHistory(_ sender: Any?) {
        commandActions?.toggleHistoryPanel()
    }

    @objc func toggleResults(_ sender: Any?) {
        commandActions?.toggleResults()
    }

    @objc func navigateBack(_ sender: Any?) {
        commandActions?.navigateBack()
    }

    @objc func navigateForward(_ sender: Any?) {
        commandActions?.navigateForward()
    }

    @objc func showPreviousResult(_ sender: Any?) {
        commandActions?.previousResultTab()
    }

    @objc func showNextResult(_ sender: Any?) {
        commandActions?.nextResultTab()
    }

    @objc func pinResult(_ sender: Any?) {
        commandActions?.pinResultTab()
    }

    @objc func closeResultTab(_ sender: Any?) {
        commandActions?.closeResultTab()
    }

    @objc func increaseEditorTextSize(_ sender: Any?) {
        ThemeEngine.shared.adjustEditorFontSize(by: 1)
    }

    @objc func decreaseEditorTextSize(_ sender: Any?) {
        ThemeEngine.shared.adjustEditorFontSize(by: -1)
    }
}
