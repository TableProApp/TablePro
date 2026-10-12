//
//  QueryTab+ConnectionMove.swift
//  TablePro
//

import Foundation

extension QueryTab {
    /// The persisted round trip drops results, execution and grid state, which name the old
    /// connection's rows. `content` is copied whole because that trip drops a file's saved baseline.
    @MainActor
    func movedToConnection(
        databaseName: String,
        schemaName: String?,
        existingTabs: [QueryTab],
        defaultPageSize: Int
    ) -> QueryTab {
        var moved = QueryTab(from: toPersistedTab(), defaultPageSize: defaultPageSize)
        moved.content = content
        moved.hasUserInteraction = hasUserInteraction
        moved.tableContext = TabTableContext(databaseName: databaseName, schemaName: schemaName)
        moved.columnLayout = ColumnLayoutState()
        moved.sortState = SortState()
        moved.pendingRestoredSort = nil
        moved.restoredSortSource = .unset
        if Self.isDefaultQueryTitle(title),
           existingTabs.contains(where: { $0.id != id && $0.tabType == .query && $0.title == title }) {
            moved.title = QueryTabManager.nextQueryTitle(existingTabs: existingTabs)
        }
        return moved
    }

    /// Only the numbered titles the app hands out are renumbered; a typed title or a file name is
    /// the user's, and two tabs may share it.
    static func isDefaultQueryTitle(_ title: String) -> Bool {
        guard title.hasPrefix("Query ") else { return false }
        return Int(title.dropFirst(6)) != nil
    }
}
