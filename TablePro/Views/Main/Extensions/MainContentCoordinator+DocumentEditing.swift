//
//  MainContentCoordinator+DocumentEditing.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    /// Whether the selected tab is a collection whose engine writes whole documents.
    ///
    /// One definition for every place that offers Insert Document: the Edit menu, the row menu and
    /// the empty-space menu. Only a table tab, because the write ends by reloading the tab and a
    /// query tab's result is not reloaded that way, so the new document would not appear. A tab with
    /// staged grid edits refuses it, because a reload over staged edits asks to discard them in a
    /// sheet behind this one.
    var canInsertDocument: Bool {
        guard canEditActiveResult,
              PluginManager.shared.supportsDocumentEditing(for: connection.type),
              let tab = tabManager.selectedTab,
              tab.tabType == .table,
              tab.tableContext.tableName != nil,
              tab.display.resultsViewMode == .data else { return false }
        return !changeManager.hasChanges
    }

    func presentInsertDocument() {
        guard canInsertDocument,
              let table = tabManager.selectedTab?.tableContext.tableName,
              let scope = selectedTabScope else { return }
        activeSheet = .documentEditor(DocumentEditorRequest(table: table, scope: scope))
    }
}
