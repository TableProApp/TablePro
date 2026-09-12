import Foundation
import Observation
import TableProPluginKit

@MainActor
protocol ChangeManaging: AnyObject {
    var hasChanges: Bool { get }
    var reloadVersion: Int { get }
    var canRedo: Bool { get }
    var rowChanges: [RowChange] { get }
    var insertedRowIDs: Set<RowID> { get }
    var generatedColumns: Set<String> { get }
    func isRowDeleted(_ rowID: RowID) -> Bool
    func recordCellChange(
        rowID: RowID,
        columnIndex: Int,
        columnName: String,
        oldValue: PluginCellValue,
        newValue: PluginCellValue,
        originalRow: [PluginCellValue]?
    )
    func undoRowDeletion(rowID: RowID)
}

/// Only the data grid tracks server-computed columns; the structure and
/// inspector grids edit schema definitions, where the concept does not apply.
extension ChangeManaging {
    var generatedColumns: Set<String> { [] }
}

@Observable
@MainActor
final class AnyChangeManager {
    @ObservationIgnored private let wrapped: any ChangeManaging

    var hasChanges: Bool { wrapped.hasChanges }
    var reloadVersion: Int { wrapped.reloadVersion }
    var canRedo: Bool { wrapped.canRedo }
    var rowChanges: [RowChange] { wrapped.rowChanges }
    var insertedRowIDs: Set<RowID> { wrapped.insertedRowIDs }
    var generatedColumns: Set<String> { wrapped.generatedColumns }

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

    func undoRowDeletion(rowID: RowID) {
        wrapped.undoRowDeletion(rowID: rowID)
    }

    init(_ manager: any ChangeManaging) {
        self.wrapped = manager
    }
}
