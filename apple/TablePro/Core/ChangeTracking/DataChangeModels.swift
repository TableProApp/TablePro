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
    /// The new value is `.text` holding SQL from `CellExpressionVocabulary`, or `PluginCellValue.columnDefault`,
    /// written unquoted. Never set with `newIsAbsent`.
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

    func followed(by later: CellChange) -> CellChange {
        CellChange(
            columnIndex: columnIndex,
            columnName: later.columnName,
            oldValue: oldValue,
            newValue: later.newValue,
            oldIsAbsent: oldIsAbsent,
            newIsAbsent: later.newIsAbsent,
            oldIsExpression: oldIsExpression,
            newIsExpression: later.newIsExpression
        )
    }
}

// A cell's old value is the cell as this run found it, not as the row was read.
struct UpdateRun: Equatable {
    let sequence: Int
    let action: Int
    var cellChanges: [CellChange]

    func holds(_ columnIndex: Int) -> Bool {
        cellChanges.contains { $0.columnIndex == columnIndex }
    }

    func writesExpression(into columns: Set<Int>) -> Bool {
        cellChanges.contains { $0.newIsExpression && columns.contains($0.columnIndex) }
    }

    mutating func write(_ cellChange: CellChange) {
        guard let index = cellChanges.firstIndex(where: { $0.columnIndex == cellChange.columnIndex }) else {
            cellChanges.append(cellChange)
            return
        }
        let written = cellChanges[index].followed(by: cellChange)
        if written.restoresOriginal {
            cellChanges.remove(at: index)
        } else {
            cellChanges[index] = written
        }
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

    /// An insert's cells that hold a SQL expression or the column default, as the row stands. An update keeps its own
    /// on each `CellChange`.
    var expressionColumns: Set<Int>

    /// The order the user made this change in.
    ///
    /// Not the array position. `PendingChanges` removes a cancelled change by swapping the last
    /// element into its slot, so array order stops matching edit order the first time anything is
    /// undone. Statement generation has to know which change came first, because deleting a row
    /// and reusing its unique value in a new one only works in that order.
    var sequence: Int

    // An update's edits in the order they were made. Empty reads as one run at `sequence`.
    var runs: [UpdateRun]

    init(
        rowID: RowID,
        type: ChangeType,
        cellChanges: [CellChange] = [],
        originalRow: [PluginCellValue]? = nil,
        absentColumns: Set<Int> = [],
        expressionColumns: Set<Int> = [],
        sequence: Int = 0,
        runs: [UpdateRun] = []
    ) {
        self.id = UUID()
        self.rowID = rowID
        self.type = type
        self.cellChanges = cellChanges
        self.originalRow = originalRow
        self.absentColumns = absentColumns
        self.expressionColumns = expressionColumns
        self.sequence = sequence
        self.runs = runs
    }

    // A row keeps one UPDATE at its first run when a later step could not find it: with no key, a keyless match fails
    // once the server rewrites a column on the first UPDATE, and an earlier run's SQL in a key is not the key it wrote.
    static func saveSteps(_ changes: [RowChange], keyColumns: Set<Int>) -> [RowChange] {
        var steps: [(step: RowChange, source: Int)] = []
        for (source, change) in changes.enumerated() {
            guard change.type == .update, let first = change.runs.first else {
                steps.append((change, source))
                continue
            }
            guard !keyColumns.isEmpty, change.runs.count > 1, var row = change.originalRow,
                  !change.runs.dropLast().contains(where: { $0.writesExpression(into: keyColumns) })
            else {
                var placed = change
                placed.sequence = first.sequence
                steps.append((placed, source))
                continue
            }
            var absent = change.absentColumns
            for run in change.runs {
                steps.append((
                    RowChange(
                        rowID: change.rowID, type: .update, cellChanges: run.cellChanges, originalRow: row,
                        absentColumns: absent, expressionColumns: change.expressionColumns, sequence: run.sequence
                    ),
                    source
                ))
                for cellChange in run.cellChanges {
                    if row.indices.contains(cellChange.columnIndex) {
                        row[cellChange.columnIndex] = cellChange.newValue
                    }
                    if cellChange.newIsAbsent {
                        absent.insert(cellChange.columnIndex)
                    } else {
                        absent.remove(cellChange.columnIndex)
                    }
                }
            }
        }

        let ordered = steps.enumerated()
            .sorted { ($0.element.step.sequence, $0.offset) < ($1.element.step.sequence, $1.offset) }
            .map(\.element)
        // Two runs with nothing left between them, once a change recorded there was cancelled, are one UPDATE.
        var merged: [(step: RowChange, source: Int)] = []
        for entry in ordered {
            if let last = merged.last, last.source == entry.source, entry.step.type == .update {
                merged[merged.count - 1].step = last.step.followed(by: entry.step)
            } else {
                merged.append(entry)
            }
        }
        return merged.map(\.step)
    }

    private func followed(by later: RowChange) -> RowChange {
        var cells = cellChanges
        for cellChange in later.cellChanges {
            if let index = cells.firstIndex(where: { $0.columnIndex == cellChange.columnIndex }) {
                cells[index] = cells[index].followed(by: cellChange)
            } else {
                cells.append(cellChange)
            }
        }
        return RowChange(
            rowID: rowID, type: type, cellChanges: cells, originalRow: originalRow,
            absentColumns: absentColumns, expressionColumns: expressionColumns, sequence: sequence
        )
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
