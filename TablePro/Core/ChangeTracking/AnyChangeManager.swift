import Foundation
import Observation
import TableProPluginKit

@MainActor
protocol ChangeManaging: AnyObject {
    var hasChanges: Bool { get }
    var reloadVersion: Int { get }
    var canRedo: Bool { get }
    var rowChanges: [RowChange] { get }
    var insertedRowIndices: Set<Int> { get }
    var generatedColumns: Set<String> { get }
    func isRowDeleted(_ rowIndex: Int) -> Bool
    func recordCellChange(
        rowIndex: Int,
        columnIndex: Int,
        columnName: String,
        oldValue: PluginCellValue,
        newValue: PluginCellValue,
        originalRow: [PluginCellValue]?
    )
    func undoRowDeletion(rowIndex: Int)
    func undoRowInsertion(rowIndex: Int)
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
    var insertedRowIndices: Set<Int> { wrapped.insertedRowIndices }
    var generatedColumns: Set<String> { wrapped.generatedColumns }

    func isRowDeleted(_ rowIndex: Int) -> Bool {
        wrapped.isRowDeleted(rowIndex)
    }

    func recordCellChange(
        rowIndex: Int,
        columnIndex: Int,
        columnName: String,
        oldValue: PluginCellValue,
        newValue: PluginCellValue,
        originalRow: [PluginCellValue]
    ) {
        wrapped.recordCellChange(
            rowIndex: rowIndex,
            columnIndex: columnIndex,
            columnName: columnName,
            oldValue: oldValue,
            newValue: newValue,
            originalRow: originalRow
        )
    }

    func undoRowDeletion(rowIndex: Int) {
        wrapped.undoRowDeletion(rowIndex: rowIndex)
    }

    func undoRowInsertion(rowIndex: Int) {
        wrapped.undoRowInsertion(rowIndex: rowIndex)
    }

    init(_ manager: any ChangeManaging) {
        self.wrapped = manager
    }
}
