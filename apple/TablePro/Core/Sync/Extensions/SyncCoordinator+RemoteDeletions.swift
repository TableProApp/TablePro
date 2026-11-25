import CloudKit
import Foundation
import os
import TableProConnectionLibrary
import TableProSyncTransport

struct SyncPendingDeletions: Equatable {
    var connections: Set<UUID> = []
    var groups: Set<UUID> = []
    var tags: Set<UUID> = []
    var projects: Set<UUID> = []
    var sshProfiles: Set<UUID> = []
    var credentialProfiles: Set<UUID> = []
    var tableFavorites: Set<String> = []
    var databaseFavorites: Set<String> = []
    var settingsRecordNames: Set<String> = []
    var sqlFavorites: Set<UUID> = []
    var sqlFolders: Set<UUID> = []
    var tableFolders: Set<UUID> = []
    var tableFolderItems: Set<String> = []

    // `readsProjects` false leaves a project alone: until the type syncs, this Mac's projects are its own.
    static func parse(
        _ recordIDs: [CKRecord.ID],
        settings: SyncSettings,
        readsProjects: Bool = SyncSchemaGate.isProjectSyncWritable
    ) -> SyncPendingDeletions {
        var pending = SyncPendingDeletions()
        for recordID in recordIDs {
            guard let parsed = SyncRecordType.parse(recordName: recordID.recordName) else { continue }
            if parsed.type == .project, !readsProjects { continue }
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
        case .tableFolder:
            if let uuid { tableFolders.insert(uuid) }
        case .tableFolderItem:
            tableFolderItems.insert(id)
        case .project:
            if let uuid { projects.insert(uuid) }
        }
    }
}

