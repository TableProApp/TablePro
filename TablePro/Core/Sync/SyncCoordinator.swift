//
//  SyncCoordinator.swift
//  TablePro
//
//  Orchestrates sync: license gating, scheduling, push/pull coordination
//

import CloudKit
import Combine
import Foundation
import Observation
import os
import TableProSyncTransport

/// Central coordinator for iCloud sync
@MainActor @Observable
final class SyncCoordinator {
    static let shared = SyncCoordinator()
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "SyncCoordinator")

    private(set) var syncStatus: SyncStatus = .disabled(.userDisabled)
    private(set) var lastSyncDate: Date?
    private(set) var iCloudAccountAvailable: Bool = false

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private let engine = CloudKitSyncEngine()
    @ObservationIgnored private let changeTracker: SyncChangeTracker
    @ObservationIgnored private let metadataStorage: SyncMetadataStorage
    @ObservationIgnored private let recordCache = SyncRecordCache()
    @ObservationIgnored private let accountObserver = OSAllocatedUnfairLock<(any NSObjectProtocol)?>(uncheckedState: nil)
    @ObservationIgnored private var changeCancellable: AnyCancellable?
    @ObservationIgnored private var licenseCancellable: AnyCancellable?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false

    /// Bumped every time something other than a sync run decides the status, so a run that has been
    /// suspended across the network can tell whether its outcome is still the current answer.
    @ObservationIgnored private var statusGeneration = 0

    init(services: AppServices = .live) {
        self.services = services
        self.changeTracker = services.syncTracker
        self.metadataStorage = services.syncMetadataStorage
        lastSyncDate = metadataStorage.lastSyncDate
    }

    deinit {
        if let observer = accountObserver.withLockUnchecked({ $0 }) { NotificationCenter.default.removeObserver(observer) }
        syncTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Call from AppDelegate at launch
    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        observeAccountChanges()
        observeLocalChanges()
        observeLicenseChanges()

        // If local storage is empty (fresh install or wiped), clear the sync token
        // to force a full fetch instead of a delta that returns nothing
        if services.connectionStorage.loadConnections().isEmpty {
            metadataStorage.saveToken(nil)
            Self.logger.info("No local connections — cleared sync token for full fetch")
        }

        Task {
            await checkAccountStatus()
            evaluateStatus()

            if syncStatus.isEnabled {
                await syncNow()
            }
        }
    }

    /// Called when the app comes to the foreground
    func syncIfNeeded() {
        guard syncStatus.isEnabled, !syncStatus.isSyncing else { return }

        Task {
            await syncNow()
        }
    }

    /// Manual full sync (push then pull)
    func syncNow() async {
        guard canSync() else {
            Self.logger.info("syncNow: canSync() returned false, skipping")
            return
        }
        guard !syncStatus.isSyncing else {
            Self.logger.info("syncNow: another sync is already in progress, skipping")
            return
        }

        let generation = statusGeneration
        syncStatus = .syncing

        do {
            try await engine.ensureZoneExists()

            var pushError: Error?
            do {
                try await performPush()
            } catch {
                pushError = error
                Self.logger.error("Push failed: \(error.localizedDescription)")
            }

            await performPull()

            if let pushError {
                settle(.error(SyncError.from(pushError)), from: generation)
                return
            }

            lastSyncDate = Date()
            metadataStorage.lastSyncDate = lastSyncDate
            settle(.idle, from: generation)
            metadataStorage.pruneTombstones(olderThan: 30)

            Self.logger.info("Sync completed successfully")
        } catch {
            let syncError = SyncError.from(error)
            settle(.error(syncError), from: generation)
            Self.logger.error("Sync failed: \(error.localizedDescription)")
        }
    }

    /// Publishes the outcome of a sync run, unless something decided the status while it was in
    /// flight.
    ///
    /// A run reads `canSync()` once on entry and then suspends across the whole CloudKit round
    /// trip, so turning sync off, or losing the license, used to be overwritten by the returning
    /// run: the indicator went back to "Synced" for a sync that would now be refused. Whoever
    /// decided last wins, and a stale run reports nothing.
    private func settle(_ outcome: SyncStatus, from generation: Int) {
        guard generation == statusGeneration else {
            Self.logger.info("Discarding a sync outcome the status moved on from")
            return
        }
        syncStatus = outcome
    }

    /// Triggered by remote push notification
    func handleRemoteNotification() {
        guard syncStatus.isEnabled else { return }

        Task {
            await performPull()
        }
    }

    /// Called when user enables sync in settings
    func enableSync() {
        Self.logger.info("enableSync() called")

        // Clear token to force a full fetch on first sync after enabling
        metadataStorage.saveToken(nil)

        // Mark ALL existing local data as dirty so it gets pushed on first sync
        markAllLocalDataDirty()
        let dirtyCount = changeTracker.dirtyRecords(for: .connection).count
        Self.logger.info("enableSync() dirty marking done, dirty connections: \(dirtyCount)")

        Task {
            await checkAccountStatus()
            evaluateStatus()

            if syncStatus.isEnabled {
                await markSQLFavoritesDirty()
                await syncNow()
            }
        }
    }

    /// Marks existing SQL favorites and folders dirty. Separate from `markAllLocalDataDirty`
    /// because the favorite store is an actor and must be read asynchronously.
    private func markSQLFavoritesDirty() async {
        let favorites = await services.sqlFavoriteManager.fetchFavorites()
        changeTracker.markDirty(.favorite, ids: favorites.map { $0.id.uuidString })

        let folders = await services.sqlFavoriteManager.fetchFolders()
        changeTracker.markDirty(.favoriteFolder, ids: folders.map { $0.id.uuidString })
    }

    /// Marks every synced record dirty so the first sync after enabling pushes the lot.
    ///
    /// Every type is marked as one batch. Marking record by record posted a change notification per
    /// record, and the observer cancels the in-flight sync and awaits it before scheduling the next,
    /// so an account with a few hundred saved column layouts built a chain of hundreds of tasks each
    /// waiting on its predecessor and the app stopped responding to the switch that started it.
    private func markAllLocalDataDirty() {
        let connections = services.connectionStorage.loadConnections()
        changeTracker.markDirty(
            .connection,
            ids: connections.filter { !$0.localOnly }.map { $0.id.uuidString }
        )

        let groups = services.groupStorage.loadGroups()
        changeTracker.markDirty(.group, ids: groups.map { $0.id.uuidString })

        let tags = services.tagStorage.loadTags()
        changeTracker.markDirty(.tag, ids: tags.map { $0.id.uuidString })

        let sshProfiles = services.sshProfileStorage.loadProfiles()
        changeTracker.markDirty(.sshProfile, ids: sshProfiles.map { $0.id.uuidString })

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

        let settingsCategories = AppSettingsCategory.synced + [CustomSlashCommandStorage.syncCategory]
        let columnLayoutCategories = FileColumnLayoutPersister.shared.customizedStorageKeys()
            .map { FileColumnLayoutPersister.syncCategory(for: $0) }
        changeTracker.markDirty(.settings, ids: settingsCategories + columnLayoutCategories)

        let summary = [
            "connections=\(connections.count)",
            "groups=\(groups.count)",
            "tags=\(tags.count)",
            "sshProfiles=\(sshProfiles.count)",
            "favoriteTables=\(favoriteTables.count)",
            "settings=\(AppSettingsCategory.synced.count + 1)"
        ].joined(separator: ", ")
        Self.logger.info("Marked all local data dirty: \(summary, privacy: .public)")
    }

    /// Called when user disables sync in settings
    func disableSync() {
        syncTask?.cancel()
        decide(.disabled(.userDisabled))
    }

    // MARK: - Status

    private func evaluateStatus() {
        let licenseManager = services.licenseManager

        guard licenseManager.isFeatureAvailable(.iCloudSync) else {
            decide(.disabled(Self.licenseDisableReason(for: licenseManager.status)))
            return
        }

        let syncSettings = services.appSettingsStorage.loadSync()
        guard syncSettings.enabled else {
            decide(.disabled(.userDisabled))
            return
        }

        guard iCloudAccountAvailable else {
            decide(.disabled(.noAccount))
            return
        }

        // If we were in an error or disabled state, transition to idle
        if !syncStatus.isSyncing {
            decide(.idle)
        }
    }

    /// Settles the status from outside a sync run, and retires whatever run is in flight.
    ///
    /// The branch that leaves a running sync alone deliberately does not come through here: it has
    /// decided nothing, so invalidating the run would leave the status stuck on Syncing with
    /// nothing left to move it.
    private func decide(_ status: SyncStatus) {
        statusGeneration += 1
        syncStatus = status
    }

    /// Why sync is off, for a license that does not currently unlock it.
    ///
    /// Exhaustive on purpose. The arm that used to be `default:` swallowed `.validationFailed`,
    /// which is a paying customer the app has not reached the server about, and told them a license
    /// was required. A new `LicenseStatus` case has to be answered here rather than inheriting the
    /// wrong answer.
    nonisolated static func licenseDisableReason(for status: LicenseStatus) -> DisableReason {
        switch status {
        case .expired:
            return .licenseExpired
        case .validationFailed:
            return .licenseUnverified
        case .active, .unlicensed, .suspended, .deactivated:
            return .licenseRequired
        }
    }

    private func canSync() -> Bool {
        let licenseManager = services.licenseManager
        guard licenseManager.isFeatureAvailable(.iCloudSync) else {
            Self.logger.trace("Sync skipped: license not available")
            return false
        }

        let syncSettings = services.appSettingsStorage.loadSync()
        guard syncSettings.enabled else {
            Self.logger.trace("Sync skipped: disabled by user")
            return false
        }

        guard iCloudAccountAvailable else {
            Self.logger.trace("Sync skipped: no iCloud account")
            return false
        }

        return true
    }

    // MARK: - Push

    private func performPush() async throws {
        let settings = services.appSettingsStorage.loadSync()
        var recordsToSave: [CKRecord] = []
        var recordIDsToDelete: [CKRecord.ID] = []
        let zoneID = await engine.currentZoneID

        if settings.syncConnections {
            let dirtyConnectionIds = changeTracker.dirtyRecords(for: .connection)
            if !dirtyConnectionIds.isEmpty {
                let connections = services.connectionStorage.loadConnections()
                for id in dirtyConnectionIds {
                    if let connection = connections.first(where: { $0.id.uuidString == id }),
                       !connection.localOnly {
                        let recordID = SyncRecordMapper.recordID(type: .connection, id: id, in: zoneID)
                        recordsToSave.append(
                            SyncRecordMapper.toCKRecord(
                                connection,
                                in: zoneID,
                                base: recordCache.record(for: recordID)
                            )
                        )
                    }
                }
            }

            let connectionTombstones = metadataStorage.tombstones(for: .connection)
            for tombstone in connectionTombstones {
                recordIDsToDelete.append(
                    SyncRecordMapper.recordID(type: .connection, id: tombstone.id, in: zoneID)
                )
            }
        }

        if settings.syncGroupsAndTags {
            collectDirtyGroups(into: &recordsToSave, deletions: &recordIDsToDelete, zoneID: zoneID)
            collectDirtyTags(into: &recordsToSave, deletions: &recordIDsToDelete, zoneID: zoneID)
        }

        if settings.syncSSHProfiles {
            collectDirtySSHProfiles(into: &recordsToSave, deletions: &recordIDsToDelete, zoneID: zoneID)
        }

        if settings.syncSettings {
            let dirtySettingsIds = changeTracker.dirtyRecords(for: .settings)
            for category in dirtySettingsIds {
                if let data = settingsData(for: category) {
                    recordsToSave.append(
                        SyncRecordMapper.toCKRecord(category: category, settingsData: data, in: zoneID)
                    )
                }
            }
        }

        if settings.syncTableFavorites {
            collectDirtyTableFavorites(into: &recordsToSave, deletions: &recordIDsToDelete, zoneID: zoneID)
        }

        if settings.syncDatabaseFavorites {
            collectDirtyDatabaseFavorites(into: &recordsToSave, deletions: &recordIDsToDelete, zoneID: zoneID)
        }

        if settings.syncSQLFavorites {
            await collectDirtySQLFavorites(into: &recordsToSave, deletions: &recordIDsToDelete, zoneID: zoneID)
        }

        // Deduplicate deletion IDs to prevent CloudKit "can't delete same record twice" error
        let uniqueDeletions = Array(Set(recordIDsToDelete))

        guard !recordsToSave.isEmpty || !uniqueDeletions.isEmpty else { return }

        let identities = SyncRecordMapper.identities(for: pushedLocalIds(), in: zoneID)
        let outcome = try await engine.push(records: recordsToSave, deletions: uniqueDeletions)

        recordCache.store(Array(outcome.savedRecords.values))
        recordCache.remove(Array(outcome.deletedRecordIDs))

        for recordID in outcome.savedRecords.keys {
            guard let identity = identities[recordID] else { continue }
            changeTracker.clearDirty(identity.type, id: identity.id)
        }

        for recordID in outcome.deletedRecordIDs {
            guard let identity = identities[recordID] else { continue }
            metadataStorage.removeTombstone(identity.id, type: identity.type)
        }

        let savedCount = outcome.savedRecords.count
        let deletedCount = outcome.deletedRecordIDs.count
        let rejectedCount = outcome.failures.count
        Self.logger.info("Push completed: \(savedCount) saved, \(deletedCount) deleted, \(rejectedCount) rejected")

        guard outcome.hasFailures else { return }

        guard let firstFailure = outcome.failures.values.first else { return }
        throw SyncError.pushRejected(count: outcome.failures.count, detail: firstFailure.message)
    }

    /// Every local identifier this push can have sent. `SyncChangeTracker` is not isolated to this
    /// actor, so the sets can move under an await; a record whose identifier is missing from the
    /// snapshot is left dirty and pushed again rather than cleared against the wrong entry.
    private func pushedLocalIds() -> [SyncRecordType: Set<String>] {
        var localIds: [SyncRecordType: Set<String>] = [:]
        for type in SyncRecordType.allCases {
            let ids = changeTracker.dirtyRecords(for: type)
                .union(metadataStorage.tombstones(for: type).map(\.id))
            guard !ids.isEmpty else { continue }
            localIds[type] = ids
        }
        return localIds
    }

    // MARK: - Pull

    nonisolated static func isTokenExpired(_ error: Error) -> Bool {
        (error as? SyncError) == .tokenExpired
    }

    private func performPull() async {
        let token = metadataStorage.loadToken()
        let tokenStatus = token == nil ? "nil (full fetch)" : "present (delta)"
        Self.logger.info("Pull starting, token: \(tokenStatus)")

        do {
            let result = try await engine.pull(since: token)
            applyPullResult(result)
        } catch let error where Self.isTokenExpired(error) {
            Self.logger.warning("Change token expired, clearing and retrying with full fetch")
            metadataStorage.saveToken(nil)
            do {
                let result = try await engine.pull(since: nil)
                applyPullResult(result)
            } catch {
                Self.logger.error("Full fetch after token expiry failed: \(error.localizedDescription)")
            }
        } catch {
            Self.logger.error("Pull failed: \(error.localizedDescription)")
        }
    }

    private func applyPullResult(_ result: PullResult) {
        if let newToken = result.newToken {
            metadataStorage.saveToken(newToken)
        }

        applyRemoteChanges(result)

        recordCache.store(result.changedRecords)
        recordCache.remove(result.deletedRecordIDs)

        Self.logger.info(
            "Pull completed: \(result.changedRecords.count) changed, \(result.deletedRecordIDs.count) deleted"
        )
    }

    // Performance: storage reads here (loadSync, loadConnections, loadGroups, etc.) run on
    // @MainActor and can block the UI on large sync batches. Consider moving to Task.detached
    // for large payloads.
    private func applyRemoteChanges(_ result: PullResult) {
        let settings = services.appSettingsStorage.loadSync()

        services.connectionStorage.invalidateCache()

        changeTracker.isSuppressed = true
        defer {
            changeTracker.isSuppressed = false
        }

        var actualConnectionChanges = false
        var groupsOrTagsChanged = false

        let connectionTombstoneIds = Set(metadataStorage.tombstones(for: .connection).map(\.id))
        let groupTombstoneIds = Set(metadataStorage.tombstones(for: .group).map(\.id))
        let tagTombstoneIds = Set(metadataStorage.tombstones(for: .tag).map(\.id))
        let sshTombstoneIds = Set(metadataStorage.tombstones(for: .sshProfile).map(\.id))
        let tableFavoriteTombstoneIds = Set(metadataStorage.tombstones(for: .tableFavorite).map(\.id))
        let databaseFavoriteTombstoneIds = Set(metadataStorage.tombstones(for: .favoriteDatabase).map(\.id))
        let sqlFavoriteTombstoneIds = Set(metadataStorage.tombstones(for: .favorite).map(\.id))
        let sqlFolderTombstoneIds = Set(metadataStorage.tombstones(for: .favoriteFolder).map(\.id))
        var remoteFavorites: [SQLFavorite] = []
        var remoteFolders: [SQLFavoriteFolder] = []

        for record in result.changedRecords {
            switch record.recordType {
            case SyncRecordType.connection.rawValue where settings.syncConnections:
                if applyRemoteConnection(record, tombstoneIds: connectionTombstoneIds) {
                    actualConnectionChanges = true
                }
            case SyncRecordType.group.rawValue where settings.syncGroupsAndTags:
                if applyRemoteGroup(record, tombstoneIds: groupTombstoneIds) {
                    groupsOrTagsChanged = true
                }
            case SyncRecordType.tag.rawValue where settings.syncGroupsAndTags:
                if applyRemoteTag(record, tombstoneIds: tagTombstoneIds) {
                    groupsOrTagsChanged = true
                }
            case SyncRecordType.sshProfile.rawValue where settings.syncSSHProfiles:
                applyRemoteSSHProfile(record, tombstoneIds: sshTombstoneIds)
            case SyncRecordType.settings.rawValue where settings.syncSettings:
                applyRemoteSettings(record)
            case SyncRecordType.tableFavorite.rawValue where settings.syncTableFavorites:
                applyRemoteTableFavorite(record, tombstoneIds: tableFavoriteTombstoneIds)
            case SyncRecordType.favoriteDatabase.rawValue where settings.syncDatabaseFavorites:
                applyRemoteDatabaseFavorite(record, tombstoneIds: databaseFavoriteTombstoneIds)
            case SyncRecordType.favorite.rawValue where settings.syncSQLFavorites:
                if let favorite = try? SyncRecordMapper.sqlFavorite(from: record),
                   !sqlFavoriteTombstoneIds.contains(favorite.id.uuidString) {
                    remoteFavorites.append(favorite)
                }
            case SyncRecordType.favoriteFolder.rawValue where settings.syncSQLFavorites:
                if let folder = try? SyncRecordMapper.sqlFavoriteFolder(from: record),
                   !sqlFolderTombstoneIds.contains(folder.id.uuidString) {
                    remoteFolders.append(folder)
                }
            default:
                break
            }
        }

        var connectionIdsToDelete: Set<UUID> = []
        var groupIdsToDelete: Set<UUID> = []
        var tagIdsToDelete: Set<UUID> = []
        var sshProfileIdsToDelete: Set<UUID> = []
        var tableFavoriteIdsToDelete: Set<String> = []
        var sqlFavoriteIdsToDelete: Set<UUID> = []
        var sqlFolderIdsToDelete: Set<UUID> = []

        for recordID in result.deletedRecordIDs {
            let name = recordID.recordName
            if name.hasPrefix("Connection_"),
               let uuid = UUID(uuidString: String(name.dropFirst("Connection_".count))) {
                connectionIdsToDelete.insert(uuid)
                actualConnectionChanges = true
            } else if name.hasPrefix("Group_"),
                      let uuid = UUID(uuidString: String(name.dropFirst("Group_".count))) {
                groupIdsToDelete.insert(uuid)
                groupsOrTagsChanged = true
            } else if name.hasPrefix("Tag_"),
                      let uuid = UUID(uuidString: String(name.dropFirst("Tag_".count))) {
                tagIdsToDelete.insert(uuid)
                groupsOrTagsChanged = true
            } else if name.hasPrefix("SSHProfile_"),
                      let uuid = UUID(uuidString: String(name.dropFirst("SSHProfile_".count))) {
                sshProfileIdsToDelete.insert(uuid)
            } else if name.hasPrefix("FavoriteTable_") {
                tableFavoriteIdsToDelete.insert(String(name.dropFirst("FavoriteTable_".count)))
            } else if settings.syncSQLFavorites, name.hasPrefix("FavoriteFolder_"),
                      let uuid = UUID(uuidString: String(name.dropFirst("FavoriteFolder_".count))) {
                sqlFolderIdsToDelete.insert(uuid)
            } else if settings.syncSQLFavorites, name.hasPrefix("Favorite_"),
                      let uuid = UUID(uuidString: String(name.dropFirst("Favorite_".count))) {
                sqlFavoriteIdsToDelete.insert(uuid)
            }
        }

        if !connectionIdsToDelete.isEmpty {
            var connections = services.connectionStorage.loadConnections()
            connections.removeAll { connectionIdsToDelete.contains($0.id) }
            if !services.connectionStorage.saveConnections(connections) {
                Self.logger.error("Failed to apply remote connection deletions: persistence error")
            } else {
                ConnectionLocalState.purge(connectionIds: connectionIdsToDelete, origin: .remote)
                let favoriteManager = services.sqlFavoriteManager
                Task {
                    for id in connectionIdsToDelete {
                        await favoriteManager.removeFavoritesAndFolders(for: id)
                    }
                }
            }
        }
        if !groupIdsToDelete.isEmpty {
            var groups = services.groupStorage.loadGroups()
            groups.removeAll { groupIdsToDelete.contains($0.id) }
            services.groupStorage.saveGroups(groups)
        }
        if !tagIdsToDelete.isEmpty {
            var tags = services.tagStorage.loadTags()
            tags.removeAll { tagIdsToDelete.contains($0.id) }
            services.tagStorage.saveTags(tags)
        }
        if !sshProfileIdsToDelete.isEmpty {
            var profiles = services.sshProfileStorage.loadProfiles()
            profiles.removeAll { sshProfileIdsToDelete.contains($0.id) }
            services.sshProfileStorage.saveProfilesWithoutSync(profiles)
        }
        for id in tableFavoriteIdsToDelete {
            services.favoriteTablesStorage.removeFavoriteWithoutSync(id: id)
        }

        if !remoteFolders.isEmpty || !remoteFavorites.isEmpty
            || !sqlFolderIdsToDelete.isEmpty || !sqlFavoriteIdsToDelete.isEmpty {
            let manager = services.sqlFavoriteManager
            let folders = remoteFolders
            let favorites = remoteFavorites
            let folderDeletes = sqlFolderIdsToDelete
            let favoriteDeletes = sqlFavoriteIdsToDelete
            Task {
                for folder in folders {
                    await manager.applyRemoteFolder(folder)
                }
                for favorite in favorites {
                    await manager.applyRemoteFavorite(favorite)
                }
                for id in favoriteDeletes {
                    await manager.applyRemoteDeleteFavorite(id: id)
                }
                for id in folderDeletes {
                    await manager.applyRemoteDeleteFolder(id: id)
                }
            }
        }

        /// After the batch, never per record: a pull carries no dependency order, so a legal
        /// hierarchy change spread over two records passes through a state that reads as a cycle
        /// until both have landed.
        if groupsOrTagsChanged {
            services.groupStorage.repairHierarchy()
        }

        if actualConnectionChanges || groupsOrTagsChanged {
            services.appEvents.connectionUpdated.send(nil)
        }
    }

    @discardableResult
    private func mergeLocalEdits(into remoteRecord: CKRecord, localConnection: DatabaseConnection) -> DatabaseConnection? {
        guard let base = recordCache.record(for: remoteRecord.recordID) else { return nil }

        let localRecord = SyncRecordMapper.toCKRecord(localConnection, in: remoteRecord.recordID.zoneID)
        guard let merged = remoteRecord.copy() as? CKRecord else { return nil }

        let localFields = localRecord.fields(ConnectionSyncField.self)
        let baseFields = base.fields(ConnectionSyncField.self)
        let mergedFields = merged.fields(ConnectionSyncField.self)
        for field in ConnectionSyncField.allCases where field != .modifiedAtLocal {
            guard !CKRecord.isEqualRecordValue(localFields[field], baseFields[field]) else { continue }
            mergedFields[field] = localFields[field]
        }

        do {
            return try SyncRecordMapper.toConnection(merged)
        } catch {
            Self.logger.error("Failed to merge local edits: \(error.localizedDescription)")
            return nil
        }
    }

    private func applyRemoteConnection(_ record: CKRecord, tombstoneIds: Set<String>) -> Bool {
        let remoteConnection: DatabaseConnection
        do {
            remoteConnection = try SyncRecordMapper.toConnection(record)
        } catch {
            Self.logger.error("Skipping remote connection \(record.recordID.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }

        if tombstoneIds.contains(remoteConnection.id.uuidString) {
            return false
        }

        var connections = services.connectionStorage.loadConnections()
        if let index = connections.firstIndex(where: { $0.id == remoteConnection.id }) {
            var incoming = remoteConnection
            if changeTracker.dirtyRecords(for: .connection).contains(remoteConnection.id.uuidString) {
                guard let reconciled = mergeLocalEdits(
                    into: record,
                    localConnection: connections[index]
                ) else {
                    return false
                }
                incoming = reconciled
            }
            var merged = incoming
            merged.localOnly = connections[index].localOnly
            merged.passwordSource = connections[index].passwordSource
            connections[index] = merged
        } else {
            connections.append(remoteConnection)
        }
        guard services.connectionStorage.saveConnections(connections) else {
            Self.logger.error("Failed to apply remote connection update: persistence error for \(remoteConnection.id, privacy: .public)")
            return false
        }
        return true
    }

    @discardableResult
    private func applyRemoteGroup(_ record: CKRecord, tombstoneIds: Set<String>) -> Bool {
        guard let remoteGroup = SyncRecordMapper.toGroup(record) else { return false }
        if tombstoneIds.contains(remoteGroup.id.uuidString) { return false }

        return services.groupStorage.applyRemoteGroup(remoteGroup)
    }

    @discardableResult
    private func applyRemoteTag(_ record: CKRecord, tombstoneIds: Set<String>) -> Bool {
        guard let remoteTag = SyncRecordMapper.toTag(record) else { return false }
        if tombstoneIds.contains(remoteTag.id.uuidString) { return false }

        var tags = services.tagStorage.loadTags()
        if let index = tags.firstIndex(where: { $0.id == remoteTag.id }) {
            tags[index] = remoteTag
        } else {
            tags.append(remoteTag)
        }
        services.tagStorage.saveTags(tags)
        return true
    }

    private func applyRemoteSSHProfile(_ record: CKRecord, tombstoneIds: Set<String>) {
        let remoteProfile: SSHProfile
        do {
            remoteProfile = try SyncRecordMapper.toSSHProfile(record)
        } catch {
            Self.logger.error("Skipping remote SSH profile \(record.recordID.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        if tombstoneIds.contains(remoteProfile.id.uuidString) { return }

        var profiles = services.sshProfileStorage.loadProfiles()
        if let index = profiles.firstIndex(where: { $0.id == remoteProfile.id }) {
            profiles[index] = remoteProfile
        } else {
            profiles.append(remoteProfile)
        }
        services.sshProfileStorage.saveProfilesWithoutSync(profiles)
    }

    private func applyRemoteSettings(_ record: CKRecord) {
        guard let category = SyncRecordMapper.settingsCategory(from: record),
              let data = SyncRecordMapper.settingsData(from: record)
        else { return }
        do {
            try applySettingsData(data, for: category)
        } catch {
            let recordName = record.recordID.recordName
            let message = error.localizedDescription
            Self.logger.error(
                "Skipping remote settings \(recordName, privacy: .public) (\(category, privacy: .public)): \(message, privacy: .public)"
            )
        }
    }

    @discardableResult
    private func applyRemoteTableFavorite(_ record: CKRecord, tombstoneIds: Set<String>) -> Bool {
        let entry: FavoriteTablesStorage.FavoriteEntry
        do {
            entry = try SyncRecordMapper.favoriteEntry(from: record)
        } catch {
            let recordName = record.recordID.recordName
            let message = error.localizedDescription
            Self.logger.error(
                "Skipping remote favorite table \(recordName, privacy: .public): \(message, privacy: .public)"
            )
            return false
        }
        if tombstoneIds.contains(FavoriteTablesStorage.syncId(for: entry)) { return false }
        return services.favoriteTablesStorage.addFavoriteWithoutSync(entry)
    }

    /// Upserts rather than inserts. A database favorite carries a mutable payload, the environment
    /// tag, so an insert-if-absent apply would keep the local tag and silently drop the remote one.
    private func applyRemoteDatabaseFavorite(_ record: CKRecord, tombstoneIds: Set<String>) {
        let entry: FavoriteDatabaseEntry
        do {
            entry = try SyncRecordMapper.favoriteDatabase(from: record)
        } catch {
            let recordName = record.recordID.recordName
            let message = error.localizedDescription
            Self.logger.error(
                "Skipping remote favorite database \(recordName, privacy: .public): \(message, privacy: .public)"
            )
            return
        }
        guard !tombstoneIds.contains(FavoriteDatabasesStorage.syncId(for: entry)) else { return }
        services.favoriteDatabasesStorage.setFavoriteWithoutSync(entry)
    }

    // MARK: - Observers

    private func observeAccountChanges() {
        let observer = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await checkAccountStatus()
                evaluateStatus()

                let currentAccountId = metadataStorage.lastAccountId
                if let newAccountId = try? await self.currentAccountId(),
                   currentAccountId != nil, currentAccountId != newAccountId {
                    Self.logger.warning("iCloud account changed, clearing sync metadata")
                    metadataStorage.clearAll()
                    metadataStorage.lastAccountId = newAccountId
                }
            }
        }
        accountObserver.withLockUnchecked { $0 = observer }
    }

    private func observeLocalChanges() {
        changeCancellable = services.appEvents.syncChangeTracked
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                guard syncStatus.isEnabled else { return }
                let previousTask = syncTask
                previousTask?.cancel()
                syncTask = Task {
                    // Wait for the cancelled previous task to unwind before scheduling
                    // the new debounce window, so we never have two sync tasks live.
                    _ = await previousTask?.value
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    await self.syncNow()
                }
            }
    }

    private func observeLicenseChanges() {
        licenseCancellable = services.appEvents.licenseStatusDidChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                evaluateStatus()
                if syncStatus.isEnabled {
                    Task { await self.syncNow() }
                }
            }
    }

    // MARK: - Account

    private func checkAccountStatus() async {
        do {
            let status = try await engine.accountStatus()
            iCloudAccountAvailable = (status == .available)

            if iCloudAccountAvailable {
                if let accountId = try? await currentAccountId() {
                    metadataStorage.lastAccountId = accountId
                }
            }
        } catch {
            iCloudAccountAvailable = false
            Self.logger.warning("Failed to check iCloud account: \(error.localizedDescription)")
        }
    }

    private func currentAccountId() async throws -> String? {
        try await engine.currentAccountId()
    }

    // MARK: - Conflict Handling

    // MARK: - Settings Helpers

    private func settingsData(for category: String) -> Data? {
        let storage = services.appSettingsStorage
        let encoder = JSONEncoder()

        do {
            switch category {
            case AppSettingsCategory.general: return try encoder.encode(storage.loadGeneral())
            case AppSettingsCategory.appearance: return try encoder.encode(storage.loadAppearance())
            case AppSettingsCategory.editor: return try encoder.encode(storage.loadEditor())
            case AppSettingsCategory.dataGrid: return try encoder.encode(storage.loadDataGrid())
            case AppSettingsCategory.history: return try encoder.encode(storage.loadHistory())
            case AppSettingsCategory.tabs: return try encoder.encode(storage.loadTabs())
            case AppSettingsCategory.keyboard: return try encoder.encode(storage.loadKeyboard())
            case AppSettingsCategory.ai: return try encoder.encode(storage.loadAI())
            case AppSettingsCategory.notifications: return try encoder.encode(storage.loadNotifications())
            case CustomSlashCommandStorage.syncCategory:
                return try encoder.encode(CustomSlashCommandStorage.shared.commands)
            case let category where category.hasPrefix(FileColumnLayoutPersister.syncCategoryPrefix):
                return FileColumnLayoutPersister.shared.rawData(
                    forStorageKey: String(category.dropFirst(FileColumnLayoutPersister.syncCategoryPrefix.count))
                )
            default: return nil
            }
        } catch {
            Self.logger.error("Failed to encode settings category '\(category)': \(error.localizedDescription)")
            return nil
        }
    }

    private func applySettingsData(_ data: Data, for category: String) throws {
        let manager = services.appSettings
        let decoder = JSONDecoder()

        do {
            switch category {
            case AppSettingsCategory.general: manager.general = try decoder.decode(GeneralSettings.self, from: data)
            case AppSettingsCategory.appearance:
                manager.appearance = try decoder.decode(AppearanceSettings.self, from: data)
            case AppSettingsCategory.editor: manager.editor = try decoder.decode(EditorSettings.self, from: data)
            case AppSettingsCategory.dataGrid: manager.dataGrid = try decoder.decode(DataGridSettings.self, from: data)
            case AppSettingsCategory.history: manager.history = try decoder.decode(HistorySettings.self, from: data)
            case AppSettingsCategory.tabs: manager.tabs = try decoder.decode(TabSettings.self, from: data)
            case AppSettingsCategory.keyboard: manager.keyboard = try decoder.decode(KeyboardSettings.self, from: data)
            case AppSettingsCategory.ai: manager.ai = try decoder.decode(AISettings.self, from: data)
            case AppSettingsCategory.notifications:
                manager.notifications = try decoder.decode(NotificationSettings.self, from: data)
            case CustomSlashCommandStorage.syncCategory:
                CustomSlashCommandStorage.shared.applyRemote(try decoder.decode([CustomSlashCommand].self, from: data))
            case let category where category.hasPrefix(FileColumnLayoutPersister.syncCategoryPrefix):
                FileColumnLayoutPersister.shared.applyRemote(
                    storageKey: String(category.dropFirst(FileColumnLayoutPersister.syncCategoryPrefix.count)),
                    data: data
                )
            default: return
            }
        } catch {
            throw SyncDecodeError.decodeFailure(field: category, underlying: error)
        }
    }

    // MARK: - Group/Tag Collection Helpers

    private func collectDirtyGroups(
        into records: inout [CKRecord],
        deletions: inout [CKRecord.ID],
        zoneID: CKRecordZone.ID
    ) {
        let dirtyGroupIds = changeTracker.dirtyRecords(for: .group)
        if !dirtyGroupIds.isEmpty {
            let groups = services.groupStorage.loadGroups()
            for id in dirtyGroupIds {
                if let group = groups.first(where: { $0.id.uuidString == id }) {
                    records.append(SyncRecordMapper.toCKRecord(group, in: zoneID))
                }
            }
        }

        for tombstone in metadataStorage.tombstones(for: .group) {
            deletions.append(
                SyncRecordMapper.recordID(type: .group, id: tombstone.id, in: zoneID)
            )
        }
    }

    private func collectDirtyTags(
        into records: inout [CKRecord],
        deletions: inout [CKRecord.ID],
        zoneID: CKRecordZone.ID
    ) {
        let dirtyTagIds = changeTracker.dirtyRecords(for: .tag)
        if !dirtyTagIds.isEmpty {
            let tags = services.tagStorage.loadTags()
            for id in dirtyTagIds {
                if let tag = tags.first(where: { $0.id.uuidString == id }) {
                    records.append(SyncRecordMapper.toCKRecord(tag, in: zoneID))
                }
            }
        }

        for tombstone in metadataStorage.tombstones(for: .tag) {
            deletions.append(
                SyncRecordMapper.recordID(type: .tag, id: tombstone.id, in: zoneID)
            )
        }
    }

    private func collectDirtySSHProfiles(
        into records: inout [CKRecord],
        deletions: inout [CKRecord.ID],
        zoneID: CKRecordZone.ID
    ) {
        let dirtyProfileIds = changeTracker.dirtyRecords(for: .sshProfile)
        if !dirtyProfileIds.isEmpty {
            let profiles = services.sshProfileStorage.loadProfiles()
            for id in dirtyProfileIds {
                if let profile = profiles.first(where: { $0.id.uuidString == id }) {
                    records.append(SyncRecordMapper.toCKRecord(profile, in: zoneID))
                }
            }
        }

        for tombstone in metadataStorage.tombstones(for: .sshProfile) {
            deletions.append(
                SyncRecordMapper.recordID(type: .sshProfile, id: tombstone.id, in: zoneID)
            )
        }
    }

    private func collectDirtySQLFavorites(
        into records: inout [CKRecord],
        deletions: inout [CKRecord.ID],
        zoneID: CKRecordZone.ID
    ) async {
        let dirtyFavoriteIds = changeTracker.dirtyRecords(for: .favorite)
        if !dirtyFavoriteIds.isEmpty {
            let favorites = await services.sqlFavoriteManager.fetchFavorites()
            let favoritesById = Dictionary(favorites.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
            for id in dirtyFavoriteIds {
                if let favorite = favoritesById[id] {
                    records.append(SyncRecordMapper.toCKRecord(sqlFavorite: favorite, in: zoneID))
                }
            }
        }
        for tombstone in metadataStorage.tombstones(for: .favorite) {
            deletions.append(
                SyncRecordMapper.recordID(type: .favorite, id: tombstone.id, in: zoneID)
            )
        }

        let dirtyFolderIds = changeTracker.dirtyRecords(for: .favoriteFolder)
        if !dirtyFolderIds.isEmpty {
            let folders = await services.sqlFavoriteManager.fetchFolders()
            let foldersById = Dictionary(folders.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
            for id in dirtyFolderIds {
                if let folder = foldersById[id] {
                    records.append(SyncRecordMapper.toCKRecord(sqlFavoriteFolder: folder, in: zoneID))
                }
            }
        }
        for tombstone in metadataStorage.tombstones(for: .favoriteFolder) {
            deletions.append(
                SyncRecordMapper.recordID(type: .favoriteFolder, id: tombstone.id, in: zoneID)
            )
        }
    }

    private func collectDirtyTableFavorites(
        into records: inout [CKRecord],
        deletions: inout [CKRecord.ID],
        zoneID: CKRecordZone.ID
    ) {
        let dirtyIds = changeTracker.dirtyRecords(for: .tableFavorite)
        if !dirtyIds.isEmpty {
            let favorites = services.favoriteTablesStorage.loadFavorites()
            for entry in favorites where dirtyIds.contains(FavoriteTablesStorage.syncId(for: entry)) {
                records.append(SyncRecordMapper.toCKRecord(favoriteEntry: entry, in: zoneID))
            }
        }

        for tombstone in metadataStorage.tombstones(for: .tableFavorite) {
            deletions.append(
                SyncRecordMapper.recordID(type: .tableFavorite, id: tombstone.id, in: zoneID)
            )
        }
    }

    /// A connection the user marked local only never reaches iCloud, and neither do the database
    /// names hanging off it. Tombstones are not filtered: a deletion only ever removes something,
    /// and a connection can be marked local only after its favorites were already pushed.
    private func collectDirtyDatabaseFavorites(
        into records: inout [CKRecord],
        deletions: inout [CKRecord.ID],
        zoneID: CKRecordZone.ID
    ) {
        let dirtyIds = changeTracker.dirtyRecords(for: .favoriteDatabase)
        if !dirtyIds.isEmpty {
            let localOnlyIds = Set(
                services.connectionStorage.loadConnections().filter(\.localOnly).map(\.id)
            )
            let favorites = services.favoriteDatabasesStorage.loadFavorites()
            for entry in favorites
            where dirtyIds.contains(FavoriteDatabasesStorage.syncId(for: entry))
                && !localOnlyIds.contains(entry.connectionId) {
                records.append(SyncRecordMapper.toCKRecord(favoriteDatabase: entry, in: zoneID))
            }
        }

        for tombstone in metadataStorage.tombstones(for: .favoriteDatabase) {
            deletions.append(
                SyncRecordMapper.recordID(type: .favoriteDatabase, id: tombstone.id, in: zoneID)
            )
        }
    }
}
