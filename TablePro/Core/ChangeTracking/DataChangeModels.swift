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
    let rowIndex: Int
    let columnIndex: Int
    let columnName: String
    let oldValue: PluginCellValue
    let newValue: PluginCellValue

    init(
        rowIndex: Int,
        columnIndex: Int,
        columnName: String,
        oldValue: PluginCellValue,
        newValue: PluginCellValue
    ) {
        self.id = UUID()
        self.rowIndex = rowIndex
        self.columnIndex = columnIndex
        self.columnName = columnName
        self.oldValue = oldValue
        self.newValue = newValue
    }
}

struct RowChange: Identifiable, Equatable {
    let id: UUID
    var rowIndex: Int
    let type: ChangeType
    var cellChanges: [CellChange]
    let originalRow: [PluginCellValue]?

    init(
        rowIndex: Int,
        type: ChangeType,
        cellChanges: [CellChange] = [],
        originalRow: [PluginCellValue]? = nil
    ) {
        self.id = UUID()
        self.rowIndex = rowIndex
        self.type = type
        self.cellChanges = cellChanges
        self.originalRow = originalRow
    }
}

struct RowChangeKey: Hashable {
    let rowIndex: Int
    let type: ChangeType
}

enum UndoAction {
    case cellEdit(
            rowIndex: Int,
            columnIndex: Int,
            columnName: String,
            previousValue: PluginCellValue,
            newValue: PluginCellValue,
            originalRow: [PluginCellValue]?
         )
    case rowInsertion(rowIndex: Int)
    case rowDeletion(rowIndex: Int, originalRow: [PluginCellValue])
    case batchRowDeletion(rows: [(rowIndex: Int, originalRow: [PluginCellValue])])
    case batchRowInsertion(rowIndices: [Int], rowValues: [[PluginCellValue]])
}
