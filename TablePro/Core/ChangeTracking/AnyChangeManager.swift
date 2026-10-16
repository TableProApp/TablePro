import Combine
import Foundation
import TableProPluginKit

@MainActor
protocol ChangeManaging: AnyObject {
    var hasChanges: Bool { get }
    var reloadVersion: Int { get }
    var canRedo: Bool { get }
    var rowChanges: [RowChange] { get }
    var insertedRowIDs: Set<RowID> { get }
    var deletedRowIDs: Set<RowID> { get }
    var modifiedCells: [RowID: Set<Int>] { get }
    var generatedColumns: Set<String> { get }
    var supportsFieldRemoval: Bool { get }
    var cellWriterSupport: CellWriterSupport { get }
    func isRowDeleted(_ rowID: RowID) -> Bool
    func isExpression(rowID: RowID, columnIndex: Int) -> Bool
    func expressionColumns(forRow rowID: RowID) -> Set<Int>
    func recordCellChange(
        rowID: RowID,
        columnIndex: Int,
        columnName: String,
        oldValue: PluginCellValue,
        newValue: PluginCellValue,
        originalRow: [PluginCellValue]?
    )
    func recordCellChange(
        rowID: RowID,
        columnIndex: Int,
        columnName: String,
        oldValue: PluginCellValue,
        newValue: PluginCellValue,
        originalRow: [PluginCellValue]?,
        absence: FieldAbsence
    )
    func recordCellChange(
        rowID: RowID,
        columnIndex: Int,
        columnName: String,
        oldValue: PluginCellValue,
        newValue: PluginCellValue,
        originalRow: [PluginCellValue]?,
        absence: FieldAbsence,
        isExpression: Bool
    )
    func undoRowDeletion(rowID: RowID)
}

/// Only the data grid tracks server-computed columns; the structure and
/// inspector grids edit schema definitions, where the concept does not apply.
extension ChangeManaging {
    var generatedColumns: Set<String> { [] }

    var deletedRowIDs: Set<RowID> { [] }

    var modifiedCells: [RowID: Set<Int>] { [:] }

    var supportsFieldRemoval: Bool { false }

    var cellWriterSupport: CellWriterSupport { .none }

    func isExpression(rowID: RowID, columnIndex: Int) -> Bool { false }

    func expressionColumns(forRow rowID: RowID) -> Set<Int> { [] }

    /// Only the data grid can show a row without a field; every other grid records the value.
    func recordCellChange(
        rowID: RowID,
        columnIndex: Int,
        columnName: String,
        oldValue: PluginCellValue,
        newValue: PluginCellValue,
        originalRow: [PluginCellValue]?,
        absence: FieldAbsence
    ) {
        recordCellChange(
            rowID: rowID,
            columnIndex: columnIndex,
            columnName: columnName,
            oldValue: oldValue,
            newValue: newValue,
            originalRow: originalRow
        )
    }

    /// Only the data grid writes SQL expressions; `cellWriterSupport` keeps every other grid from offering one.
    func recordCellChange(
        rowID: RowID,
        columnIndex: Int,
        columnName: String,
        oldValue: PluginCellValue,
        newValue: PluginCellValue,
        originalRow: [PluginCellValue]?,
        absence: FieldAbsence,
        isExpression: Bool
    ) {
        recordCellChange(
            rowID: rowID,
            columnIndex: columnIndex,
            columnName: columnName,
            oldValue: oldValue,
            newValue: newValue,
            originalRow: originalRow,
            absence: absence
        )
    }
}

@MainActor
final class AnyChangeManager: ObservableObject {
    private let wrapped: any ChangeManaging

    var hasChanges: Bool { wrapped.hasChanges }
    var reloadVersion: Int { wrapped.reloadVersion }
    var canRedo: Bool { wrapped.canRedo }
    var rowChanges: [RowChange] { wrapped.rowChanges }
    var insertedRowIDs: Set<RowID> { wrapped.insertedRowIDs }
    var deletedRowIDs: Set<RowID> { wrapped.deletedRowIDs }
    var modifiedCells: [RowID: Set<Int>] { wrapped.modifiedCells }
    var generatedColumns: Set<String> { wrapped.generatedColumns }
    var supportsFieldRemoval: Bool { wrapped.supportsFieldRemoval }
    var cellWriterSupport: CellWriterSupport { wrapped.cellWriterSupport }

    func isRowDeleted(_ rowID: RowID) -> Bool {
        wrapped.isRowDeleted(rowID)
    }

    func isExpression(rowID: RowID, columnIndex: Int) -> Bool {
        wrapped.isExpression(rowID: rowID, columnIndex: columnIndex)
    }

    func expressionColumns(forRow rowID: RowID) -> Set<Int> {
        wrapped.expressionColumns(forRow: rowID)
    }

    func recordCellChange(
        rowID: RowID,
        columnIndex: Int,
        columnName: String,
        oldValue: PluginCellValue,
        newValue: PluginCellValue,
        originalRow: [PluginCellValue]
    ) {
        wrapped.recordCellChange(
            rowID: rowID,
            columnIndex: columnIndex,
            columnName: columnName,
            oldValue: oldValue,
            newValue: newValue,
            originalRow: originalRow
        )
    }

    func recordCellChange(
        rowID: RowID,
        columnIndex: Int,
        columnName: String,
        oldValue: PluginCellValue,
        newValue: PluginCellValue,
        originalRow: [PluginCellValue],
        absence: FieldAbsence
    ) {
        wrapped.recordCellChange(
            rowID: rowID,
            columnIndex: columnIndex,
            columnName: columnName,
            oldValue: oldValue,
            newValue: newValue,
            originalRow: originalRow,
            absence: absence
        )
    }

    func recordCellChange(
        rowID: RowID,
        columnIndex: Int,
        columnName: String,
        oldValue: PluginCellValue,
        newValue: PluginCellValue,
        originalRow: [PluginCellValue],
        absence: FieldAbsence,
        isExpression: Bool
    ) {
        wrapped.recordCellChange(
            rowID: rowID,
            columnIndex: columnIndex,
            columnName: columnName,
            oldValue: oldValue,
            newValue: newValue,
            originalRow: originalRow,
            absence: absence,
            isExpression: isExpression
        )
    }

    func undoRowDeletion(rowID: RowID) {
        wrapped.undoRowDeletion(rowID: rowID)
    }

    init(_ manager: any ChangeManaging) {
        self.wrapped = manager
    }
}
