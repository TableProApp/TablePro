import Foundation

@MainActor
protocol TableViewCoordinating: AnyObject {
    func applyInsertedRows(_ indices: IndexSet)
    func applyRemovedRows(_ indices: IndexSet)
    func applyFullReplace()
    func applyDelta(_ delta: Delta)
    func invalidateCachesForUndoRedo()
    func commitActiveCellEdit()
    func beginEditing(displayRow: Int, column: Int)
}

extension TableViewCoordinator: TableViewCoordinating {}
