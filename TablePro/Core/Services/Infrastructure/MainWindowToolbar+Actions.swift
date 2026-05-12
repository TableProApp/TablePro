//
//  MainWindowToolbar+Actions.swift
//  TablePro
//

import AppKit
import Combine

extension MainWindowToolbar {
    @objc func performOpenConnectionSwitcher(_ sender: Any?) {
        coordinator?.commandActions?.openConnectionSwitcher()
    }

    @objc func performOpenDatabaseSwitcher(_ sender: Any?) {
        coordinator?.commandActions?.openDatabaseSwitcher()
    }

    @objc func performRefresh(_ sender: Any?) {
        AppCommands.shared.refreshData.send(nil)
    }

    @objc func performSaveChanges(_ sender: Any?) {
        coordinator?.commandActions?.saveChanges()
    }

    @objc func performOpenQuickSwitcher(_ sender: Any?) {
        coordinator?.commandActions?.openQuickSwitcher()
    }

    @objc func performNewTab(_ sender: Any?) {
        NSApp.sendAction(#selector(NSWindow.newWindowForTab(_:)), to: nil, from: nil)
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

    @objc func performImport(_ sender: Any?) {
        coordinator?.commandActions?.importTables()
    }
}