// The library as it stood before a pull, read only when the pull deletes a group.
struct SyncMembershipBeforePull {
    let connections: [DatabaseConnection]
    let groups: [ConnectionGroup]
    // The records whose own project this pull set, which a group's deletion leaves as sent.
    let connectionsWithOwnProject: Set<UUID>
    let groupsWithOwnProject: Set<UUID>
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
        alongside tableFavorites: [FavoriteTablesStorage.FavoriteEntry],
        membershipBefore: SyncMembershipBeforePull? = nil
    ) -> SyncRemoteDeletionEffects {
        var effects = SyncRemoteDeletionEffects()
        effects.connectionsChanged = !pending.connections.isEmpty
        effects.groupsOrTagsChanged = !pending.groups.isEmpty || !pending.tags.isEmpty || !pending.projects.isEmpty
        effects.tableFavoriteIdsToRetire = services.favoriteTablesStorage.applyRemote(
            saved: tableFavorites,
            deletedIds: pending.tableFavorites
        )
        services.favoriteDatabasesStorage.removeFavoritesWithoutSync(ids: pending.databaseFavorites)

        let persisted = [
            applyRemoteConnectionDeletions(pending.connections),
            applyRemoteGroupDeletions(pending.groups, membershipBefore: membershipBefore),
            applyRemoteTagDeletions(pending.tags),
            applyRemoteProjectDeletions(pending.projects),
            applyRemoteSSHProfileDeletions(pending.sshProfiles),
            applyRemoteCredentialProfileDeletions(pending.credentialProfiles),
            applyRemoteColumnLayoutDeletions(pending.settingsRecordNames),
            applyRemoteThemeDeletions(pending.settingsRecordNames)
        ]
        effects.persistenceFailed = persisted.contains(false)
        applyRemoteTableFolderDeletions(folderIds: pending.tableFolders, itemSyncIds: pending.tableFolderItems)
        return effects
    }

    // A deletion applies by id: a copy this Mac cannot read goes when its standing says it syncs, never when Local only.
    private func applyRemoteConnectionDeletions(_ ids: Set<UUID>) -> Bool {
        guard !ids.isEmpty else { return true }
        var connections = services.connectionStorage.loadConnections()
        let unreadable = ids.intersection(services.connectionStorage.unreadableConnectionIds)
        let removedUnreadable = metadataStorage.unreadableConnectionsRemoved(byDeletionOf: unreadable)
        let deletedIds = ids
            .subtracting(connections.filter(\.localOnly).map(\.id))
            .subtracting(unreadable)
            .union(removedUnreadable)
        guard !deletedIds.isEmpty else { return true }
        let removed = connections.filter { deletedIds.contains($0.id) }
        connections.removeAll { deletedIds.contains($0.id) }
        guard services.connectionStorage.saveConnections(
            connections,
            byUser: false,
            removingUnreadable: removedUnreadable
        ) else {
            Self.logger.error("Failed to apply remote connection deletions: persistence error")
            return false
        }
        changeTracker.discardDirty(.connection, ids: deletedIds.map(\.uuidString))
        forgetHeldChanges(ofConnections: removedUnreadable)
        services.connectionStorage.deleteSecrets(of: removed, origin: .remote)
        services.connectionStorage.deleteSecrets(ofUnreadable: removedUnreadable)
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

    func membershipBeforePull(bringing records: [CKRecord], readsProjects: Bool) -> SyncMembershipBeforePull {
        func ids(of type: SyncRecordType) -> Set<UUID> {
            guard readsProjects else { return [] }
            return Set(records.lazy.filter { $0.recordType == type.rawValue }.compactMap { record in
                SyncRecordType.parse(recordName: record.recordID.recordName).flatMap { UUID(uuidString: $0.id) }
            })
        }
        return SyncMembershipBeforePull(
            connections: services.connectionStorage.loadConnections(),
            groups: services.groupStorage.loadGroups(),
            connectionsWithOwnProject: ids(of: .connection),
            groupsWithOwnProject: ids(of: .group)
        )
    }

    private func applyRemoteGroupDeletions(_ ids: Set<UUID>, membershipBefore: SyncMembershipBeforePull?) -> Bool {
        guard !ids.isEmpty else { return true }
        guard services.groupStorage.applyRemoteDeletions(ids) else { return false }
        changeTracker.discardDirty(.group, ids: ids.map(\.uuidString))
        forgetHeldChanges(of: .group, ids: ids)
        return keepProjects(ofMembersReleasedFrom: ids, membershipBefore)
    }

    // The store hands a deleted group's project to what still names the group. A member this pull already took
    // out of it names nothing by then, so its project is read from the library as it stood before the pull.
    private func keepProjects(ofMembersReleasedFrom ids: Set<UUID>, _ before: SyncMembershipBeforePull?) -> Bool {
        guard let before else { return true }
        let changes = LibraryPullMembership.keptByReleasedMembers(
            ofGroups: ids,
            connectionsBefore: before.connections,
            groupsBefore: before.groups,
            connections: services.connectionStorage.loadConnections(),
            groups: services.groupStorage.loadGroups(),
            connectionsWithOwnProject: before.connectionsWithOwnProject,
            groupsWithOwnProject: before.groupsWithOwnProject
        )
        guard !changes.isEmpty else { return true }
        let connectionsSaved = changes.connections.isEmpty
            || services.connectionStorage.rewriteMembership(byUser: false) { connection in
                connection.projectId = changes.connectionProjectId(connection.id, current: connection.projectId)
            }
        return connectionsSaved && services.groupStorage.applyProjectChanges(changes.groups)
    }

    private func applyRemoteProjectDeletions(_ ids: Set<UUID>) -> Bool {
        guard !ids.isEmpty else { return true }
        guard services.projectStorage.applyRemoteDeletions(ids) else { return false }
        changeTracker.discardDirty(.project, ids: ids.map(\.uuidString))
        forgetHeldChanges(of: .project, ids: ids)
        return true
    }

    private func applyRemoteTagDeletions(_ ids: Set<UUID>) -> Bool {
        guard !ids.isEmpty else { return true }
        guard services.tagStorage.applyRemoteDeletions(ids) else { return false }
        changeTracker.discardDirty(.tag, ids: ids.map(\.uuidString))
        forgetHeldChanges(of: .tag, ids: ids)
        return true
    }

    // Unlinking reads the profile's secrets, so it runs while they still exist. False withholds the pull token:
    // acknowledging the delete would leave connections pointing at the profile with nothing left to replay it.
    private func applyRemoteSSHProfileDeletions(_ profileIds: Set<UUID>) -> Bool {
        guard !profileIds.isEmpty else { return true }

        var profiles = services.sshProfileStorage.loadProfiles()
        let deleted = profiles.filter { profileIds.contains($0.id) }
        profiles.removeAll { profileIds.contains($0.id) }

        for profile in deleted where !services.sshProfileStorage.unlinkConnections(fromProfile: profile, byUser: false) {
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

    // A profile deleted on another Mac hands its credentials to the connections using it here, so they keep connecting.
    private func applyRemoteCredentialProfileDeletions(_ profileIds: Set<UUID>) -> Bool {
        guard !profileIds.isEmpty else { return true }

        var profiles = services.credentialProfileStorage.loadProfiles()
        // Unlinking needs the profile, so the deletion of one this Mac cannot read waits for a build that reads it.
        let unreadable = profileIds.intersection(services.credentialProfileStorage.unreadableProfileIds)
        if !unreadable.isEmpty {
            metadataStorage.deletionsHeldForUnreadableCopies.formUnion(
                unreadable.map { SyncRecordType.credentialProfile.recordName(for: $0.uuidString) }
            )
        }
        let deleted = profiles.filter { profileIds.contains($0.id) }
        profiles.removeAll { profileIds.contains($0.id) }

        for profile in deleted where !services.credentialProfileStorage.unlinkConnections(from: profile, byUser: false) {
            Self.logger.error(
                "Kept credential profile \(profile.id.uuidString, privacy: .public): its connections could not be converted"
            )
            return false
        }
        guard services.credentialProfileStorage.saveProfilesWithoutSync(profiles) else { return false }
        // A held deletion keeps the mark, so the edit made here still counts when the copy reads.
        changeTracker.discardDirty(.credentialProfile, ids: profileIds.subtracting(unreadable).map(\.uuidString))
        for profile in deleted {
            services.credentialProfileStorage.deleteSecrets(for: profile)
        }
        return true
    }
}
