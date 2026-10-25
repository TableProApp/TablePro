//
//  MainContentCoordinator+DocumentEditing.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    // Table tabs only: the write ends by reloading the tab. Staged grid edits refuse it, since that reload would ask to discard them.
    var documentEditingAvailable: Bool {
        guard canEditActiveResult,
              PluginManager.shared.supportsDocumentEditing(for: connection.type),
              let tab = tabManager.selectedTab,
              tab.tabType == .table,
              tab.tableContext.tableName != nil,
              tab.display.resultsViewMode == .data else { return false }
        return !changeManager.hasChanges
    }

    var canInsertDocument: Bool {
        documentEditingAvailable
    }

    func presentInsertDocument() {
        guard canInsertDocument,
              let table = tabManager.selectedTab?.tableContext.tableName,
              let scope = selectedTabScope else { return }
        activeSheet = .documentEditor(DocumentEditorRequest(table: table, scope: scope))
    }

    // What the driver finds the row's document by; nil for a row it gave none, where Edit Document is not offered.
    func documentLocator(for rowID: RowID) -> String? {
        guard documentEditingAvailable, let tab = tabManager.selectedTab else { return nil }
        return tabSessionRegistry.tableRows(for: tab.id).rowLocator(for: rowID)
    }

    func canEditDocument(rowID: RowID) -> Bool {
        documentLocator(for: rowID) != nil
    }

    // The caller resolves the locator when the command is chosen, so a reload in between can't move it to another row.
    func presentEditDocument(locator: String) {
        guard documentEditingAvailable,
              let table = tabManager.selectedTab?.tableContext.tableName,
              let scope = selectedTabScope else { return }
        activeSheet = .documentEditor(DocumentEditorRequest(table: table, scope: scope, kind: .edit(locator: locator)))
    }
}
