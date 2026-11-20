import Combine
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

        changeTracker.markDirty(.project, ids: services.projectStorage.loadProjects().map { $0.id.uuidString })

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

    // Membership made while no record could carry it was never uploaded, and the first pull that reads
    // the field would take a record without one as "in no project". So every project and every member
    // goes up once, before that pull.
    func seedProjectMembershipIfNeeded() {
        guard isProjectSyncWritable(), !metadataStorage.projectMembershipSeeded else { return }
        let projects = services.projectStorage.loadProjects()
        let connections = services.connectionStorage.loadConnections()
            .filter { $0.projectId != nil && $0.participatesInSync }
        let groups = services.groupStorage.loadGroups().filter { $0.projectId != nil }
        guard adoptCachedMembership() else { return }
        changeTracker.markDirty(.project, ids: projects.map { $0.id.uuidString })
        changeTracker.markDirty(.connection, ids: connections.map { $0.id.uuidString })
        changeTracker.markDirty(.group, ids: groups.map { $0.id.uuidString })
        metadataStorage.projectMembershipSeeded = true
        Self.logger.info(
            "Project sync is on: marked \(projects.count, privacy: .public) projects and \(connections.count + groups.count, privacy: .public) members to upload"
        )
    }

    // A copy in no project whose cached record names one another device wrote takes it, once, before the first
    // push that writes the field. Otherwise an unrelated edit waiting to go up reads as removing that project.
    // After this run, no project here against a project in the cache is a removal made on this Mac.
    private func adoptCachedMembership() -> Bool {
        let connectionStorage = services.connectionStorage
        var connections = connectionStorage.loadConnections()
        var adoptedConnections = 0
        for index in connections.indices
            where connections[index].participatesInSync && connections[index].projectId == nil && connections[index].groupId == nil {
            guard let cached = recordCache.projectId(ofConnection: connections[index].id) else { continue }
            connections[index].projectId = cached
            adoptedConnections += 1
        }
        let groupStorage = services.groupStorage
        var groups = groupStorage.loadGroups()
        var adoptedGroups = 0
        for index in groups.indices where groups[index].projectId == nil && groups[index].parentId == nil {
            guard let cached = recordCache.projectId(ofGroup: groups[index].id) else { continue }
            groups[index].projectId = cached
            adoptedGroups += 1
        }
        guard adoptedConnections + adoptedGroups > 0 else { return true }

        // The server already holds these values, so nothing here is an edit to upload.
        let wasSuppressed = changeTracker.isSuppressed
        changeTracker.isSuppressed = true
        defer { changeTracker.isSuppressed = wasSuppressed }
        guard adoptedConnections == 0 || connectionStorage.saveConnections(connections, byUser: false),
              adoptedGroups == 0 || groupStorage.saveGroups(groups)
        else {
            Self.logger.error("The projects other devices assigned were not saved, so membership waits for the next run")
            return false
        }
        services.appEvents.connectionUpdated.send(nil)
        Self.logger.info(
            "Took the project of \(adoptedConnections + adoptedGroups, privacy: .public) records from their cached copies"
        )
        return true
    }
}
