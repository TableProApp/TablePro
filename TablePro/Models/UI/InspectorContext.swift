//
//  InspectorContext.swift
//  TablePro
//
//  Lightweight struct holding inspector panel data, passed directly
//  from MainContentView through the view hierarchy instead of being
//  cached in RightPanelState.
//

import Foundation

struct InspectorContext {
    let tableName: String?
    let tableMetadata: TableMetadata?
    let selectedRowData: [(column: String, value: String?, type: String)]?
    let isEditable: Bool
    let isRowDeleted: Bool
    let currentQuery: String?
    let queryResults: String?
    /// The same row the details tab shows, carried as raw cell values for the JSON tab.
    let jsonRow: JSONRowSnapshot?

    static let empty = InspectorContext(
        tableName: nil,
        tableMetadata: nil,
        selectedRowData: nil,
        isEditable: false,
        isRowDeleted: false,
        currentQuery: nil,
        queryResults: nil,
        jsonRow: nil
    )
}
