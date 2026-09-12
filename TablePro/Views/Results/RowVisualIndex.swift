//
//  RowVisualIndex.swift
//  TablePro
//

import Foundation

@MainActor
final class RowVisualIndex {
    private var states: [RowID: RowVisualState] = [:]

    var isEmpty: Bool { states.isEmpty }

    func visualState(for rowID: RowID) -> RowVisualState {
        states[rowID] ?? .empty
    }

    func clear() {
        states.removeAll(keepingCapacity: true)
    }

    func rebuild(from changeManager: AnyChangeManager) {
        states.removeAll(keepingCapacity: true)

        let insertedRowIDs = changeManager.insertedRowIDs
        guard changeManager.hasChanges || !insertedRowIDs.isEmpty else { return }

        for rowChange in changeManager.rowChanges {
            states[rowChange.rowID] = Self.makeState(
                for: rowChange,
                inserted: insertedRowIDs.contains(rowChange.rowID)
            )
        }

        for rowID in insertedRowIDs where states[rowID] == nil {
            states[rowID] = Self.insertedState
        }
    }

    func updateRow(_ rowID: RowID, from changeManager: AnyChangeManager) {
        let isInserted = changeManager.insertedRowIDs.contains(rowID)

        if let rowChange = changeManager.rowChanges.first(where: { $0.rowID == rowID }) {
            states[rowID] = Self.makeState(for: rowChange, inserted: isInserted)
            return
        }

        if isInserted {
            states[rowID] = Self.insertedState
        } else {
            states.removeValue(forKey: rowID)
        }
    }

    private static let insertedState = RowVisualState(
        isDeleted: false,
        isInserted: true,
        modifiedColumns: []
    )

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
}
