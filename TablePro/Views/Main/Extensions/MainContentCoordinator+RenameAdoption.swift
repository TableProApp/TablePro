//
//  MainContentCoordinator+RenameAdoption.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Everything that named the object by its old name, moved onto the new one.
///
/// A rename is the one destructive-looking operation whose object survives it, so the state the
/// user built around it survives too: the tab stays open on the same rows, its filters and column
/// widths stay applied, and a favourite stays a favourite rather than pointing at a table that no
/// longer exists on every device it synced to.
extension MainContentCoordinator {
    func adoptTableRename(_ ref: DatabaseTreeTableRef, to newName: String) {
        let database = ref.database ?? browseDatabaseName
        let resolvedSchema = DatabaseManager.shared.resolvedSchemaName(ref.qualifyingSchema, for: connectionId)
        let identity = TableTabIdentity(ref: ref, browsing: browseDatabaseName, resolvedSchema: resolvedSchema)

        retitleTabs(matching: identity, to: newName)
        movePerTableSettings(
            from: ref.table.name, to: newName, database: database, schema: resolvedSchema
        )
        moveFavorite(ref, to: newName, database: ref.database)
        moveRecent(ref, to: newName)
        unstagePendingOperations(for: ref)
    }

    /// A container's new name has to reach everything keyed by its old one, or the next page, save
    /// or reconnect targets something that is gone. A schema is not exempt: its tabs, its queued
    /// operations and its per-table settings are all keyed by it too.
    func adoptContainerRename(_ ref: DatabaseContainerRef, to newName: String) {
        switch ref.kind {
        case .database:
            guard let oldDatabase = ref.database else { return }
            retargetContainer(database: oldDatabase, schema: nil, toDatabase: newName, toSchema: nil)
            SharedSidebarState.forConnection(connectionId)
                .renameRecentDatabase(from: oldDatabase, to: newName)
            FavoriteDatabasesStorage.shared.rename(
                database: oldDatabase, to: newName, connectionId: connectionId
            )
            retargetDatabaseFilter(from: oldDatabase, to: newName)
            retargetSavedConnectionDatabase(from: oldDatabase, to: newName)
            retargetBrowseCursor(from: oldDatabase, to: newName)
        case .schema:
            guard let oldSchema = ref.schema else { return }
            let database = ref.database ?? browseDatabaseName
            retargetContainer(
                database: database, schema: oldSchema, toDatabase: database, toSchema: newName
            )
            SharedSidebarState.forConnection(connectionId)
                .renameRecentSchema(database: database, from: oldSchema, to: newName)
        }
    }

