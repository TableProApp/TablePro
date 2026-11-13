//
//  MainContentCoordinator+Share.swift
//  TablePro
//

import Foundation
import os
import TableProEditorKit
import TableProPluginKit
import TableProUtilities

extension MainContentCoordinator {
    private static let shareLogger = Logger(subsystem: "com.TablePro", category: "ShareResult")

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

    func shareLinkedFavorite(_ favorite: LinkedSQLFavorite) {
        guard let loaded = FileTextLoader.load(favorite.fileURL) else { return }
        presentShareQuery(loaded.content, title: favorite.name)
    }

    func presentShareQuery(_ sql: String, title: String) {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, admitsSheetCommand() else { return }
        activeSheet = .share(.query(title: title, sql: trimmed, dialect: connection.type.rawValue))
    }

    func activeResultShareRequest() -> ShareRequest? {
        guard let tab = tabManager.selectedTab,
              !tabSessionRegistry.tableRows(for: tab.id).rows.isEmpty
        else { return nil }
        let tabId = tab.id
        return .result(title: tab.title, sql: shareSQL(of: tab), dialect: connection.type.rawValue) { [weak self] maxRows in
            await self?.shareSource(tabId: tabId, maxRows: maxRows)
        }
    }

    // MARK: - Rows

    // Rows the grid does not hold yet are read from the server, the grid itself left as it is.
    func shareSource(tabId: UUID, maxRows: Int) async -> ShareResultSource? {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }) else { return nil }
        if let read = shareRead(for: tab, maxRows: maxRows) {
            do {
                let result = try await paginationCoordinator.readRows(
                    tabId: tabId,
                    query: read.query,
                    parameters: read.parameters,
                    rowCap: maxRows,
                    operationDescription: String(localized: "Share Result")
                )
                if let current = tabManager.tabs.first(where: { $0.id == tabId }) {
                    return fetchedShareSource(result, tab: current, sql: shareSQL(of: current), maxRows: maxRows)
                }
                return nil
            } catch {
                Self.shareLogger.notice("Share Result read failed, sharing the loaded rows: \(error.publicLogShape, privacy: .public)")
            }
        }
        guard let current = tabManager.tabs.first(where: { $0.id == tabId }) else { return nil }
        return loadedShareSource(tab: current, maxRows: maxRows)
    }

    // The statement to read, or nil when the grid already holds what the share needs.
    private func shareRead(for tab: QueryTab, maxRows: Int) -> (query: String, parameters: [TypedParameterValue?]?)? {
        // A value filter narrows the rows on screen, so the share is exactly those.
        guard !tab.valueFilter.isActive, maxRows > 0 else { return nil }
        let loaded = tabSessionRegistry.tableRows(for: tab.id).rows.count
        if tab.tabType == .table {
            let total = Self.exactTotal(of: tab)
            let pageHoldsEnough = tab.pagination.currentOffset == 0
                && (loaded >= maxRows || (total.map { loaded >= $0 } ?? false))
            guard !pageHoldsEnough, let query = filterCoordinator.viewQuery(for: tab, limit: maxRows) else { return nil }
            return (query, nil)
        }
        let isCut = tab.pagination.hasMoreRows || tab.display.activeResultSet?.isTruncated == true
        guard isCut, loaded < maxRows, let base = tab.pagination.baseQueryForMore else { return nil }
        return (base, tab.pagination.baseQueryParameterValues)
    }

    private func fetchedShareSource(_ result: QueryResult, tab: QueryTab, sql: String, maxRows: Int) -> ShareResultSource {
        let policy = maskingPolicy
        let table = tab.tabType == .table ? tab.tableContext.tableName : nil
        let rows = TableRows.from(
            queryRows: result.rows,
            columns: result.columns,
            columnTypes: result.columnTypes,
            exportDocuments: result.exportDocuments,
            absentCells: result.absentCells,
            unloadedCells: result.unloadedCells,
            masks: policy.columnMasks(table: table, columns: result.columns, columnTypes: result.columnTypes),
            exportPolicy: policy,
            exportTable: table,
            columnOrigins: result.columnOrigins
        )
        let external = policy.externalColumnMasks(
            table: table, columns: rows.columns, typeNames: rows.columnTypes.map(\.rawType), origins: rows.columnOrigins
        )
        let masked = policy.isEmpty ? rows : rows.externallyMasked(by: external)
        let read = DisplayedResultReader.read(
            tableRows: masked,
            displayIDs: nil,
            selectedDisplayIndices: [],
            columns: .fromColumnLayout(tab.columnLayout, columns: masked.columns)
        )
        let more = result.isTruncated || read.rows.count >= maxRows
        return ShareResultSource(
            columns: read.columns,
            columnTypes: read.columnTypes,
            rows: read.rows,
            totalRowCount: Self.shareTotal(of: tab, rows: read.rows.count, more: more),
            sql: sql,
            masks: read.masks
        )
    }

    // At most max_rows display positions are read, so a large grid is never copied whole.
    private func loadedShareSource(tab: QueryTab, maxRows: Int) -> ShareResultSource {
        let tableRows = externallyMaskedRows(forTab: tab.id)
        let displayIDs = displayIDs(forTab: tab.id)
        let displayed = displayIDs?.count ?? tableRows.rows.count
        let deleted = changeManager.deletedRowIDs
        let positions = Set(0..<min(displayed, maxRows + deleted.count))
        let read = DisplayedResultReader.read(
            tableRows: tableRows,
            displayIDs: displayIDs,
            selectedDisplayIndices: positions,
            deletedRowIDs: deleted,
            columns: .fromColumnLayout(tab.columnLayout, columns: tableRows.columns)
        )
        let rows = Array(read.rows.prefix(maxRows))
        let total: Int?
        if tab.valueFilter.isActive {
            total = displayed - read.skippedDeletedCount
        } else {
            let more = tab.pagination.hasMoreRows || tab.display.activeResultSet?.isTruncated == true
                || tab.pagination.currentOffset > 0 || displayed - read.skippedDeletedCount > rows.count
            total = Self.shareTotal(of: tab, rows: rows.count, more: more)
        }
        return ShareResultSource(
            columns: read.columns,
            columnTypes: read.columnTypes,
            rows: rows,
            totalRowCount: total.map { max($0, rows.count) },
            sql: shareSQL(of: tab),
            masks: read.masks
        )
    }

    // The true total when counted; an estimate when it is above the rows held; else the rows, or nil if more exist.
    private static func shareTotal(of tab: QueryTab, rows: Int, more: Bool) -> Int? {
        if let exact = exactTotal(of: tab) {
            return max(exact, rows)
        }
        if tab.pagination.isApproximateRowCount, let estimate = tab.pagination.totalRowCount, estimate > rows {
            return estimate
        }
        return more ? nil : rows
    }

    private static func exactTotal(of tab: QueryTab) -> Int? {
        tab.pagination.isApproximateRowCount ? nil : tab.pagination.totalRowCount
    }

    // A table tab shares its view without the page's window, or no SQL when the host cannot write that view.
    func shareSQL(of tab: QueryTab) -> String {
        guard tab.tabType == .table else { return Self.resultSQL(of: tab) }
        return filterCoordinator.viewSQL(for: tab) ?? ""
    }

    private static func resultSQL(of tab: QueryTab) -> String {
        let resultSet = tab.display.activeResultSet
        return (resultSet?.namedParameterStatement?.sql
            ?? resultSet?.baseQuery
            ?? tab.pagination.baseQueryForMore
            ?? tab.content.query)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func selectionOrWholeText(_ text: String, selection: NSRange?) -> String {
        let whole = text as NSString
        guard let selection, selection.location != NSNotFound, selection.length > 0,
              NSMaxRange(selection) <= whole.length
        else { return text }
        return whole.substring(with: selection)
    }
}
