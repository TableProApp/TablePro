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

// MARK: - Array Extension

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
