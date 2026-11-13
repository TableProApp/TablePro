import Foundation
import os
import TableProSyncTransport

extension SyncCoordinator {
    /// Marks existing SQL favorites and folders dirty. Separate from `markAllLocalDataDirty`
    /// because the favorite store is an actor and must be read asynchronously.
    func markSQLFavoritesDirty() async {
        let favorites = await services.sqlFavoriteManager.fetchFavorites()
        changeTracker.markDirty(.favorite, ids: favorites.map { $0.id.uuidString })

        let folders = await services.sqlFavoriteManager.fetchFolders()
        changeTracker.markDirty(.favoriteFolder, ids: folders.map { $0.id.uuidString })
    }

    /// Marks every synced record dirty so the first sync after enabling pushes the lot.
    ///
    /// Every type is marked as one batch. Marking record by record posted a change notification per
    /// record, and an account with a few hundred saved column layouts built a chain of hundreds of
    /// tasks each waiting on its predecessor until the app stopped responding to the switch that
    /// started it.
    func markAllLocalDataDirty() {
        let connections = services.connectionStorage.loadConnections()
        changeTracker.markDirty(
            .connection,
            ids: connections.filter(\.participatesInSync).map { $0.id.uuidString }
        )

        let groups = services.groupStorage.loadGroups()
        changeTracker.markDirty(.group, ids: groups.map { $0.id.uuidString })

        let tags = services.tagStorage.loadTags()
        changeTracker.markDirty(.tag, ids: tags.map { $0.id.uuidString })

        let sshProfiles = services.sshProfileStorage.loadProfiles()
        changeTracker.markDirty(.sshProfile, ids: sshProfiles.map { $0.id.uuidString })

        let credentialProfiles = services.credentialProfileStorage.loadProfiles()
        changeTracker.markDirty(.credentialProfile, ids: credentialProfiles.map { $0.id.uuidString })

        let favoriteTables = services.favoriteTablesStorage.loadFavorites()
        changeTracker.markDirty(
            .tableFavorite,
            ids: favoriteTables.map { FavoriteTablesStorage.syncId(for: $0) }
        )

        let favoriteDatabases = services.favoriteDatabasesStorage.loadFavorites()
        changeTracker.markDirty(
            .favoriteDatabase,
            ids: favoriteDatabases.map { FavoriteDatabasesStorage.syncId(for: $0) }
        )

        let tableFolderIds = tableFolderSyncIds()
        changeTracker.markDirty(.tableFolder, ids: tableFolderIds.folders)
        changeTracker.markDirty(.tableFolderItem, ids: tableFolderIds.items)

        let settingsCategories = AppSettingsCategory.synced + [CustomSlashCommandStorage.syncCategory]
        let columnLayoutCategories = columnLayouts().customizedStorageKeys()
            .map { FileColumnLayoutPersister.syncCategory(for: $0) }
        let themeCategories = themeCatalog.syncCategories
        changeTracker.markDirty(.settings, ids: settingsCategories + columnLayoutCategories + themeCategories)

        let summary = [
            "connections=\(connections.count)",
            "groups=\(groups.count)",
            "tags=\(tags.count)",
            "sshProfiles=\(sshProfiles.count)",
            "favoriteTables=\(favoriteTables.count)",
            "tableFolders=\(tableFolderIds.folders.count)",
            "settings=\(AppSettingsCategory.synced.count + 1)",
            "themes=\(themeCategories.count)"
        ].joined(separator: ", ")
        Self.logger.info("Marked all local data dirty: \(summary, privacy: .public)")
    }
}
