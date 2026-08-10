//
//  MainSplitViewController+FileMenuActions.swift
//  TablePro
//

import AppKit

extension MainSplitViewController {
    @objc func openSQLFile(_ sender: Any?) {
        commandActions?.openSQLFile()
    }

    @objc func saveDocument(_ sender: Any?) {
        commandActions?.saveChanges()
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        commandActions?.saveFileAs()
    }

    @objc func closeOtherTabs(_ sender: Any?) {
        commandActions?.closeOtherTabs()
    }

    @objc func closeTabsForOtherContainers(_ sender: Any?) {
        commandActions?.closeTabsForOtherDatabases()
    }

    @objc func closeAllTabs(_ sender: Any?) {
        commandActions?.closeAllTabs()
    }

    @objc func exportTables(_ sender: Any?) {
        commandActions?.exportTables()
    }

    @objc func exportQueryResults(_ sender: Any?) {
        commandActions?.exportQueryResults()
    }

    @objc func importData(_ sender: Any?) {
        guard let formatId = commandActions?.availableImportFormats.first?.id else { return }
        commandActions?.importTables(formatId: formatId)
    }

    @objc func backupDatabase(_ sender: Any?) {
        commandActions?.backupDatabase()
    }

    @objc func restoreDatabase(_ sender: Any?) {
        commandActions?.restoreDatabase()
    }
}
