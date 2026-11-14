//
//  MainContentCoordinator+Share.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProEditorKit
import TableProPluginKit
import TableProSQLGrammar
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
        let key = shareResultKey(of: tab)
        return .result(
            title: tab.title,
            sql: shareSQL(of: tab),
            dialect: connection.type.rawValue,
            sourceChanges: maskingRulesApplied.eraseToAnyPublisher()
        ) { [weak self] maxRows in
            await self?.shareSource(tabId: tabId, key: key, maxRows: maxRows)
        }
    }

    // MARK: - Rows

    // The rows of the result the sheet was opened on, or of a refresh of it; nil once the tab shows another statement
    // or database. Rows the grid does not hold yet are read from the server, the grid itself left as it is.
    func shareSource(tabId: UUID, key: ShareResultKey, maxRows: Int) async -> ShareResultSource? {
        guard let tab = sharedTab(tabId, key: key) else { return nil }
        if let read = shareRead(for: tab, maxRows: maxRows) {
            do {
                let result = try await paginationCoordinator.readRows(
                    tabId: tabId,
                    query: read.query,
                    parameters: read.parameters,
                    rowCap: maxRows,
                    operationDescription: String(localized: "Share Result")
                )
                guard let current = sharedTab(tabId, key: key) else { return nil }
                return await fetchedShareSource(result, tab: current, maxRows: maxRows)
            } catch {
                Self.shareLogger.notice("Share Result read failed, sharing the loaded rows: \(error.publicLogShape, privacy: .public)")
            }
        }
        guard !Task.isCancelled, let current = sharedTab(tabId, key: key) else { return nil }
        return await loadedShareSource(tab: current, maxRows: maxRows)
    }

    // Auto Refresh and a reload install a new result for the same statement, so the share follows what the result is,
    // never the result instance.
    func shareResultKey(of tab: QueryTab) -> ShareResultKey {
        let scope = scope(for: tab)
        let statement = shareSQL(of: tab)
        // A table view the host cannot write as SQL is told apart by what narrows and orders its rows.
        let view = tab.tabType == .table && statement.isEmpty
            ? ShareTableView(tab, search: filterCoordinator.activeBrowseSearch(for: tab.filterState))
            : nil
        return ShareResultKey(
            table: tab.tabType == .table ? tab.tableContext.tableName : nil,
            statement: statement,
            parameters: tab.tabType == .table ? nil : tab.display.activeResultSet?.baseQueryParameterValues,
            database: scope?.database,
            schema: scope?.schema,
            view: view
        )
    }

    private func sharedTab(_ tabId: UUID, key: ShareResultKey) -> QueryTab? {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }), shareResultKey(of: tab) == key else { return nil }
        return tab
    }

    // The statement to read, or nil when the grid already holds what the share needs or the result's own statement
    // cannot safely run again.
    private func shareRead(for tab: QueryTab, maxRows: Int) -> (query: String, parameters: [TypedParameterValue?]?)? {
        // A value filter narrows the rows on screen, so the share is exactly those.
        guard !tab.valueFilter.isActive, maxRows > 0 else { return nil }
        let loaded = tabSessionRegistry.tableRows(for: tab.id).rows.count
        if tab.tabType == .table {
            let total = ShareTotals(tab).exact
            let pageHoldsEnough = tab.pagination.currentOffset == 0
                && (loaded >= maxRows || (total.map { loaded >= $0 } ?? false))
            guard !pageHoldsEnough, let query = filterCoordinator.viewQuery(for: tab, limit: maxRows) else { return nil }
            return (query, nil)
        }
        // A write that returned rows, such as UPDATE ... RETURNING, must not run again, as Reveal decides.
        guard let result = tab.display.activeResultSet, result.isTruncated, loaded < maxRows,
              let base = result.baseQuery, !wasReadElsewhere(result, in: tab),
              QueryClassifier.classify(base, databaseType: connection.type).tier == .safe
        else { return nil }
        return (base, result.baseQueryParameterValues)
    }

    private func fetchedShareSource(_ result: QueryResult, tab: QueryTab, maxRows: Int) async -> ShareResultSource? {
        let policy = maskingPolicy
        let table = tab.tabType == .table ? tab.tableContext.tableName : nil
        let typeNames = result.columnTypes.map(\.rawType)
        let masks = policy.columnMasks(table: table, columns: result.columns, typeNames: typeNames).strictest(
            with: policy.externalColumnMasks(
                table: table, columns: result.columns, typeNames: typeNames, origins: result.columnOrigins
            )
        )
        let projection = VisibleColumnProjection.fromColumnLayout(tab.columnLayout, columns: result.columns)
        let untraced = policy.untracedColumns(table: table, columns: result.columns, origins: result.columnOrigins)
        return await Self.fetchedShareSource(
            FetchedShareRows(
                columns: result.columns,
                columnTypes: result.columnTypes,
                rows: result.rows,
                absentCells: result.absentCells,
                unloadedCells: result.unloadedCells,
                isTruncated: result.isTruncated,
                masks: masks,
                projection: projection,
                untracedColumns: projection.positions(of: Set(untraced)),
                totals: ShareTotals(tab),
                sql: shareSQL(of: tab)
            ),
            maxRows: maxRows
        )
    }

    @concurrent
    private static func fetchedShareSource(_ fetched: FetchedShareRows, maxRows: Int) async -> ShareResultSource? {
        let shape = TableRows.RowShape(columns: fetched.columns, masks: fetched.masks, exportPolicy: .none, exportTable: nil)
        let prepared = await TableRows.preparing(
            fetched.rows, absentCells: fetched.absentCells, unloadedCells: fetched.unloadedCells, shape: shape
        )
        guard prepared.isComplete, !Task.isCancelled else { return nil }
        let read = DisplayedResultReader.read(
            tableRows: TableRows.from(prepared: prepared, columnTypes: fetched.columnTypes),
            displayIDs: nil,
            selectedDisplayIndices: [],
            columns: fetched.projection
        )
        guard !Task.isCancelled else { return nil }
        let more = fetched.isTruncated || read.rows.count >= maxRows
        return ShareResultSource(
            columns: read.columns,
            columnTypes: read.columnTypes,
            rows: read.rows,
            totalRowCount: fetched.totals.total(rows: read.rows.count, more: more),
            sql: fetched.sql,
            masks: read.masks,
            untracedColumns: fetched.untracedColumns
        )
    }

    private func loadedShareSource(tab: QueryTab, maxRows: Int) async -> ShareResultSource? {
        let tableRows = tabSessionRegistry.tableRows(for: tab.id)
        let table = tab.tabType == .table ? tab.tableContext.tableName : nil
        let untraced = maskingPolicy.untracedColumns(table: table, columns: tableRows.columns, origins: tableRows.columnOrigins)
        let projection = VisibleColumnProjection.fromColumnLayout(tab.columnLayout, columns: tableRows.columns)
        return await Self.loadedShareSource(
            HeldShareRows(
                tableRows: tableRows,
                displayIDs: displayIDs(forTab: tab.id),
                deletedRowIDs: changeManager(forTab: tab.id).deletedRowIDs,
                overlay: externalOverlay(forTab: tab.id),
                projection: projection,
                untracedColumns: projection.positions(of: Set(untraced)),
                totals: ShareTotals(tab),
                isValueFiltered: tab.valueFilter.isActive,
                hasRowsElsewhere: tab.pagination.hasMoreRows || tab.display.activeResultSet?.isTruncated == true
                    || tab.pagination.currentOffset > 0,
                sql: shareSQL(of: tab)
            ),
            maxRows: maxRows
        )
    }

    // At most max_rows display positions are read and masked, so a large grid is never copied or masked whole.
    @concurrent
    private static func loadedShareSource(_ held: HeldShareRows, maxRows: Int) async -> ShareResultSource? {
        guard !Task.isCancelled else { return nil }
        let displayed = held.displayIDs?.count ?? held.tableRows.rows.count
        let read = DisplayedResultReader.read(
            tableRows: held.tableRows,
            displayIDs: held.displayIDs,
            selectedDisplayIndices: Set(0..<min(displayed, maxRows + held.deletedRowIDs.count)),
            deletedRowIDs: held.deletedRowIDs,
            columns: held.projection
        )
        guard !Task.isCancelled else { return nil }
        let overlay = held.projection.masks(held.overlay)
        let rows = overlay.rows(Array(read.rows.prefix(maxRows)))
        let total: Int?
        if held.isValueFiltered {
            total = displayed - read.skippedDeletedCount
        } else {
            let more = held.hasRowsElsewhere || displayed - read.skippedDeletedCount > rows.count
            total = held.totals.total(rows: rows.count, more: more)
        }
        return ShareResultSource(
            columns: read.columns,
            columnTypes: read.columnTypes,
            rows: rows,
            totalRowCount: total.map { max($0, rows.count) },
            sql: held.sql,
            masks: read.masks.strictest(with: overlay),
            untracedColumns: held.untracedColumns
        )
    }

    // A table tab shares its view without the page's window, or no SQL when the host cannot write that view.
    func shareSQL(of tab: QueryTab) -> String {
        guard tab.tabType == .table else { return Self.resultSQL(of: tab) }
        return filterCoordinator.viewSQL(for: tab) ?? ""
    }

    private static func resultSQL(of tab: QueryTab) -> String {
        let resultSet = tab.display.activeResultSet
        return (resultSet?.namedParameterStatement?.sql ?? resultSet?.baseQuery ?? tab.content.query)
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

internal struct ShareResultKey: Equatable, Sendable {
    let table: String?
    let statement: String
    let parameters: [TypedParameterValue?]?
    let database: String?
    let schema: String?
    let view: ShareTableView?
}

internal struct ShareTableView: Equatable, Sendable {
    let filters: [TableFilter]
    let logicMode: FilterLogicMode
    let search: BrowseSearchState?
    let sort: [SortColumn]

    @MainActor
    init(_ tab: QueryTab, search: BrowseSearchState?) {
        let rerun = tab.filterState.rerunFilters
        filters = rerun.filters
        logicMode = rerun.logicMode
        self.search = search
        sort = tab.sortState.columns
    }
}

// The tab's row count, taken on the main actor for the rows built off it.
private struct ShareTotals: Sendable {
    let exact: Int?
    let estimate: Int?

    @MainActor
    init(_ tab: QueryTab) {
        let pagination = tab.pagination
        exact = pagination.isApproximateRowCount ? nil : pagination.totalRowCount
        estimate = pagination.isApproximateRowCount ? pagination.totalRowCount : nil
    }

    // The true total when counted; an estimate when it is above the rows held; else the rows, or nil if more exist.
    func total(rows: Int, more: Bool) -> Int? {
        if let exact {
            return max(exact, rows)
        }
        if let estimate, estimate > rows {
            return estimate
        }
        return more ? nil : rows
    }
}

private struct FetchedShareRows: Sendable {
    let columns: [String]
    let columnTypes: [ColumnType]
    let rows: [[PluginCellValue]]
    let absentCells: [Int: Set<Int>]
    let unloadedCells: [Int: [Int: Int]]
    let isTruncated: Bool
    let masks: ColumnMasks
    let projection: VisibleColumnProjection
    let untracedColumns: Set<Int>
    let totals: ShareTotals
    let sql: String
}

private struct HeldShareRows: Sendable {
    let tableRows: TableRows
    let displayIDs: [RowID]?
    let deletedRowIDs: Set<RowID>
    // What the grid's own masks leave for a reader outside the app, by source column.
    let overlay: ColumnMasks
    let projection: VisibleColumnProjection
    let untracedColumns: Set<Int>
    let totals: ShareTotals
    let isValueFiltered: Bool
    let hasRowsElsewhere: Bool
    let sql: String
}
