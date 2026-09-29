import CloudKit
import Foundation
import os
import TableProSyncTransport

struct SyncPendingDeletions: Equatable {
    var connections: Set<UUID> = []
    var groups: Set<UUID> = []
    var tags: Set<UUID> = []
    var sshProfiles: Set<UUID> = []
    var credentialProfiles: Set<UUID> = []
    var tableFavorites: Set<String> = []
    var databaseFavorites: Set<String> = []
    var settingsRecordNames: Set<String> = []
    var sqlFavorites: Set<UUID> = []
    var sqlFolders: Set<UUID> = []

    static func parse(_ recordIDs: [CKRecord.ID], settings: SyncSettings) -> SyncPendingDeletions {
        var pending = SyncPendingDeletions()
        for recordID in recordIDs {
            guard let parsed = SyncRecordType.parse(recordName: recordID.recordName) else { continue }
            pending.insert(parsed.id, of: parsed.type, settings: settings)
        }
        return pending
    }

    private mutating func insert(_ id: String, of type: SyncRecordType, settings: SyncSettings) {
        guard settings.syncs(type) else { return }
        let uuid = UUID(uuidString: id)
        switch type {
        case .connection:
            if let uuid { connections.insert(uuid) }
        case .group:
            if let uuid { groups.insert(uuid) }
        case .tag:
            if let uuid { tags.insert(uuid) }
        case .sshProfile:
            if let uuid { sshProfiles.insert(uuid) }
        case .credentialProfile:
            if let uuid { credentialProfiles.insert(uuid) }
        case .tableFavorite:
            tableFavorites.insert(id)
        case .favoriteDatabase:
            databaseFavorites.insert(id)
        case .settings:
            settingsRecordNames.insert(type.recordNamePrefix + id)
        case .favorite:
            if let uuid { sqlFavorites.insert(uuid) }
        case .favoriteFolder:
            if let uuid { sqlFolders.insert(uuid) }
        }
    }
}

struct SyncRemoteDeletionEffects {
    var connectionsChanged = false
    var groupsOrTagsChanged = false
    var persistenceFailed = false
    var tableFavoriteIdsToRetire: [UUID: Set<String>] = [:]
}

extension SyncCoordinator {
    func applyRemoteDeletions(
        _ pending: SyncPendingDeletions,
        alongside tableFavorites: [FavoriteTablesStorage.FavoriteEntry]
    ) -> SyncRemoteDeletionEffects {
        var effects = SyncRemoteDeletionEffects()
        effects.connectionsChanged = !pending.connections.isEmpty
        effects.groupsOrTagsChanged = !pending.groups.isEmpty || !pending.tags.isEmpty
        effects.tableFavoriteIdsToRetire = services.favoriteTablesStorage.applyRemote(
            saved: tableFavorites,
            deletedIds: pending.tableFavorites
        )
        services.favoriteDatabasesStorage.removeFavoritesWithoutSync(ids: pending.databaseFavorites)

        let persisted = [
            applyRemoteConnectionDeletions(pending.connections),
            applyRemoteGroupDeletions(pending.groups),
            applyRemoteTagDeletions(pending.tags),
            applyRemoteSSHProfileDeletions(pending.sshProfiles),
            applyRemoteCredentialProfileDeletions(pending.credentialProfiles),
            applyRemoteColumnLayoutDeletions(pending.settingsRecordNames)
        ]
        effects.persistenceFailed = persisted.contains(false)
        return effects
    }

    private func applyRemoteConnectionDeletions(_ ids: Set<UUID>) -> Bool {
        guard !ids.isEmpty else { return true }
        var connections = services.connectionStorage.loadConnections()
        let deletedIds = ids.subtracting(connections.filter(\.localOnly).map(\.id))
        guard !deletedIds.isEmpty else { return true }
        connections.removeAll { deletedIds.contains($0.id) }
        guard services.connectionStorage.saveConnections(connections) else {
            Self.logger.error("Failed to apply remote connection deletions: persistence error")
            return false
        }
        changeTracker.discardDirty(.connection, ids: deletedIds.map(\.uuidString))
        ConnectionLocalState.purge(
            connectionIds: deletedIds,
            origin: .remote,
            favoriteTables: services.favoriteTablesStorage,
            favoriteDatabases: services.favoriteDatabasesStorage,
            sqlFavorites: services.sqlFavoriteManager,
            queryHistory: services.queryHistoryManager
        )
        return true
    }

