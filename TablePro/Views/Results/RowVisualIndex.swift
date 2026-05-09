//
//  RowVisualIndex.swift
//  TablePro
//

import Foundation

@MainActor
final class RowVisualIndex {
    private var states: [Int: RowVisualState] = [:]

    func visualState(for row: Int) -> RowVisualState {
        states[row] ?? .empty
    }

    func clear() {
        states.removeAll(keepingCapacity: true)
    }

    func rebuild(from changeManager: AnyChangeManager, sortedIDs: [RowID]?) {
        states.removeAll(keepingCapacity: true)

        let insertedRowIndices = Self.insertedRowIndices(
            from: changeManager,
            sortedIDs: sortedIDs
        )

        if !changeManager.hasChanges && insertedRowIndices.isEmpty {
            return
        }

        for rowChange in changeManager.rowChanges {
            states[rowChange.rowIndex] = Self.makeState(
                for: rowChange,
                inserted: insertedRowIndices.contains(rowChange.rowIndex)
            )
        }

        for rowIndex in insertedRowIndices where states[rowIndex] == nil {
            states[rowIndex] = RowVisualState(
                isDeleted: false,
                isInserted: true,
                modifiedColumns: []
            )
        }
    }

    func updateRow(_ rowIndex: Int, from changeManager: AnyChangeManager, sortedIDs: [RowID]?) {
        let isInsertedDisplay = Self.isRowInsertedAtDisplayIndex(
            rowIndex,
            changeManager: changeManager,
            sortedIDs: sortedIDs
        )

        if let rowChange = changeManager.rowChanges.first(where: { $0.rowIndex == rowIndex }) {
            states[rowIndex] = Self.makeState(for: rowChange, inserted: isInsertedDisplay)
            return
        }

        if isInsertedDisplay {
            states[rowIndex] = RowVisualState(
                isDeleted: false,
                isInserted: true,
                modifiedColumns: []
            )
        } else {
            states.removeValue(forKey: rowIndex)
        }
    }

    private static func makeState(for rowChange: RowChange, inserted: Bool) -> RowVisualState {
        let isDeleted = rowChange.type == .delete
        let isInserted = inserted || rowChange.type == .insert
        let modifiedColumns: Set<Int> = rowChange.type == .update
            ? Set(rowChange.cellChanges.map { $0.columnIndex })
            : []
        return RowVisualState(
            isDeleted: isDeleted,
            isInserted: isInserted,
            modifiedColumns: modifiedColumns
        )
    }

    private static func insertedRowIndices(
        from changeManager: AnyChangeManager,
        sortedIDs: [RowID]?
    ) -> Set<Int> {
        guard let sortedIDs else { return changeManager.insertedRowIndices }
        var indices = Set<Int>()
        for (displayIndex, id) in sortedIDs.enumerated() where id.isInserted {
            indices.insert(displayIndex)
        }
        return indices
    }

    private static func isRowInsertedAtDisplayIndex(
        _ rowIndex: Int,
        changeManager: AnyChangeManager,
        sortedIDs: [RowID]?
    ) -> Bool {
        if let sortedIDs {
            guard rowIndex >= 0, rowIndex < sortedIDs.count else { return false }
            return sortedIDs[rowIndex].isInserted
        }
        return changeManager.insertedRowIndices.contains(rowIndex)
    }
}
