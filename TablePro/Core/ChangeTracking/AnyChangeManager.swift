import Foundation
import Observation

@MainActor
protocol ChangeManaging: AnyObject {
    var hasChanges: Bool { get }
    var reloadVersion: Int { get }
    var canRedo: Bool { get }
    var rowChanges: [RowChange] { get }
    func isRowDeleted(_ rowIndex: Int) -> Bool
    func recordCellChange(
        rowIndex: Int,
        columnIndex: Int,
        columnName: String,
        oldValue: String?,
        newValue: String?,
        originalRow: [String?]?
    )
    func undoRowDeletion(rowIndex: Int)
    func undoRowInsertion(rowIndex: Int)
    func consumeChangedRowIndices() -> Set<Int>
}

@Observable
@MainActor
final class AnyChangeManager {
    @ObservationIgnored private let wrapped: any ChangeManaging

    var hasChanges: Bool { wrapped.hasChanges }
    var reloadVersion: Int { wrapped.reloadVersion }
    var canRedo: Bool { wrapped.canRedo }
    var rowChanges: [RowChange] { wrapped.rowChanges }

    func isRowDeleted(_ rowIndex: Int) -> Bool {
        wrapped.isRowDeleted(rowIndex)
    }

    func recordCellChange(
        rowIndex: Int,
        columnIndex: Int,
        columnName: String,
        oldValue: String?,
        newValue: String?,
        originalRow: [String?]
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

    func consumeChangedRowIndices() -> Set<Int> {
        wrapped.consumeChangedRowIndices()
    }

    init(_ manager: any ChangeManaging) {
        self.wrapped = manager
    }
}
