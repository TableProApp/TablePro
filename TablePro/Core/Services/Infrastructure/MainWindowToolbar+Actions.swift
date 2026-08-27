//
//  MainWindowToolbar+Actions.swift
//  TablePro
//

import AppKit
import Combine

extension MainWindowToolbar {
    /// Straight to the window, because the switcher is the window's. Every other item here needs
    /// the connection on screen; this one is the way off it, so it cannot be reached through that
    /// connection's coordinator, which a disconnect nils.
    @objc func performOpenConnectionSwitcher(_ sender: Any?) {
        subject.windowController?.openConnectionSwitcher()
    }

    @objc func performOpenDatabaseSwitcher(_ sender: Any?) {
        coordinator?.commandActions?.openDatabaseSwitcher()
    }

    @objc func performNavigateBack(_ sender: Any?) {
        coordinator?.commandActions?.navigateBack()
    }

    @objc func performNavigateForward(_ sender: Any?) {
        coordinator?.commandActions?.navigateForward()
    }

    @objc func performRefresh(_ sender: Any?) {
        coordinator?.commandActions?.refresh()
    }

    @objc func performSaveChanges(_ sender: Any?) {
        coordinator?.commandActions?.saveChanges()
    }

    @objc func performOpenQuickSwitcher(_ sender: Any?) {
        coordinator?.commandActions?.openQuickSwitcher()
    }

    @objc func performAddRow(_ sender: Any?) {
        NSApp.sendAction(#selector(MainSplitViewController.addRow(_:)), to: nil, from: nil)
    }

    @objc func performRestorePreviousValues(_ sender: Any?) {
        NSApp.sendAction(#selector(MainSplitViewController.restorePreviousValues(_:)), to: nil, from: nil)
    }

    @objc func performNewTab(_ sender: Any?) {
        NSApp.sendAction(#selector(MainSplitViewController.newEditorTab(_:)), to: nil, from: nil)
    }

    @objc func performPreviewSQL(_ sender: Any?) {
        coordinator?.commandActions?.previewSQL()
    }

    @objc func performToggleResults(_ sender: Any?) {
        coordinator?.commandActions?.toggleResults()
    }

    @objc func performShowDashboard(_ sender: Any?) {
        coordinator?.commandActions?.showServerDashboard()
    }

    @objc func performToggleHistory(_ sender: Any?) {
        coordinator?.commandActions?.toggleHistoryPanel()
    }

    @objc func performExport(_ sender: Any?) {
        coordinator?.commandActions?.exportTables()
    }

    @objc func performImportFormat(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              let formatId = menuItem.representedObject as? String else { return }
        coordinator?.commandActions?.importTables(formatId: formatId)
    }
}
