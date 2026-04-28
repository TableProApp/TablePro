//
//  DataChangeModels.swift
//  TablePro
//
//  Pure data models for tracking data changes.
//  No business logic - just structures for representing change state.
//

import Foundation

/// Represents a type of data change
enum ChangeType: Hashable {
    case update
    case insert
    case delete
}

/// Represents a single cell change
struct CellChange: Identifiable, Equatable {
    let id: UUID
    let rowIndex: Int
    let columnIndex: Int
    let columnName: String
    let oldValue: String?
    let newValue: String?

    init(
        rowIndex: Int,
        columnIndex: Int,
        columnName: String,
        oldValue: String?,
        newValue: String?
    ) {
        self.id = UUID()
        self.rowIndex = rowIndex
        self.columnIndex = columnIndex
        self.columnName = columnName
        self.oldValue = oldValue
        self.newValue = newValue
    }
}

/// Represents a row-level change
struct RowChange: Identifiable, Equatable {
    let id: UUID
    var rowIndex: Int
    let type: ChangeType
    var cellChanges: [CellChange]
    let originalRow: [String?]?

    init(
        rowIndex: Int,
        type: ChangeType,
        cellChanges: [CellChange] = [],
        originalRow: [String?]? = nil
    ) {
        self.id = UUID()
        self.rowIndex = rowIndex
        self.type = type
        self.cellChanges = cellChanges
        self.originalRow = originalRow
    }
}

/// Composite key for O(1) lookup of RowChange by (rowIndex, type)
struct RowChangeKey: Hashable {
    let rowIndex: Int
    let type: ChangeType
}

/// Represents an action that can be undone
enum UndoAction {
    case cellEdit(
            rowIndex: Int,
            columnIndex: Int,
            columnName: String,
            previousValue: String?,
            newValue: String?,
            originalRow: [String?]?
         )
    case rowInsertion(rowIndex: Int)
    case rowDeletion(rowIndex: Int, originalRow: [String?])
    /// Batch deletion of multiple rows (for undo as a single action)
    case batchRowDeletion(rows: [(rowIndex: Int, originalRow: [String?])])
    /// Batch insertion undo - when user deletes multiple inserted rows at once
    case batchRowInsertion(rowIndices: [Int], rowValues: [[String?]])
}

// Note: TabChangeSnapshot is defined in QueryTab.swift

// MARK: - Array Extension

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