    private func retitleTabs(matching identity: TableTabIdentity, to newName: String) {
        let browseDatabase = browseDatabaseName
        var renamedSelectedTab = false
        for index in tabManager.tabs.indices
        where tabManager.tabs[index].tableIdentity(browsing: browseDatabase) == identity {
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
        /// tab it is serving is one of the tabs that was renamed: comparing its bare name would
        /// point `public.orders`'s pending edits at whatever `billing.orders` just became.
        guard renamedSelectedTab else { return }
        changeManager.tableName = newName
    }

    private func movePerTableSettings(
        from oldName: String,
        to newName: String,
        database: String,
        schema: String?
    ) {
        FilterSettingsStorage.shared.renameLastFilters(
            from: oldName,
            to: newName,
            connectionId: connectionId,
            databaseName: database,
            schemaName: schema
        )
        FileColumnLayoutPersister.shared.rename(
            from: ColumnLayoutTableKey(
                connectionId: connectionId, databaseName: database, schemaName: schema, tableName: oldName
            ),
            to: ColumnLayoutTableKey(
                connectionId: connectionId, databaseName: database, schemaName: schema, tableName: newName
            )
        )
    }

    private func moveFavorite(_ ref: DatabaseTreeTableRef, to newName: String, database: String?) {
        let storage = FavoriteTablesStorage.shared
        guard storage.isFavorite(
            name: ref.table.name, schema: ref.schema, database: database, connectionId: connectionId
        ) else { return }
        storage.removeFavorite(
            name: ref.table.name, schema: ref.schema, database: database, connectionId: connectionId
        )
        storage.addFavorite(
            name: newName, schema: ref.schema, database: database, connectionId: connectionId
        )
    }

    private func moveRecent(_ ref: DatabaseTreeTableRef, to newName: String) {
        SharedSidebarState.forConnection(connectionId).renameRecentTable(
            database: ref.database, schema: ref.schema, from: ref.table.name, to: newName
        )
    }

    // MARK: - Containers

    private func retargetContainer(
        database: String,
        schema: String?,
        toDatabase: String,
        toSchema: String?
    ) {
        retargetTabs(database: database, schema: schema, toDatabase: toDatabase, toSchema: toSchema)
        retargetPendingOperations(
            database: database, schema: schema, toDatabase: toDatabase, toSchema: toSchema
        )
        FilterSettingsStorage.shared.renameScope(
            connectionId: connectionId, fromDatabase: database, fromSchema: schema,
            toDatabase: toDatabase, toSchema: toSchema
        )
        FileColumnLayoutPersister.shared.renameScope(
            connectionId: connectionId, fromDatabase: database, fromSchema: schema,
            toDatabase: toDatabase, toSchema: toSchema
        )
        retargetFavoriteTables(
            database: database, schema: schema, toDatabase: toDatabase, toSchema: toSchema
        )
    }

    private func retargetTabs(database: String, schema: String?, toDatabase: String, toSchema: String?) {
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

    /// A queued Truncate or Drop names the container it was raised in, so one left behind either
    /// misses at Save or, once something takes the old name, reaches the wrong object.
    private func retargetPendingOperations(
        database: String,
        schema: String?,
        toDatabase: String,
        toSchema: String?
    ) {
        guard let viewModel = sidebarViewModel else { return }
        func moved(_ ref: DatabaseTreeTableRef) -> DatabaseTreeTableRef {
            guard ref.database == database else { return ref }
            if let schema, ref.qualifyingSchema != schema { return ref }
            return DatabaseTreeTableRef(
                database: toDatabase,
                schema: schema == nil ? ref.schema : toSchema,
                table: ref.table
            )
        }
        let options = viewModel.tableOperationOptions
        var movedOptions: [DatabaseTreeTableRef: TableOperationOptions] = [:]
        for (ref, value) in options { movedOptions[moved(ref)] = value }
        viewModel.pendingTruncates = Set(viewModel.pendingTruncates.map(moved))
        viewModel.pendingDeletes = Set(viewModel.pendingDeletes.map(moved))
        viewModel.tableOperationOptions = movedOptions
    }

    private func retargetFavoriteTables(
        database: String,
        schema: String?,
        toDatabase: String,
        toSchema: String?
    ) {
        let storage = FavoriteTablesStorage.shared
        for entry in storage.favorites(for: connectionId) where entry.database == database {
            if let schema, entry.schema != schema { continue }
            storage.removeFavorite(
                name: entry.name, schema: entry.schema, database: entry.database, connectionId: connectionId
            )
            storage.addFavorite(
                name: entry.name,
                schema: schema == nil ? entry.schema : toSchema,
                database: toDatabase,
                connectionId: connectionId
            )
        }
    }

    private func retargetDatabaseFilter(from oldName: String, to newName: String) {
        let state = SharedSidebarState.forConnection(connectionId)
        var selected = state.databaseFilterSelected
        guard selected.remove(oldName) != nil else { return }
        selected.insert(newName)
        state.databaseFilterSelected = selected
    }

    /// The connection's saved default is what a reconnect and Reopen Last Session both use, so a
    /// database renamed out from under it leaves the connection opening onto nothing.
    private func retargetSavedConnectionDatabase(from oldName: String, to newName: String) {
        guard connection.database == oldName else { return }
        var updated = connection
        updated.database = newName
        ConnectionStorage.shared.updateConnection(updated)
    }

    /// Only reachable when another window is browsing the renamed database, because the menu keeps
    /// Rename off the container this window is on.
    private func retargetBrowseCursor(from oldName: String, to newName: String) {
        guard browseDatabaseName == oldName else { return }
        Task { await switchContainers(database: newName, schema: nil) }
    }

    /// A queued Truncate or Drop against the old name would either miss or, once a new table takes
    /// that name, reach the wrong object. The queue is dropped rather than moved, because the
    /// confirmation the user gave named the object they were looking at.
    private func unstagePendingOperations(for ref: DatabaseTreeTableRef) {
        guard let viewModel = sidebarViewModel else { return }
        guard viewModel.pendingTruncates.contains(ref) || viewModel.pendingDeletes.contains(ref) else { return }
        viewModel.pendingTruncates.remove(ref)
        viewModel.pendingDeletes.remove(ref)
        viewModel.tableOperationOptions.removeValue(forKey: ref)
    }
}
