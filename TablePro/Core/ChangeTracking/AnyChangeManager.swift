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
    var generatedColumns: Set<String> { get }
    var supportsFieldRemoval: Bool { get }
    func isRowDeleted(_ rowID: RowID) -> Bool
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
    func undoRowDeletion(rowID: RowID)
}

/// Only the data grid tracks server-computed columns; the structure and
/// inspector grids edit schema definitions, where the concept does not apply.
extension ChangeManaging {
    var generatedColumns: Set<String> { [] }

    var supportsFieldRemoval: Bool { false }

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
}

@MainActor
final class AnyChangeManager: ObservableObject {
    private let wrapped: any ChangeManaging

    var hasChanges: Bool { wrapped.hasChanges }
    var reloadVersion: Int { wrapped.reloadVersion }
    var canRedo: Bool { wrapped.canRedo }
    var rowChanges: [RowChange] { wrapped.rowChanges }
    var insertedRowIDs: Set<RowID> { wrapped.insertedRowIDs }
    var generatedColumns: Set<String> { wrapped.generatedColumns }
    var supportsFieldRemoval: Bool { wrapped.supportsFieldRemoval }

    func isRowDeleted(_ rowID: RowID) -> Bool {
        wrapped.isRowDeleted(rowID)
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

    func undoRowDeletion(rowID: RowID) {
        wrapped.undoRowDeletion(rowID: rowID)
    }

    init(_ manager: any ChangeManaging) {
        self.wrapped = manager
    }
}
