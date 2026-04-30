//
//  ResultSet.swift
//  TablePro
//
//  A single result set from one SQL statement execution.
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class ResultSet: Identifiable {
    let id: UUID
    var label: String
    var tableRows: TableRows
    var executionTime: TimeInterval?
    var rowsAffected: Int = 0
    var errorMessage: String?
    var statusMessage: String?
    var tableName: String?
    var isEditable: Bool = false
    var isPinned: Bool = false
    var metadataVersion: Int = 0
    var sortState = SortState()
    var pagination = PaginationState()
    var columnLayout = ColumnLayoutState()

    var resultColumns: [String] { tableRows.columns }

    init(id: UUID = UUID(), label: String, tableRows: TableRows = TableRows()) {
        self.id = id
        self.label = label
        self.tableRows = tableRows
    }
}
