import Foundation

enum RowSelectionSyncDecision {
    static func shouldWriteRowBinding(previous: Set<Int>, new: Set<Int>) -> Bool {
        new != previous
    }

    static func shouldClearCellSelection(isProgrammatic: Bool, newSelection: Set<Int>, cellSelectionEmpty: Bool) -> Bool {
        !isProgrammatic && !newSelection.isEmpty && !cellSelectionEmpty
    }
}
