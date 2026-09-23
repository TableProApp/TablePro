//
//  SyncCoordinator.swift
//  TablePro
//
//  Orchestrates sync: license gating, scheduling, push/pull coordination
//

import CloudKit
import Combine
import Foundation
import os
import TableProSyncTransport

/// Central coordinator for iCloud sync
@MainActor
final class SyncCoordinator: ObservableObject {
    static let shared = SyncCoordinator()
    nonisolated static let logger = Logger(subsystem: "com.TablePro", category: "SyncCoordinator")

    @Published private(set) var syncStatus: SyncStatus = .disabled(.userDisabled)
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var iCloudAccountAvailable: Bool = false

    let services: AppServices
    private let transport: any SyncTransport
    let changeTracker: SyncChangeTracker
    let metadataStorage: SyncMetadataStorage
    let recordCache: SyncRecordCache
    let columnLayouts: () -> FileColumnLayoutPersister
    private let accountObserver = OSAllocatedUnfairLock<(any NSObjectProtocol)?>(uncheckedState: nil)
    private var changeCancellable: AnyCancellable?
    private var licenseCancellable: AnyCancellable?
    private var syncTask: Task<Void, Never>?
    private var hasStarted = false
    private var isRunningCycle = false
    private var hasDeferredNotificationPull = false
    private var notificationPull: Task<Void, Never>?

    /// Bumped every time something other than a sync run decides the status, so a run that has been
    /// suspended across the network can tell whether its outcome is still the current answer.
    private var statusGeneration = 0

    init(
        services: AppServices = .live,
        recordCache: SyncRecordCache = SyncCoordinator.makeRecordCache(),
        transport: any SyncTransport = CloudKitSyncEngine(),
        columnLayouts: @escaping @autoclosure () -> FileColumnLayoutPersister = .shared
    ) {
        self.services = services
        self.transport = transport
        self.changeTracker = services.syncTracker
        self.metadataStorage = services.syncMetadataStorage
        self.recordCache = recordCache
        self.columnLayouts = columnLayouts
        lastSyncDate = metadataStorage.lastSyncDate
    }

    nonisolated static func makeRecordCache() -> SyncRecordCache {
        SyncRecordCache(
            directory: AppStorageEnvironment.shared.supportDirectory
                .appendingPathComponent("SyncRecordCache", isDirectory: true),
            defaults: AppStorageEnvironment.shared.defaults
        )
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

        if let syncError = await runSyncCycle() {
            settle(.error(syncError), from: generation)
            return
        }

        lastSyncDate = Date()
        metadataStorage.lastSyncDate = lastSyncDate
        settle(.idle, from: generation)
        metadataStorage.pruneTombstones(olderThan: 30)

        Self.logger.info("Sync completed successfully")
    }

    internal func runSyncCycle() async -> SyncError? {
        isRunningCycle = true
        await notificationPull?.value
        let failure = await pushThenPull()
        isRunningCycle = false
        if hasDeferredNotificationPull {
            hasDeferredNotificationPull = false
            await pullForRemoteNotification()
        }
        return failure
    }

