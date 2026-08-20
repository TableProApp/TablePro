//
//  MainSplitViewController+ViewMenuActions.swift
//  TablePro
//

import AppKit

extension MainSplitViewController {
    @objc func toggleWorkspaceRail(_ sender: Any?) {
        toggleWorkspaceRail()
    }

    @objc func showPreviousWorkspace(_ sender: Any?) {
        commandActions?.showPreviousWorkspace()
    }

    @objc func showNextWorkspace(_ sender: Any?) {
        commandActions?.showNextWorkspace()
    }

    @objc func setResultView(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
              let mode = ResultsViewMode(rawValue: raw) else { return }
        commandActions?.setResultsViewMode(mode)
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
