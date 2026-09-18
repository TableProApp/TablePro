//
//  DataChangeModels.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum ChangeType: Hashable {
    case update
    case insert
    case delete
}

struct CellChange: Identifiable, Equatable {
    let id: UUID
    let columnIndex: Int
    let columnName: String
    let oldValue: PluginCellValue
    let newValue: PluginCellValue

    init(
        columnIndex: Int,
        columnName: String,
        oldValue: PluginCellValue,
        newValue: PluginCellValue
    ) {
        self.id = UUID()
        self.columnIndex = columnIndex
        self.columnName = columnName
        self.oldValue = oldValue
        self.newValue = newValue
    }
}

struct RowChange: Identifiable, Equatable {
    let id: UUID
    let rowID: RowID
    let type: ChangeType
    var cellChanges: [CellChange]
    let originalRow: [PluginCellValue]?

    /// The order the user made this change in.
    ///
    /// Not the array position. `PendingChanges` removes a cancelled change by swapping the last
    /// element into its slot, so array order stops matching edit order the first time anything is
    /// undone. Statement generation has to know which change came first, because deleting a row
    /// and reusing its unique value in a new one only works in that order.
    var sequence: Int

    init(
        rowID: RowID,
        type: ChangeType,
        cellChanges: [CellChange] = [],
        originalRow: [PluginCellValue]? = nil,
        sequence: Int = 0
    ) {
        self.id = UUID()
        self.rowID = rowID
        self.type = type
        self.cellChanges = cellChanges
        self.originalRow = originalRow
        self.sequence = sequence
    }
}

struct RowChangeKey: Hashable {
    let rowID: RowID
    let type: ChangeType
}

struct InsertedRowLocation {
    let rowID: RowID
    let storageIndex: Int
}

enum UndoAction {
    case cellEdit(
            rowID: RowID,
            columnIndex: Int,
            columnName: String,
            previousValue: PluginCellValue,
            newValue: PluginCellValue,
            originalRow: [PluginCellValue]?
         )
    case rowInsertion(rowID: RowID)
    case rowDeletion(rowID: RowID, originalRow: [PluginCellValue])
    case batchRowDeletion(rows: [(rowID: RowID, originalRow: [PluginCellValue])])
    case batchRowInsertion(rows: [InsertedRowLocation], rowValues: [[PluginCellValue]])
}