    private func applyRemoteColumnLayoutDeletions(_ recordNames: Set<String>) -> Bool {
        guard !recordNames.isEmpty else { return true }
        let persister = columnLayouts()
        return persister.removeWithoutSync(storageKeys: persister.storageKeys(forSyncRecordNames: recordNames))
    }

    private func applyRemoteGroupDeletions(_ ids: Set<UUID>) -> Bool {
        guard !ids.isEmpty else { return true }
        var groups = services.groupStorage.loadGroups()
        groups.removeAll { ids.contains($0.id) }
        guard services.groupStorage.saveGroups(groups) else { return false }
        changeTracker.discardDirty(.group, ids: ids.map(\.uuidString))
        return true
    }

    private func applyRemoteTagDeletions(_ ids: Set<UUID>) -> Bool {
        guard !ids.isEmpty else { return true }
        var tags = services.tagStorage.loadTags()
        tags.removeAll { ids.contains($0.id) }
        guard services.tagStorage.saveTags(tags) else { return false }
        changeTracker.discardDirty(.tag, ids: ids.map(\.uuidString))
        return true
    }

    /// Unlinking reads a profile's secrets, so it runs while they still exist. Dropping the record
    /// alone left every connection using it addressing a profile id that no longer resolved, and
    /// left its keychain items with nothing able to name them.
    ///
    /// Returns false when a conversion could not be persisted, which withholds the pull token: the
    /// alternative is acknowledging a delete whose connections still point at the profile, with the
    /// conversion lost and no tombstone left to replay it.
    private func applyRemoteSSHProfileDeletions(_ profileIds: Set<UUID>) -> Bool {
        guard !profileIds.isEmpty else { return true }

        var profiles = services.sshProfileStorage.loadProfiles()
        let deleted = profiles.filter { profileIds.contains($0.id) }
        profiles.removeAll { profileIds.contains($0.id) }

        for profile in deleted where !services.sshProfileStorage.unlinkConnections(fromProfile: profile) {
            Self.logger.error(
                "Kept SSH profile \(profile.id.uuidString, privacy: .public): its connections could not be converted"
            )
            return false
        }
        guard services.sshProfileStorage.saveProfilesWithoutSync(profiles) else { return false }
        changeTracker.discardDirty(.sshProfile, ids: profileIds.map(\.uuidString))
        for profile in deleted {
            services.sshProfileStorage.deleteSecrets(for: profile.id)
        }
        return true
    }

    /// A profile deleted on another Mac hands its credentials to the connections using it here
    /// too, so they keep connecting rather than losing the password the link took away.
    private func applyRemoteCredentialProfileDeletions(_ profileIds: Set<UUID>) -> Bool {
        guard !profileIds.isEmpty else { return true }

        var profiles = services.credentialProfileStorage.loadProfiles()
        let deleted = profiles.filter { profileIds.contains($0.id) }
        profiles.removeAll { profileIds.contains($0.id) }

        for profile in deleted where !services.credentialProfileStorage.unlinkConnections(from: profile) {
            Self.logger.error(
                "Kept credential profile \(profile.id.uuidString, privacy: .public): its connections could not be converted"
            )
            return false
        }
        guard services.credentialProfileStorage.saveProfilesWithoutSync(profiles) else { return false }
        changeTracker.discardDirty(.credentialProfile, ids: profileIds.map(\.uuidString))
        for profile in deleted {
            services.credentialProfileStorage.deleteSecrets(for: profile)
        }
        return true
    }
}
