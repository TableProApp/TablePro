//
//  StatusBarSnapshot.swift
//  TablePro
//

import Foundation

struct StatusBarSnapshot: Equatable {
    let tabId: UUID?
    let tabType: TabType?
    let hasRows: Bool
    let hasColumns: Bool
    /// Rows held in the loaded page buffer.
    let rowCount: Int
    /// Rows the grid is actually showing, which a per-column value filter narrows without re-querying.
    ///
    /// Kept apart from `rowCount` because selection indices are display positions: counting a
    /// selection against the loaded buffer reported "3 of 100 rows selected" for a grid showing three.
    let displayRowCount: Int
    let isValueFiltered: Bool
    let hasTableName: Bool
    /// The modes this tab can switch between, which the bar's leading control offers.
    let availableModes: [ResultsViewMode]
    /// Whether the structure editor has published an add/remove pair for this tab.
    let hasStructureActions: Bool
    let pagination: PaginationState
    let statusMessage: String?

    init(
        tabId: UUID?,
        tabType: TabType?,
        hasRows: Bool,
        hasColumns: Bool,
        rowCount: Int,
        displayRowCount: Int? = nil,
        isValueFiltered: Bool = false,
        hasTableName: Bool,
        availableModes: [ResultsViewMode] = [],
        hasStructureActions: Bool = false,
        pagination: PaginationState,
        statusMessage: String?
    ) {
        self.tabId = tabId
        self.tabType = tabType
        self.hasRows = hasRows
        self.hasColumns = hasColumns
        self.rowCount = rowCount
        self.displayRowCount = displayRowCount ?? rowCount
        self.isValueFiltered = isValueFiltered
        self.hasTableName = hasTableName
        self.availableModes = availableModes
        self.hasStructureActions = hasStructureActions
        self.pagination = pagination
        self.statusMessage = statusMessage
    }

    init(
        tab: QueryTab?,
        tableRows: TableRows?,
        displayRowCount: Int? = nil,
        hasStructureActions: Bool = false
    ) {
        let loaded = tableRows?.rows.count ?? 0
        let displayed = displayRowCount ?? loaded
        self.init(
            tabId: tab?.id,
            tabType: tab?.tabType,
            hasRows: !(tableRows?.rows.isEmpty ?? true),
            hasColumns: !(tableRows?.columns.isEmpty ?? true),
            rowCount: loaded,
            displayRowCount: displayed,
            isValueFiltered: displayed != loaded,
            hasTableName: tab?.tableContext.tableName != nil,
            availableModes: ResultsModeAvailability.modes(
                tabType: tab?.tabType,
                hasTableName: tab?.tableContext.tableName != nil,
                hasColumns: !(tableRows?.columns.isEmpty ?? true)
            ),
            hasStructureActions: hasStructureActions,
            pagination: tab?.pagination ?? PaginationState(),
            statusMessage: tab?.execution.statusMessage
        )
    }

    var showsPaginationControls: Bool {
        if let total = pagination.totalRowCount, total > 0 { return true }
        return isPagedWithUnknownTotal
    }

    var isPagedWithUnknownTotal: Bool {
        pagination.currentPage > 1 || rowCount >= pagination.pageSize
    }
}
