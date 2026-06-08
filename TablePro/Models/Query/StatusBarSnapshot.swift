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
    let rowCount: Int
    let hasTableName: Bool
    let pagination: PaginationState
    let statusMessage: String?

    init(
        tabId: UUID?,
        tabType: TabType?,
        hasRows: Bool,
        hasColumns: Bool,
        rowCount: Int,
        hasTableName: Bool,
        pagination: PaginationState,
        statusMessage: String?
    ) {
        self.tabId = tabId
        self.tabType = tabType
        self.hasRows = hasRows
        self.hasColumns = hasColumns
        self.rowCount = rowCount
        self.hasTableName = hasTableName
        self.pagination = pagination
        self.statusMessage = statusMessage
    }

    init(tab: QueryTab?, tableRows: TableRows?) {
        self.init(
            tabId: tab?.id,
            tabType: tab?.tabType,
            hasRows: !(tableRows?.rows.isEmpty ?? true),
            hasColumns: !(tableRows?.columns.isEmpty ?? true),
            rowCount: tableRows?.rows.count ?? 0,
            hasTableName: tab?.tableContext.tableName != nil,
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
