import Foundation

@MainActor
protocol RowDeltaApplying: AnyObject {
    func applyInsertedRows(_ indices: IndexSet)
    func applyRemovedRows(_ indices: IndexSet)
    func applyFullReplace()
    func invalidateCachesForUndoRedo()
}

extension TableViewCoordinator: RowDeltaApplying {}
