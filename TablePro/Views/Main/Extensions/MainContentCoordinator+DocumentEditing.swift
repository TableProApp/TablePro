//
//  MainContentCoordinator+DocumentEditing.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    /// Whether the selected tab is a collection whose engine writes whole documents.
    ///
    /// One definition for every place that offers Insert Document or Edit Document: the Edit menu,
    /// the row menu and the empty-space menu. Only a table tab, because the write ends by reloading
    /// the tab and a query tab's result is not reloaded that way, so the change would not appear. A
    /// tab with staged grid edits refuses it, because a reload over staged edits asks to discard them
    /// in a sheet behind this one.
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

    /// What the driver finds the document on a grid row by, read through the display order so a
    /// sort or a value filter cannot hand back another row's document. Nil for a row the driver
    /// gave none, which is a row Edit Document is not offered on.
    func documentLocator(forDisplayRow displayRow: Int) -> String? {
        guard documentEditingAvailable, let tab = tabManager.selectedTab else { return nil }
        let tableRows = tabSessionRegistry.tableRows(for: tab.id)
        guard let row = DisplayRowMapping.row(
            forDisplay: displayRow,
            displayIDs: activeGridDisplayIDs,
            in: tableRows
        ) else { return nil }
        return tableRows.rowLocator(for: row.id)
    }

    func canEditDocument(atDisplayRow displayRow: Int) -> Bool {
        documentLocator(forDisplayRow: displayRow) != nil
    }

    /// Opens the editor on the document a locator names. The locator is resolved by the caller at
    /// the moment the command was chosen, so a reload in between cannot move it to another row.
    func presentEditDocument(locator: String) {
        guard documentEditingAvailable,
              let table = tabManager.selectedTab?.tableContext.tableName,
              let scope = selectedTabScope else { return }
        activeSheet = .documentEditor(DocumentEditorRequest(table: table, scope: scope, kind: .edit(locator: locator)))
    }
}
