//
//  RowVisualIndex.swift
//  TablePro
//

import AppKit
import TableProTheme

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

    func rebuild(from changeManager: AnyChangeManager?) {
        states.removeAll(keepingCapacity: true)
        guard let changeManager else { return }

        let insertedRowIDs = changeManager.insertedRowIDs
        guard changeManager.hasChanges || !insertedRowIDs.isEmpty else { return }

        for rowChange in changeManager.rowChanges {
            states[rowChange.rowID] = Self.makeState(for: rowChange, inserted: insertedRowIDs.contains(rowChange.rowID))
        }

        for rowID in insertedRowIDs where states[rowID] == nil {
            states[rowID] = Self.insertedState
        }
    }

    func updateRow(_ rowID: RowID, from changeManager: AnyChangeManager?) {
        guard let changeManager else {
            states.removeValue(forKey: rowID)
            return
        }
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

    private static let insertedState = RowVisualState(isDeleted: false, isInserted: true, modifiedColumns: [])

    private static func makeState(for rowChange: RowChange, inserted: Bool) -> RowVisualState {
        let isDeleted = rowChange.type == .delete
        let isInserted = inserted || rowChange.type == .insert
        let modifiedColumns: Set<Int> = rowChange.type == .update
            ? Set(rowChange.cellChanges.map { $0.columnIndex })
            : []
        return RowVisualState(
            isDeleted: isDeleted,
            isInserted: isInserted,
            modifiedColumns: modifiedColumns,
            expressionColumns: expressionColumns(of: rowChange)
        )
    }

    private static func expressionColumns(of rowChange: RowChange) -> Set<Int> {
        switch rowChange.type {
        case .insert:
            rowChange.expressionColumns
        case .update:
            Set(rowChange.cellChanges.lazy.filter(\.newIsExpression).map(\.columnIndex))
        case .delete:
            []
        }
    }
}

extension RowVisualState {
    // The wash a whole row carries, read by both panes so they cannot disagree.
    @MainActor func tint(in scope: ThemeScope) -> NSColor? {
        if isDeleted { return scope.resolved[.gridDeleted] }
        if isInserted { return scope.resolved[.gridInserted] }
        return highlight.rowColor?.washColor
    }
}
