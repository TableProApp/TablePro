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

    func adoptContainerRename(_ ref: DatabaseContainerRef, to newName: String) {
        guard ref.kind == .database, let oldDatabase = ref.database else { return }
        SharedSidebarState.forConnection(connectionId)
            .renameRecentDatabase(from: oldDatabase, to: newName)
        FavoriteDatabasesStorage.shared.rename(
            database: oldDatabase, to: newName, connectionId: connectionId
        )
    }

    private func retitleTabs(matching identity: TableTabIdentity, to newName: String) {
        let browseDatabase = browseDatabaseName
        for index in tabManager.tabs.indices
        where tabManager.tabs[index].tableIdentity(browsing: browseDatabase) == identity {
            tabManager.mutate(at: index) { tab in
                tab.tableContext.tableName = newName
                tab.title = newName
            }
            tabManager.markTabRenamed(tabManager.tabs[index].id)
            /// The browse query still names the old table, so the next page, sort or filter would
            /// run against a name the server no longer has.
            rebuildTableQuery(at: index)
        }
        /// The change manager serves the whole window and holds the name its statements target,
        /// so a save started after the rename would still write to the old one.
        if changeManager.tableName == identity.table {
            changeManager.tableName = newName
        }
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
