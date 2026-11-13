//
//  MainContentCoordinator+Share.swift
//  TablePro
//

import Foundation
import TableProEditorKit

extension MainContentCoordinator {
    // Share Result…: the active result as the grid shows it, masked the way rows leaving the app are masked.
    func shareActiveResult() {
        guard admitsSheetCommand(), let request = activeResultShareRequest() else { return }
        activeSheet = .share(request)
    }

    // Share Query…: the editor's selection, else all of its text.
    func shareEditorQuery() {
        guard let tabId = tabManager.selectedTabId else { return }
        flushEditorText(forTab: tabId)
        guard let tab = tabManager.selectedTab, tab.tabType == .query else { return }
        let sql = Self.selectionOrWholeText(tab.content.query, selection: cursorPositions.first?.range)
        presentShareQuery(sql, title: tab.title)
    }

    func shareFavorite(_ favorite: SQLFavorite) {
        presentShareQuery(favorite.query, title: favorite.name)
    }

    func presentShareQuery(_ sql: String, title: String) {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, admitsSheetCommand() else { return }
        activeSheet = .share(.query(title: title, sql: trimmed, dialect: connection.type.rawValue))
    }

    func activeResultShareRequest() -> ShareRequest? {
        guard let tab = tabManager.selectedTab else { return nil }
        let tableRows = externallyMaskedRows(forTab: tab.id)
        guard !tableRows.rows.isEmpty else { return nil }
        let resultSet = tab.display.activeResultSet
        let sql = (resultSet?.namedParameterStatement?.sql
            ?? resultSet?.baseQuery
            ?? tab.pagination.baseQueryForMore
            ?? tab.content.query)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else { return nil }

        let read = DisplayedResultReader.read(
            tableRows: tableRows,
            displayIDs: displayIDs(forTab: tab.id),
            selectedDisplayIndices: [],
            deletedRowIDs: changeManager.deletedRowIDs,
            columns: .fromColumnLayout(tab.columnLayout, columns: tableRows.columns)
        )
        let exactTotal = tab.pagination.isApproximateRowCount ? nil : tab.pagination.totalRowCount
        let source = ShareResultSource(
            columns: read.columns,
            columnTypes: read.columnTypes,
            rows: read.rows,
            totalRowCount: max(read.rows.count, exactTotal ?? 0)
        )
        return .result(title: tab.title, sql: sql, dialect: connection.type.rawValue, source: source)
    }

    nonisolated static func selectionOrWholeText(_ text: String, selection: NSRange?) -> String {
        let whole = text as NSString
        guard let selection, selection.location != NSNotFound, selection.length > 0,
              NSMaxRange(selection) <= whole.length
        else { return text }
        return whole.substring(with: selection)
    }
}
