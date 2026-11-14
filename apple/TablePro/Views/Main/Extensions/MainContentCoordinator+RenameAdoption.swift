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
        for index in tabManager.tabs.indices where ids.contains(tabManager.tabs[index].id) {
            // Staged edits name the table their statements target, so a save after the rename writes to the new name.
            existingChangeManager(forTab: tabManager.tabs[index].id)?.tableName = newName
            tabManager.mutate(at: index) { tab in
                tab.tableContext.tableName = newName
                tab.title = newName
            }
            tabManager.markTabRenamed(tabManager.tabs[index].id)
            followRename(ofTableMetadataFor: tabManager.tabs[index])
            // The browse query still names the old table, so the next page, sort or filter would
            // run against a name the server no longer has.
            rebuildTableQuery(at: index)
        }
    }

    // A container's new name has to reach every tab keyed by its old one, or the next page or save
    // targets something that is gone.
    func retargetTabs(database: String, schema: String?, toDatabase: String, toSchema: String?) {
        let browseDatabase = browseDatabaseName
        for index in tabManager.tabs.indices {
            let context = tabManager.tabs[index].tableContext
            guard context.resolvedDatabaseName(browsing: browseDatabase) == database else { continue }
            if let schema, context.schemaName != schema { continue }
            tabManager.mutate(at: index) { tab in
                tab.tableContext.databaseName = toDatabase
                if schema != nil { tab.tableContext.schemaName = toSchema }
            }
            // Staged edits keep their undo history across the rename, so their schema moves without clearing them.
            if let schema, let manager = existingChangeManager(forTab: tabManager.tabs[index].id), manager.schemaName == schema {
                manager.schemaName = toSchema
            }
            followRename(ofTableMetadataFor: tabManager.tabs[index])
            rebuildTableQuery(at: index)
            // The history's change notice can land while the tab still names the old database.
            if tabManager.tabs[index].tabType == .tableHealth {
                tableHealthModels[tabManager.tabs[index].id]?.reloadHistory()
            }
        }
    }
}
