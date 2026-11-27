//
//  MainContentCoordinator+KeysetPaging.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum PageMove {
    case next
    case previous
    case last
}

extension MainContentCoordinator {
    /// The table's primary key when the page order is that key and nothing else, in one direction. The app's
    /// default sort is such an order. A seek resumes from a row only in an order no two rows share, which holds only
    /// on an engine that enforces the key.
    func keysetOrder(for tab: QueryTab) -> (columns: [String], direction: SortDirection)? {
        let keys = tab.tableContext.primaryKeyColumns
        guard tab.tabType == .table, services.pluginManager.seeksKeyedPages(for: connection.type),
              supportsColumnSort, queryBuilder.writesSQL, !keys.isEmpty,
              !tab.tableContext.knowsView(named: tab.tableContext.tableName),
              filterCoordinator.activeBrowseSearch(for: tab.filterState) == nil,
              TableQueryBuilder.spellsTheSame(tab.sortState.columns.compactMap(\.columnName), keys),
              Self.namesKeepTheirSpelling(tabSessionRegistry.tableRows(for: tab.id).columns + keys),
              let direction = tab.sortState.columns.first?.direction,
              tab.sortState.columns.allSatisfy({ $0.direction == direction }) else { return nil }
        return (keys, direction)
    }

    // Read off the rows on screen before the move: the edge row of this page is where the next one starts. Those
    // rows are this page's only once the statement that reads it has landed; a page still loading, stopped or failed
    // shows the page before, and seeking from it would label one page with another's rows.
    func pageSeek(for tab: QueryTab, move: PageMove) -> PageSeek? {
        guard let order = keysetOrder(for: tab),
              !tab.content.query.isEmpty, tab.display.activeResultSet?.baseQuery == tab.content.query,
              Self.keyHoldsNoNull(order.columns, in: tabSessionRegistry.tableRows(for: tab.id)) else { return nil }
        switch move {
        case .last:
            return .last
        case .next:
            return pageEdgeKey(of: tab, last: true).map(PageSeek.after)
        case .previous:
            return pageEdgeKey(of: tab, last: false).map(PageSeek.before)
        }
    }

    /// The seek a page's statement is built with, the key's types taken from the columns that statement reads.
    func keysetSeek(for tab: QueryTab, columns: [String], columnTypes: [ColumnType]) -> TableKeysetSeek? {
        guard let seek = tab.pagination.seek, let order = keysetOrder(for: tab),
              Self.namesKeepTheirSpelling(columns) else { return nil }
        let types = order.columns.map { name -> ColumnType? in
            guard let index = Self.index(of: name, in: columns), index < columnTypes.count else { return nil }
            return columnTypes[index]
        }
        return TableKeysetSeek(
            columns: order.columns, columnTypes: types, direction: order.direction,
            key: seek.key, readsBackward: seek.readsBackward
        )
    }

    /// The statement a pending seek reads the tab's page with, spent here so the page is read by key once, for the
    /// move that reached it. Any later read of that page, after a save, a refresh, a tick of auto-refresh or a return
    /// to a stale tab, reads `content.query` at its offset: kept on its edge row, a page read backward drifts from
    /// page 1, which always reads from the start, and a row deleted on it pulls in one that page 2 shows too.
    func keyedPageStatement(forTab tabId: UUID) -> KeyedPageStatement? {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }), tab.tabType == .table,
              tab.pagination.seek != nil else { return nil }
        let statement = filterCoordinator.keyedPageStatement(for: tab)
        tabManager.mutate(tabId: tabId) { $0.pagination.seek = nil }
        return statement
    }

    /// The keyed statement when the table's key names one row of what it reads, else nil for the page's offset read.
    /// Asked before every keyed read, never kept: a child table or a collation added since the last move counts.
    func confirmedKeyedPage(_ statement: KeyedPageStatement?, table: String?, scope: DatabaseScope) async
        -> KeyedPageStatement? {
        guard let statement, let table else { return nil }
        let answer = try? await services.databaseManager.withMetadataDriver(scope: scope) { driver in
            try await driver.primaryKeyNamesOneRow(inTable: table, schema: scope.schema)
        }
        return answer == true ? statement : nil
    }

    // A seek past an edge compares the key, which passes over every NULL one: SQLite takes NULL in a primary key that
    // is not its rowid, and those rows would drop out of each page read toward them. A lone INTEGER key is not proof
    // of the rowid: `INTEGER PRIMARY KEY DESC` is an ordinary column, and the catalog reports both nullable.
    static func keyHoldsNoNull(_ keys: [String], in rows: TableRows) -> Bool {
        keys.allSatisfy { rows.columnNullable[$0] == false }
    }

    // Two names Swift calls equal but spelled with other scalars, NFC and NFD, are two columns to the engine.
    static func namesKeepTheirSpelling(_ names: [String]) -> Bool {
        var seen: [String: String] = [:]
        for name in names {
            if let other = seen[name], !other.unicodeScalars.elementsEqual(name.unicodeScalars) { return false }
            seen[name] = name
        }
        return true
    }

    private static func index(of name: String, in columns: [String]) -> Int? {
        columns.firstIndex { $0.unicodeScalars.elementsEqual(name.unicodeScalars) }
    }

    // A row added in the grid has no place on the server yet, and a key with a NULL part orders nowhere.
    private func pageEdgeKey(of tab: QueryTab, last: Bool) -> [PluginCellValue]? {
        let rows = tabSessionRegistry.tableRows(for: tab.id)
        let indices = tab.tableContext.primaryKeyColumns.compactMap { Self.index(of: $0, in: rows.columns) }
        // A masked cell holds the mask's text, not the key.
        guard indices.count == tab.tableContext.primaryKeyColumns.count,
              !indices.contains(where: rows.masks.isMasked) else { return nil }
        let saved = { (row: Row) in !row.id.isInserted }
        guard let row = last ? rows.rows.last(where: saved) : rows.rows.first(where: saved) else { return nil }
        let key = indices.map { row[$0] }
        guard key.allSatisfy({ !$0.isNull }) else { return nil }
        return key
    }
}

extension QueryFetchResult {
    // A page read in reverse key order, put back in the order the grid shows it.
    func reversingRows() -> QueryFetchResult {
        let last = rows.count - 1
        var reversed = QueryFetchResult(
            columns: columns,
            columnTypes: columnTypes,
            rows: rows.reversed(),
            executionTime: executionTime,
            rowsAffected: rowsAffected,
            statusMessage: statusMessage,
            isTruncated: isTruncated,
            resultColumnMeta: resultColumnMeta,
            timing: timing,
            serverOutput: serverOutput,
            rowLocators: rowLocators.map { $0.reversed() },
            exportDocuments: exportDocuments.map { $0.reversed() },
            absentCells: Dictionary(uniqueKeysWithValues: absentCells.map { (last - $0.key, $0.value) })
        )
        reversed.unloadedCells = Dictionary(uniqueKeysWithValues: unloadedCells.map { (last - $0.key, $0.value) })
        reversed.columnOrigins = columnOrigins
        return reversed
    }
}
