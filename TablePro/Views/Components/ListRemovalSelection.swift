//
//  ListRemovalSelection.swift
//  TablePro
//

import Foundation

/// The selection a list keeps after rows are removed: the row that moves into the first removed
/// position, or the new last row when the removal took the tail. `NSTableView` behaves this way,
/// and `List(selection:)` left with an empty set after a removal stops registering clicks on the
/// remaining rows until something forces a redraw.
enum ListRemovalSelection {
    static func nextSelection<ID: Hashable>(afterRemoving removedIds: Set<ID>, from orderedIds: [ID]) -> Set<ID> {
        guard let firstRemoveIndex = orderedIds.firstIndex(where: { removedIds.contains($0) }) else {
            return []
        }
        let remaining = orderedIds.filter { !removedIds.contains($0) }
        guard !remaining.isEmpty else { return [] }
        return [remaining[min(firstRemoveIndex, remaining.count - 1)]]
    }
}
