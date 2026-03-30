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
    var rowBuffer: RowBuffer
    var executionTime: TimeInterval?
    var rowsAffected: Int = 0
    var errorMessage: String?
    var statusMessage: String?
    var tableName: String?
    var isEditable: Bool = false
    var isPinned: Bool = false
    var resultVersion: Int = 0
    var metadataVersion: Int = 0
    var sortState = SortState()
    var pagination = PaginationState()
    var columnLayout = ColumnLayoutState()

    // Column metadata
    var columnTypes: [ColumnType] = []
    var columnDefaults: [String: String?] = [:]
    var columnForeignKeys: [String: ForeignKeyInfo] = [:]
    var columnEnumValues: [String: [String]] = [:]
    var columnNullable: [String: Bool] = [:]

    var resultColumns: [String] { rowBuffer.columns }
    var resultRows: [[String?]] { rowBuffer.rows }

    init(id: UUID = UUID(), label: String, rowBuffer: RowBuffer = RowBuffer()) {
        self.id = id
        self.label = label
        self.rowBuffer = rowBuffer
    }
}
