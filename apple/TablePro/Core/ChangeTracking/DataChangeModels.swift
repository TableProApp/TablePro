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

/// Which side of a cell edit has no field at all, for an engine that tells a missing field from
/// NULL. A missing field reads `.null`, so the value alone cannot say. Every other engine keeps the
/// default, where the field is there on both sides.
struct FieldAbsence: Equatable, Sendable {
    /// The cell had no field before the edit.
    var wasAbsent = false
    /// The edit takes the field out of the row.
    var isAbsent = false
    /// The columns the row had no field for before any of its edits, kept with its first change so
    /// a rewind can leave them missing.
    var originalRow: Set<Int> = []

    var reversed: FieldAbsence {
        FieldAbsence(wasAbsent: isAbsent, isAbsent: wasAbsent, originalRow: originalRow)
    }
}

/// Whether a cell held a SQL expression before an edit and holds one after it. The value alone cannot say: an
/// expression is staged as its text, which a stored or typed value can also be.
struct ExpressionTransition: Equatable, Sendable {
    var wasExpression = false
    var isExpression = false

    var reversed: ExpressionTransition {
        ExpressionTransition(wasExpression: isExpression, isExpression: wasExpression)
    }
}

struct CellChange: Identifiable, Equatable {
    let id: UUID
    let columnIndex: Int
    let columnName: String
    let oldValue: PluginCellValue
    let newValue: PluginCellValue
    let oldIsAbsent: Bool
    let newIsAbsent: Bool
    let oldIsExpression: Bool
    /// The new value is `.text` holding SQL from `CellExpressionVocabulary`, written unquoted. Never set with
    /// `newIsAbsent`.
    let newIsExpression: Bool

    init(
        columnIndex: Int,
        columnName: String,
        oldValue: PluginCellValue,
        newValue: PluginCellValue,
        oldIsAbsent: Bool = false,
        newIsAbsent: Bool = false,
        oldIsExpression: Bool = false,
        newIsExpression: Bool = false
    ) {
        self.id = UUID()
        self.columnIndex = columnIndex
        self.columnName = columnName
        self.oldValue = oldValue
        self.newValue = newValue
        self.oldIsAbsent = oldIsAbsent
        self.newIsAbsent = newIsAbsent
        self.oldIsExpression = oldIsExpression
        self.newIsExpression = newIsExpression
    }

    /// Whether the edit leaves the cell as it was read: the same value, the field there or missing on both sides,
    /// and no expression in place of text that reads the same.
    var restoresOriginal: Bool {
        oldValue == newValue && oldIsAbsent == newIsAbsent && oldIsExpression == newIsExpression
    }
}

struct RowChange: Identifiable, Equatable {
    let id: UUID
    let rowID: RowID
    let type: ChangeType
    var cellChanges: [CellChange]
    var originalRow: [PluginCellValue]?

    /// The columns the row has no field for: as it was read for an update or a delete, and as it
    /// stands for an insert. Empty on every engine that cannot tell a missing field from NULL.
    var absentColumns: Set<Int>

    /// An insert's cells that hold a SQL expression, as the row stands. An update keeps its own on each
    /// `CellChange`.
    var expressionColumns: Set<Int>

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
        absentColumns: Set<Int> = [],
        expressionColumns: Set<Int> = [],
        sequence: Int = 0
    ) {
        self.id = UUID()
        self.rowID = rowID
        self.type = type
        self.cellChanges = cellChanges
        self.originalRow = originalRow
        self.absentColumns = absentColumns
        self.expressionColumns = expressionColumns
        self.sequence = sequence
    }

    // A value loaded after the change was recorded replaces the placeholder its pre-image captured.
    static func adoptLoadedValues(_ values: [RowID: [Int: PluginCellValue]], into changes: inout [RowChange]) {
        for index in changes.indices {
            guard let cells = values[changes[index].rowID], let row = changes[index].originalRow else { continue }
            changes[index].originalRow = completing(row, with: cells)
        }
    }

    static func completing(_ row: [PluginCellValue], with cells: [Int: PluginCellValue]) -> [PluginCellValue] {
        var row = row
        for (column, value) in cells where row.indices.contains(column) && row[column].isNull {
            row[column] = value
        }
        return row
    }

    /// The columns the row has no field for once this update is written: those it lacked, less the
    /// ones an edit gave a value, plus the ones an edit removed.
    var absentColumnsAfterUpdate: Set<Int> {
        cellChanges.reduce(into: absentColumns) { absent, cellChange in
            if cellChange.newIsAbsent {
                absent.insert(cellChange.columnIndex)
            } else {
                absent.remove(cellChange.columnIndex)
            }
        }
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

/// What a new row held when its insertion was undone: its values, the fields it had none of, and the cells that
/// held an expression. Redoing the insertion puts back all three, since the row's change is gone by then and cannot
/// say.
struct InsertedRowImage {
    let values: [PluginCellValue]?
    let absentColumns: Set<Int>
    var expressionColumns: Set<Int> = []
}

enum UndoAction {
    case cellEdit(
            rowID: RowID,
            columnIndex: Int,
            columnName: String,
            previousValue: PluginCellValue,
            newValue: PluginCellValue,
            originalRow: [PluginCellValue]?,
            absence: FieldAbsence = FieldAbsence(),
            expression: ExpressionTransition = ExpressionTransition()
         )
    case rowInsertion(rowID: RowID, restoring: InsertedRowImage? = nil)
    case rowDeletion(rowID: RowID, originalRow: [PluginCellValue], absentColumns: Set<Int> = [])
    case batchRowDeletion(
            rows: [(rowID: RowID, originalRow: [PluginCellValue])],
            absentColumns: [RowID: Set<Int>] = [:]
         )
    case batchRowInsertion(
            rows: [InsertedRowLocation],
            rowValues: [[PluginCellValue]],
            rowAbsentColumns: [Set<Int>] = [],
            rowExpressionColumns: [Set<Int>] = []
         )
}
