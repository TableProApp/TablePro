//
//  MainContentCoordinator+RenameAdoption.swift
//  TablePro
//

import Foundation

// A window's tabs moved onto an object's or a container's new name.
//
// A rename is the one destructive-looking operation whose object survives it, so the tab stays open
// on the same rows with its filters and column widths applied. What the connection keeps about the
// object, its favorites, recents, per-table settings and queued operations, moves once in
// `CatalogEditAdoption`; this is the part every window hosting the connection does for itself.
extension MainContentCoordinator {
    func retitleTabs(ids: Set<UUID>, to newName: String) {
        guard !ids.isEmpty else { return }
        let databaseType = connection.type
        for index in tabManager.tabs.indices where ids.contains(tabManager.tabs[index].id) {
            // Staged edits name the table their statements target, so a save after the rename writes to the new name.
            existingChangeManager(forTab: tabManager.tabs[index].id)?.tableName = newName
            tabManager.mutate(at: index) { tab in
                tab.tableContext.tableName = newName
                // Built as the window title builds it, or the strip drops the schema the window keeps.
                if tab.tabType == .table {
                    tab.title = QueryTabManager.tabTitle(
                        name: newName, schema: tab.tableContext.schemaName, databaseType: databaseType
                    )
                }
            }
            tabManager.markTabRenamed(tabManager.tabs[index].id)
            followRename(ofTableMetadataFor: tabManager.tabs[index])
            followRename(ofCatalogPageFor: tabManager.tabs[index])
            // The browse query still names the old table, so the next page, sort or filter would
            // run against a name the server no longer has.
            rebuildTableQuery(at: index)
        }
    }

    // A container's new name has to reach every tab keyed by its old one, or the next page or save
    // targets something that is gone.
    func retargetTabs(database: String, schema: String?, toDatabase: String, toSchema: String?) {
        let browseDatabase = browseDatabaseName
        let databaseType = connection.type
        for index in tabManager.tabs.indices {
            let context = tabManager.tabs[index].tableContext
            guard context.resolvedDatabaseName(browsing: browseDatabase) == database else { continue }
            if let schema, context.schemaName != schema { continue }
            tabManager.mutate(at: index) { tab in
                tab.tableContext.databaseName = toDatabase
                if schema != nil { tab.tableContext.schemaName = toSchema }
                // Only a table tab's title is built from its schema; a query tab's is a number or the user's name.
                if tab.tabType == .table, let tableName = tab.tableContext.tableName {
                    tab.title = QueryTabManager.tabTitle(
                        name: tableName, schema: tab.tableContext.schemaName, databaseType: databaseType
                    )
                }
            }
            if tabManager.tabs[index].tabType == .table {
                tabManager.markTabRenamed(tabManager.tabs[index].id)
            }
            // Staged edits keep their undo history across the rename, so their schema moves without clearing them.
            if let schema, let manager = existingChangeManager(forTab: tabManager.tabs[index].id), manager.schemaName == schema {
                manager.schemaName = toSchema
            }
            followRename(ofTableMetadataFor: tabManager.tabs[index])
            followRename(ofCatalogPageFor: tabManager.tabs[index])
            // A query tab keeps the table its last run read, and rebuilding would replace the user's SQL with a browse query.
            if tabManager.tabs[index].tabType == .table {
                rebuildTableQuery(at: index)
            }
            // The history's change notice can land while the tab still names the old database.
            if tabManager.tabs[index].tabType == .tableHealth {
                tableHealthModels[tabManager.tabs[index].id]?.reloadHistory()
            }
        }
    }
}
