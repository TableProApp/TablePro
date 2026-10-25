//
//  FindCoordinator.swift
//  TablePro
//

import Foundation

@MainActor
final class FindCoordinator {
    unowned let parent: MainContentCoordinator

    init(parent: MainContentCoordinator) {
        self.parent = parent
    }

    private var model: DataGridModel? {
        parent.activeGridModel
    }

    var hasActiveFind: Bool {
        guard let find = model?.find else { return false }
        return find.isVisible && !find.matches.isEmpty
    }

    func showFind(replace: Bool = false) {
        model?.showFind(replace: replace)
    }

    func findNext() {
        model?.findNext()
    }

    func findPrevious() {
        model?.findPrevious()
    }

    func useSelectionForFind() {
        model?.useSelectionForFind()
    }

    // MARK: - Search All Rows

    func offersSearchAllRows(forTab tabID: UUID) -> Bool {
        // The search replaces the filter set with one OR group, so it never runs over filters the user applied.
        guard let tab = parent.tabManager.tabs.first(where: { $0.id == tabID }),
              tab.tabType == .table,
              parent.supportsMatchAnyFilters,
              tab.filterState.filters.isEmpty else { return false }
        let rows = parent.tabSessionRegistry.tableRows(for: tabID)
        return tab.pagination.hasUnloadedRows(loadedRowCount: rows.rows.count) && !serverSearchableColumns(in: rows).isEmpty
    }

    // Its own filter rows: addFilter would apply the user's default-column setting.
    func searchAllRows(term: String, tabID: UUID) {
        guard parent.tabManager.selectedTabId == tabID else { return }
        let columns = serverSearchableColumns(in: parent.tabSessionRegistry.tableRows(for: tabID))
        guard !columns.isEmpty else { return }
        parent.filterCoordinator.applyCrossColumnSearch(term: term, columns: columns)
    }

    func serverSearchableColumns(in rows: TableRows) -> [String] {
        let readsAnyColumn = parent.connection.type.patternFiltersReadAnyColumn
        return rows.columns.indices.compactMap { index in
            let columnType = index < rows.columnTypes.count ? rows.columnTypes[index] : nil
            guard FindMatcher.isServerSearchable(columnType, patternReadsAnyColumn: readsAnyColumn) else { return nil }
            return rows.columns[index]
        }
    }
}
