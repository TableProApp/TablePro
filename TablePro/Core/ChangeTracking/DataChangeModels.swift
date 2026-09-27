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

struct CellChange: Identifiable, Equatable {
    let id: UUID
    let columnIndex: Int
    let columnName: String
    let oldValue: PluginCellValue
    let newValue: PluginCellValue
    let oldIsAbsent: Bool
    let newIsAbsent: Bool

    init(
        columnIndex: Int,
        columnName: String,
        oldValue: PluginCellValue,
        newValue: PluginCellValue,
        oldIsAbsent: Bool = false,
        newIsAbsent: Bool = false
    ) {
        self.id = UUID()
        self.columnIndex = columnIndex
        self.columnName = columnName
        self.oldValue = oldValue
        self.newValue = newValue
        self.oldIsAbsent = oldIsAbsent
        self.newIsAbsent = newIsAbsent
    }

    /// Whether the edit leaves the cell as it was read: the same value, and the field there or
    /// missing on both sides.
    var restoresOriginal: Bool {
        oldValue == newValue && oldIsAbsent == newIsAbsent
    }
}

struct RowChange: Identifiable, Equatable {
    let id: UUID
    let rowID: RowID
    let type: ChangeType
    var cellChanges: [CellChange]
    let originalRow: [PluginCellValue]?

    /// The columns the row has no field for: as it was read for an update or a delete, and as it
    /// stands for an insert. Empty on every engine that cannot tell a missing field from NULL.
    var absentColumns: Set<Int>

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
        sequence: Int = 0
    ) {
        self.id = UUID()
        self.rowID = rowID
        self.type = type
        self.cellChanges = cellChanges
        self.originalRow = originalRow
        self.absentColumns = absentColumns
        self.sequence = sequence
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

/// What a new row held when its insertion was undone: its values, and the fields it had none of.
/// Redoing the insertion puts back both, since the row's change is gone by then and cannot say.
struct InsertedRowImage {
    let values: [PluginCellValue]?
    let absentColumns: Set<Int>
}

enum UndoAction {
    case cellEdit(
            rowID: RowID,
            columnIndex: Int,
            columnName: String,
            previousValue: PluginCellValue,
            newValue: PluginCellValue,
            originalRow: [PluginCellValue]?,
            absence: FieldAbsence = FieldAbsence()
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
            rowAbsentColumns: [Set<Int>] = []
         )
}
