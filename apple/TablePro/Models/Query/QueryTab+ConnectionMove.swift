//
//  QueryTab+ConnectionMove.swift
//  TablePro
//

import Foundation

extension QueryTab {
    // Results, execution and grid state name the old connection's rows; content is copied whole since the trip drops a file's baseline.
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
        if moved.renumbersOnCollision, moved.repeatsTitle(of: existingTabs) {
            moved.title = QueryTabManager.nextQueryTitle(existingTabs: existingTabs)
        }
        return moved
    }
}