    private func pushThenPull() async -> SyncError? {
        do {
            try await transport.ensureZoneExists()
        } catch {
            Self.logger.error("Sync failed: \(error.localizedDescription)")
            return SyncError.from(error)
        }

        let push = await performPush()
        let pullError = await performPull(echoGuard: push.echoGuard)
        while hasDeferredNotificationPull {
            hasDeferredNotificationPull = false
            await performPull(echoGuard: push.echoGuard)
        }

        if let pushError = push.error {
            return SyncError.from(pushError)
        }
        return pullError
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
            await pullForRemoteNotification()
        }
    }

    internal func pullForRemoteNotification() async {
        guard !isRunningCycle else {
            hasDeferredNotificationPull = true
            return
        }
        let previous = notificationPull
        let pull = Task {
            await previous?.value
            await performPull()
        }
        notificationPull = pull
        await pull.value
        if notificationPull == pull {
            notificationPull = nil
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

        let settingsCategories = AppSettingsCategory.synced + [CustomSlashCommandStorage.syncCategory]
        let columnLayoutCategories = columnLayouts().customizedStorageKeys()
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

    private struct PushReport {
        var echoGuard: SyncEchoGuard?
        var error: Error?
    }

    private func performPush() async -> PushReport {
        let snapshot = changeTracker.editSnapshot()
        let settings = services.appSettingsStorage.loadSync()
        let zoneID = await transport.currentZoneID
        let batch = await collectPushBatch(snapshot: snapshot, settings: settings, zoneID: zoneID)
        let deletions = batch.uniqueDeletions

        guard !batch.records.isEmpty || !deletions.isEmpty else { return PushReport() }

        let identities = SyncRecordMapper.identities(for: pushedLocalIds(snapshot), in: zoneID)
        let outcome: PushOutcome
        var interruption: Error?
        do {
            outcome = try await transport.push(records: batch.records, deletions: deletions)
        } catch let interrupted as SyncPushInterruption {
            outcome = interrupted.completed
            interruption = interrupted.cause
        } catch {
            Self.logger.error("Push failed: \(error.localizedDescription)")
            return PushReport(error: error)
        }

        recordCache.store(Array(outcome.savedRecords.values))
        recordCache.remove(Array(outcome.deletedRecordIDs))

        let savedRecords = settleSavedRecords(outcome, batch: batch, identities: identities, snapshot: snapshot)

        for recordID in outcome.deletedRecordIDs {
            guard let identity = identities[recordID] else { continue }
            metadataStorage.removeTombstone(identity.id, type: identity.type)
        }

        let savedCount = outcome.savedRecords.count
        let deletedCount = outcome.deletedRecordIDs.count
        let rejectedCount = outcome.failures.count
        Self.logger.info("Push completed: \(savedCount) saved, \(deletedCount) deleted, \(rejectedCount) rejected")

        let echoGuard = SyncEchoGuard(snapshot: snapshot, savedRecords: savedRecords)
        if let interruption {
            Self.logger.error("Push stopped part way: \(interruption.localizedDescription)")
            return PushReport(echoGuard: echoGuard, error: interruption)
        }
        guard outcome.hasFailures, let firstFailure = outcome.failures.values.first else {
            return PushReport(echoGuard: echoGuard)
        }
        let rejection = SyncError.pushRejected(count: outcome.failures.count, detail: firstFailure.message)
        Self.logger.error("Push failed: \(rejection.localizedDescription)")
        return PushReport(echoGuard: echoGuard, error: rejection)
    }

    private func settleSavedRecords(
        _ outcome: PushOutcome,
        batch: SyncPushBatch,
        identities: [CKRecord.ID: SyncRecordIdentity],
        snapshot: SyncEditSnapshot
    ) -> [CKRecord.ID: SyncRecordIdentity] {
        var savedRecords: [CKRecord.ID: SyncRecordIdentity] = [:]
        for recordID in outcome.savedRecords.keys {
            guard let identity = identities[recordID] else { continue }
            savedRecords[recordID] = identity
            changeTracker.clearDirty(identity, unlessEditedSince: snapshot)
        }
        return savedRecords
    }

    private func pushedLocalIds(_ snapshot: SyncEditSnapshot) -> [SyncRecordType: Set<String>] {
        var localIds: [SyncRecordType: Set<String>] = [:]
        for type in SyncRecordType.allCases {
            let ids = snapshot.dirtyIds(for: type)
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

    @discardableResult
    private func performPull(echoGuard: SyncEchoGuard? = nil) async -> SyncError? {
        let token = metadataStorage.loadToken()
        let tokenStatus = token == nil ? "nil (full fetch)" : "present (delta)"
        Self.logger.info("Pull starting, token: \(tokenStatus)")

        do {
            let result = try await transport.pull(since: token)
            return await applyPullResult(result, echoGuard: echoGuard) ? nil : .pullNotSaved
        } catch let error where Self.isTokenExpired(error) {
            Self.logger.warning("Change token expired, clearing and retrying with full fetch")
            metadataStorage.saveToken(nil)
            do {
                let result = try await transport.pull(since: nil)
                return await applyPullResult(result, echoGuard: echoGuard) ? nil : .pullNotSaved
            } catch {
                Self.logger.error("Full fetch after token expiry failed: \(error.localizedDescription)")
                return nil
            }
        } catch {
            Self.logger.error("Pull failed: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    internal func applyPullResult(_ result: PullResult, echoGuard: SyncEchoGuard? = nil) async -> Bool {
        let settings = services.appSettingsStorage.loadSync()
        let storesPersisted = applyRemoteChanges(result, settings: settings, echoGuard: echoGuard)
        let favoritesOutcome = await services.sqlFavoriteManager.applyRemote(
            remoteSQLFavoriteBatch(from: result, settings: settings),
            echoGuard: echoGuard
        )

        /// The token and the cache are the record of what this device holds, so neither is
        /// committed over a batch a store refused. Saving the token first acknowledged records that
        /// were never written and the server never sent them again, and the cached record then
        /// stood in as the merge base for an edit that had no local base at all. Not saving it
        /// means the next pull replays the batch, which every apply here is written to survive.
        guard storesPersisted, favoritesOutcome != .failed else {
            Self.logger.error("Pull not acknowledged: a store refused to persist part of the batch")
            return false
        }

        if let newToken = result.newToken {
            metadataStorage.saveToken(newToken)
        }

        recordCache.store(result.changedRecords.filter { record in
            echoGuard?.withholds(record.recordID, tracker: changeTracker) != true
        })
        recordCache.remove(result.deletedRecordIDs)

        Self.logger.info(
            "Pull completed: \(result.changedRecords.count) changed, \(result.deletedRecordIDs.count) deleted"
        )
        return true
    }

    // Performance: storage reads here (loadSync, loadConnections, loadGroups, etc.) run on
    // @MainActor and can block the UI on large sync batches. Consider moving to Task.detached
    // for large payloads.
    /// Reports whether every record that can say so was persisted. A pull that answers false must
    /// not commit its token: the batch has to arrive again.
    private func applyRemoteChanges(_ result: PullResult, settings: SyncSettings, echoGuard: SyncEchoGuard?) -> Bool {
        services.connectionStorage.invalidateCache()

        changeTracker.isSuppressed = true
        defer {
            changeTracker.isSuppressed = false
        }

        var actualConnectionChanges = false
        var groupsOrTagsChanged = false
        var persistenceFailed = false

        let connectionTombstoneIds = Set(metadataStorage.tombstones(for: .connection).map(\.id))
        let groupTombstoneIds = Set(metadataStorage.tombstones(for: .group).map(\.id))
        let tagTombstoneIds = Set(metadataStorage.tombstones(for: .tag).map(\.id))
        let sshTombstoneIds = Set(metadataStorage.tombstones(for: .sshProfile).map(\.id))
        let credentialTombstoneIds = Set(metadataStorage.tombstones(for: .credentialProfile).map(\.id))
        let tableFavoriteTombstoneIds = Set(metadataStorage.tombstones(for: .tableFavorite).map(\.id))
        let databaseFavoriteTombstoneIds = Set(metadataStorage.tombstones(for: .favoriteDatabase).map(\.id))

        for record in result.changedRecords {
            if let echoGuard, echoGuard.withholds(record.recordID, tracker: changeTracker) {
                Self.logger.info("Kept a local edit made while its record was being pushed")
                continue
            }
            switch record.recordType {
            case SyncRecordType.connection.rawValue where settings.syncConnections:
                switch applyRemoteConnection(record, tombstoneIds: connectionTombstoneIds) {
                case .applied: actualConnectionChanges = true
                case .failed: persistenceFailed = true
                case .skipped: break
                }
            case SyncRecordType.group.rawValue where settings.syncGroupsAndTags:
                switch applyRemoteGroup(record, tombstoneIds: groupTombstoneIds) {
                case .applied: groupsOrTagsChanged = true
                case .failed: persistenceFailed = true
                case .skipped: break
                }
            case SyncRecordType.tag.rawValue where settings.syncGroupsAndTags:
                switch applyRemoteTag(record, tombstoneIds: tagTombstoneIds) {
                case .applied: groupsOrTagsChanged = true
                case .failed: persistenceFailed = true
                case .skipped: break
                }
            case SyncRecordType.sshProfile.rawValue where settings.syncSSHProfiles:
                applyRemoteSSHProfile(record, tombstoneIds: sshTombstoneIds)
            case SyncRecordType.credentialProfile.rawValue where settings.syncCredentialProfiles:
                if !applyRemoteCredentialProfile(record, tombstoneIds: credentialTombstoneIds) {
                    persistenceFailed = true
                }
            case SyncRecordType.settings.rawValue where settings.syncSettings:
                applyRemoteSettings(record)
            case SyncRecordType.tableFavorite.rawValue where settings.syncTableFavorites:
                applyRemoteTableFavorite(record, tombstoneIds: tableFavoriteTombstoneIds)
            case SyncRecordType.favoriteDatabase.rawValue where settings.syncDatabaseFavorites:
                applyRemoteDatabaseFavorite(record, tombstoneIds: databaseFavoriteTombstoneIds)
            default:
                break
            }
        }

        let deletions = applyRemoteDeletions(SyncPendingDeletions.parse(result.deletedRecordIDs, settings: settings))
        actualConnectionChanges = actualConnectionChanges || deletions.connectionsChanged
        groupsOrTagsChanged = groupsOrTagsChanged || deletions.groupsOrTagsChanged
        persistenceFailed = persistenceFailed || deletions.persistenceFailed

        /// After the batch, never per record: a pull carries no dependency order, so a legal
        /// hierarchy change spread over two records passes through a state that reads as a cycle
        /// until both have landed.
        if groupsOrTagsChanged {
            services.groupStorage.repairHierarchy()
        }

        if actualConnectionChanges || groupsOrTagsChanged {
            services.appEvents.connectionUpdated.send(nil)
        }

        return !persistenceFailed
    }

    private func remoteSQLFavoriteBatch(from result: PullResult, settings: SyncSettings) -> RemoteSQLFavoriteBatch {
        guard settings.syncSQLFavorites else { return RemoteSQLFavoriteBatch() }

        let deletions = SyncPendingDeletions.parse(result.deletedRecordIDs, settings: settings)
        var batch = RemoteSQLFavoriteBatch(
            deletedFavoriteIds: deletions.sqlFavorites,
            deletedFolderIds: deletions.sqlFolders
        )

        for record in result.changedRecords {
            switch record.recordType {
            case SyncRecordType.favorite.rawValue:
                guard let favorite = try? SyncRecordMapper.sqlFavorite(from: record) else { continue }
                batch.favorites.append(favorite)
            case SyncRecordType.favoriteFolder.rawValue:
                guard let folder = try? SyncRecordMapper.sqlFavoriteFolder(from: record) else { continue }
                batch.folders.append(folder)
            default:
                continue
            }
        }
        return batch
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

    private func applyRemoteConnection(_ record: CKRecord, tombstoneIds: Set<String>) -> RemoteApplyOutcome {
        let remoteConnection: DatabaseConnection
        do {
            remoteConnection = try SyncRecordMapper.toConnection(record)
        } catch {
            Self.logger.error("Skipping remote connection \(record.recordID.recordName, privacy: .public): \(error.publicLogShape, privacy: .public)")
            return .skipped
        }

        if tombstoneIds.contains(remoteConnection.id.uuidString) {
            return .skipped
        }

        var connections = services.connectionStorage.loadConnections()
        if let index = connections.firstIndex(where: { $0.id == remoteConnection.id }) {
            var incoming = remoteConnection
            if changeTracker.dirtyRecords(for: .connection).contains(remoteConnection.id.uuidString) {
                guard let reconciled = mergeLocalEdits(
                    into: record,
                    localConnection: connections[index]
                ) else {
                    return .skipped
                }
                incoming = reconciled
            }
            var merged = incoming
            merged.localOnly = connections[index].localOnly
            merged.passwordSource = connections[index].passwordSource
            /// `credentialMode` has no field on the connection record yet, so a remote update
            /// decodes as `.inline`. Adopting that would unlink the connection from its credential
            /// profile, and linking has already deleted the password it used to hold, so the next
            /// connect would go out with nothing.
            merged.credentialMode = connections[index].credentialMode
            connections[index] = merged
        } else {
            connections.append(remoteConnection)
        }
        guard services.connectionStorage.saveConnections(connections) else {
            Self.logger.error("Failed to apply remote connection update: persistence error for \(remoteConnection.id, privacy: .public)")
            return .failed
        }
        return .applied
    }

    private func applyRemoteGroup(_ record: CKRecord, tombstoneIds: Set<String>) -> RemoteApplyOutcome {
        guard let remoteGroup = SyncRecordMapper.toGroup(record) else { return .skipped }
        if tombstoneIds.contains(remoteGroup.id.uuidString) { return .skipped }

        return services.groupStorage.applyRemoteGroup(remoteGroup)
    }

    @discardableResult
    private func applyRemoteTag(_ record: CKRecord, tombstoneIds: Set<String>) -> RemoteApplyOutcome {
        guard let remoteTag = SyncRecordMapper.toTag(record) else { return .skipped }
        if tombstoneIds.contains(remoteTag.id.uuidString) { return .skipped }

        return services.tagStorage.applyRemoteTag(remoteTag)
    }

    private static func availableProfileName(
        basedOn name: String,
        taken profiles: [CredentialProfile]
    ) -> String {
        let used = Set(profiles.map { $0.name.lowercased() })
        for index in 2...99 {
            let candidate = String(format: String(localized: "%1$@ (%2$lld)"), name, Int64(index))
            if !used.contains(candidate.lowercased()) { return candidate }
        }
        return name
    }

    /// False when the profile could not be persisted, which withholds the pull token so the record
    /// arrives again rather than being acknowledged and lost.
    private func applyRemoteCredentialProfile(_ record: CKRecord, tombstoneIds: Set<String>) -> Bool {
        let remoteProfile: CredentialProfile
        do {
            remoteProfile = try SyncRecordMapper.toCredentialProfile(record)
        } catch {
            Self.logger.error(
                "Skipping remote credential profile \(record.recordID.recordName, privacy: .public): \(error.publicLogShape, privacy: .public)"
            )
            return true
        }
        if tombstoneIds.contains(remoteProfile.id.uuidString) { return true }

        var profiles = services.credentialProfileStorage.loadProfiles()
        if let index = profiles.firstIndex(where: { $0.id == remoteProfile.id }) {
            /// The password mode's payload never crosses the wire, so a `.source` this Mac already
            /// holds is kept rather than replaced by the `prompt` the remote had to send instead.
            var merged = remoteProfile
            if case .source = profiles[index].passwordMode, remoteProfile.passwordMode == .prompt {
                merged.passwordMode = profiles[index].passwordMode
            }
            profiles[index] = merged
        } else {
            /// Two Macs can hold same-named profiles with different ids, which is what happens when
            /// someone recreated one by hand before they synced. The editor forbids duplicate names
            /// and every picker offers a profile by name alone, so the arriving one is renamed
            /// rather than landing as an indistinguishable second row.
            var arriving = remoteProfile
            if profiles.contains(where: { $0.name.compare(arriving.name, options: .caseInsensitive) == .orderedSame }) {
                arriving.name = Self.availableProfileName(basedOn: arriving.name, taken: profiles)
            }
            profiles.append(arriving)
        }
        guard services.credentialProfileStorage.saveProfilesWithoutSync(profiles) else { return false }
        /// The connections linked to it carry a copy of the username, which every raw reader uses.
        services.credentialProfileStorage.writeUsernameThrough(remoteProfile)
        return true
    }

    private func applyRemoteSSHProfile(_ record: CKRecord, tombstoneIds: Set<String>) {
        let remoteProfile: SSHProfile
        do {
            remoteProfile = try SyncRecordMapper.toSSHProfile(record)
        } catch {
            Self.logger.error("Skipping remote SSH profile \(record.recordID.recordName, privacy: .public): \(error.publicLogShape, privacy: .public)")
            return
        }
        if tombstoneIds.contains(remoteProfile.id.uuidString) { return }

        var profiles = services.sshProfileStorage.loadProfiles()
        if let index = profiles.firstIndex(where: { $0.id == remoteProfile.id }) {
            profiles[index] = remoteProfile
        } else {
            profiles.append(remoteProfile)
        }
        guard services.sshProfileStorage.saveProfilesWithoutSync(profiles) else { return }
        /// A linked connection stores the profile's configuration, so an edit that arrives from
        /// another Mac has to reach those connections too or they keep tunnelling to the old host.
        services.sshProfileStorage.refreshLinkedConnections(with: remoteProfile)
    }

    private func applyRemoteSettings(_ record: CKRecord) {
        guard let category = SyncRecordMapper.settingsCategory(from: record),
              let data = SyncRecordMapper.settingsData(from: record)
        else { return }
        do {
            try applySettingsData(data, for: category)
        } catch {
            let recordName = record.recordID.recordName
            Self.logger.error(
                "Skipping remote settings \(recordName, privacy: .private(mask: .hash)) (\(category, privacy: .private(mask: .hash))): \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)"
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
            Self.logger.error(
                "Skipping remote favorite table \(recordName, privacy: .private(mask: .hash)): \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)"
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
            Self.logger.error(
                "Skipping remote favorite database \(recordName, privacy: .private(mask: .hash)): \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)"
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
            let status = try await transport.accountStatus()
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
        try await transport.currentAccountId()
    }
}
