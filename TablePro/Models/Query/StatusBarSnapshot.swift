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

    /// `isFetching` is the caller's answer to "is an execution running for this tab", which the tab
    /// alone cannot give. `PaginationState.isLoading` covers the window a retarget opens before the
    /// execution is claimed; the registry covers every later path, such as a page turn or a sort,
    /// where the rows on screen stay put. Either one means the same thing to the bar, so they are
    /// unioned here rather than checked separately by each control.
    init(
        tab: QueryTab?,
        tableRows: TableRows?,
        displayRowCount: Int? = nil,
        isFetching: Bool = false,
        hasStructureActions: Bool = false
    ) {
        let loaded = tableRows?.rows.count ?? 0
        let displayed = displayRowCount ?? loaded
        var pagination = tab?.pagination ?? PaginationState()
        pagination.isLoading = pagination.isLoading || isFetching
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
            pagination: pagination,
            statusMessage: tab?.execution.statusMessage
        )
    }

    /// Whether the tab is on a page of a larger set whose size nobody has reported.
    ///
    /// Only the readout asks. Whether the pagination CONTROLS appear is a question about the tab,
    /// not about the rows currently buffered, so it is answered by `ResultStatusModel` from the tab
    /// type alone; deriving it from loaded rows made the cluster leave the layout mid-reload.
    var isPagedWithUnknownTotal: Bool {
        pagination.currentPage > 1 || rowCount >= pagination.pageSize
    }
}
