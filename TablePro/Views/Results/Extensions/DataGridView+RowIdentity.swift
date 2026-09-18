//
//  DataGridView+RowIdentity.swift
//  TablePro
//

import Foundation

extension TableViewCoordinator {
    func rowID(forDisplayRow displayIndex: Int) -> RowID? {
        displayRow(at: displayIndex)?.id
    }

    func isRowDeleted(displayRow displayIndex: Int) -> Bool {
        guard let rowID = rowID(forDisplayRow: displayIndex) else { return false }
        return changeManager.isRowDeleted(rowID)
    }

    func updateVisualIndex(forDisplayRow displayIndex: Int) {
        guard let rowID = rowID(forDisplayRow: displayIndex) else { return }
        visualIndex.updateRow(rowID, from: changeManager)
    }

    /// The row's marks for a caller that has already resolved it, which every drawn cell has:
    /// resolving it again costs a `TableRows` copy per cell.
    func visualState(of displayed: Row, atDisplayRow row: Int) -> RowVisualState {
        if let delegateState = delegate?.dataGridVisualState(forRow: row) {
            return delegateState
        }
        guard !visualIndex.isEmpty || !highlightRuleSet.isEmpty else { return .empty }
        return visualIndex.visualState(for: displayed.id).highlighted(highlight(for: displayed))
    }
}
