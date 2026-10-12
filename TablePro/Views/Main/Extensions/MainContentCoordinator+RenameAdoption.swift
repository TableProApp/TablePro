//
//  MainContentCoordinator+RenameAdoption.swift
//  TablePro
//

import Foundation

/// A window's tabs moved onto an object's or a container's new name.
///
/// A rename is the one destructive-looking operation whose object survives it, so the tab stays open
/// on the same rows with its filters and column widths applied. What the connection keeps about the
/// object, its favorites, recents, per-table settings and queued operations, moves once in
/// `CatalogEditAdoption`; this is the part every window hosting the connection does for itself.
extension MainContentCoordinator {
    func retitleTabs(ids: Set<UUID>, to newName: String) {
        guard !ids.isEmpty else { return }
        var renamedSelectedTab = false
        for index in tabManager.tabs.indices where ids.contains(tabManager.tabs[index].id) {
            if tabManager.tabs[index].id == tabManager.selectedTabId { renamedSelectedTab = true }
            tabManager.mutate(at: index) { tab in
                tab.tableContext.tableName = newName
                tab.title = newName
            }
            tabManager.markTabRenamed(tabManager.tabs[index].id)
            /// The browse query still names the old table, so the next page, sort or filter would
            /// run against a name the server no longer has.
            rebuildTableQuery(at: index)
        }
        /// One change manager serves the whole window and holds the name its statements target, so
        /// a save started after the rename would still write to the old one. It moves only when the
        /// tab it is serving is one of the tabs that was renamed.
        guard renamedSelectedTab else { return }
        changeManager.tableName = newName
    }

    /// A container's new name has to reach every tab keyed by its old one, or the next page or save
    /// targets something that is gone.
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
            rebuildTableQuery(at: index)
        }
    }
}
