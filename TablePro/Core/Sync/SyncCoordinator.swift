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

    let services: AppServices
    private let transport: any SyncTransport
    let changeTracker: SyncChangeTracker
    let metadataStorage: SyncMetadataStorage
    let recordCache: SyncRecordCache
    let columnLayouts: () -> FileColumnLayoutPersister
    private let networkMonitor: SyncNetworkMonitor?
    private let accountObserver = OSAllocatedUnfairLock<(any NSObjectProtocol)?>(uncheckedState: nil)
    private var changeCancellable: AnyCancellable?
    private var licenseCancellable: AnyCancellable?
    private var debounceTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var hasStarted = false
    private var isRunning = false
    private var isRunningCycle = false
    private var hasDeferredNotificationPull = false
    private var notificationPull: Task<Void, Never>?

    /// Triggers that arrived while a run was in flight. One more run follows it rather than the
    /// trigger cancelling it: a cancelled run reported itself as a failure.
    private var pendingTriggers: [SyncTrigger] = []

    /// Upload Again pressed while an automatic check was running. The notice stays on screen during
    /// that check, so the button does too, and the person's answer must not be lost to it.
    private var uploadAgainRequested = false

    /// Failed runs in a row, which sets how far the next attempt is held back.
    private var consecutiveFailures = 0

    /// When the upload that failed may be tried again by a trigger that does not change the situation.
    private var nextAttempt: Date?

    /// The end of the wait CloudKit named on its last throttle. No automatic run starts before it.
    private var throttledUntil: Date?

    /// Bumped every time something other than a sync run decides the status, so a run that has been
    /// suspended across the network can tell whether its outcome is still the current answer.
    private var statusGeneration = 0

    init(
        services: AppServices = .live,
        recordCache: SyncRecordCache = SyncCoordinator.makeRecordCache(),
        transport: any SyncTransport = CloudKitSyncEngine(),
        networkMonitor: SyncNetworkMonitor? = SyncNetworkMonitor(),
        columnLayouts: @escaping @autoclosure () -> FileColumnLayoutPersister = .shared
    ) {
        self.services = services
        self.transport = transport
        self.networkMonitor = networkMonitor
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
        debounceTask?.cancel()
        retryTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Call from AppDelegate at launch
    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        observeAccountChanges()
        observeLocalChanges()
        observeLicenseChanges()
        observeNetwork()

        // If local storage is empty (fresh install or wiped), clear the sync token
        // to force a full fetch instead of a delta that returns nothing
        if services.connectionStorage.loadConnections().isEmpty {
            metadataStorage.saveToken(nil)
            Self.logger.info("No local connections — cleared sync token for full fetch")
        }

        /// A pull returns only what changed since the token, so records of a type an earlier build
        /// did not sync were passed over for good. The first run of a build that syncs more types
        /// fetches the zone again, which is how table folders made on an upgraded Mac reach one that
        /// upgrades later. Counted over the types verified in Production, because an unverified type
        /// has no records on the server to fetch.
        if metadataStorage.adoptReadableRecordTypes(Set(SyncRecordType.verifiedInProduction.map(\.rawValue))) {
            metadataStorage.saveToken(nil)
            Self.logger.info("This build reads record types the last one did not: cleared sync token for full fetch")
        }

        evaluateStatus()
        guard syncStatus.isEnabled else { return }
        Task { await sync(.launch) }
    }

    /// Called when the app comes to the foreground
    func syncIfNeeded() {
        requestSync(.activation)
    }

    /// Sync Now: the person asked, so it runs whatever held the last attempt back.
    func syncNow() async {
        await sync(.userRequest)
    }

    func requestSync(_ trigger: SyncTrigger) {
        guard syncStatus.isEnabled else { return }
        Task { await sync(trigger) }
    }

    /// Runs as much of a sync as `trigger` is admitted to, given how the last run ended.
    func sync(_ trigger: SyncTrigger) async {
        guard canSync() else {
            Self.logger.info("Sync skipped: not allowed for \(String(describing: trigger), privacy: .public)")
            return
        }
        guard !isRunning else {
            if !pendingTriggers.contains(trigger) {
                pendingTriggers.append(trigger)
            }
            return
        }

        let previousError = syncStatus.error
        let admission = SyncAdmission.decide(
            for: trigger,
            after: previousError,
            nextAttempt: nextAttempt,
            throttledUntil: throttledUntil
        )
        guard admission != .none else {
            Self.logger.info("Sync held back for \(String(describing: trigger), privacy: .public)")
            return
        }

        let generation = statusGeneration
        isRunning = true
        /// A standing condition stays on screen through the automatic runs that check on it, so the
        /// notice does not blink away at every activation. Only the person's own request shows
        /// progress over it.
        if previousError == nil || trigger == .userRequest {
            syncStatus = .syncing
        }
        let result = await performCycle(admission)
        isRunning = false
        finish(result, previousError: previousError, from: generation)
        if uploadAgainRequested {
            uploadAgainRequested = false
            await uploadAgain()
        }
        await runPendingTrigger()
    }

    internal func runSyncCycle(_ admission: SyncAdmission = .full) async -> SyncError? {
        await performCycle(admission).failure?.error
    }

    private struct CycleResult {
        var admission: SyncAdmission
        var failure: SyncStepFailure?
    }

    private func performCycle(_ admission: SyncAdmission) async -> CycleResult {
        isRunningCycle = true
        await notificationPull?.value
        let result = await accountThenPushThenPull(admission)
        isRunningCycle = false
        if hasDeferredNotificationPull {
            hasDeferredNotificationPull = false
            await pullForRemoteNotification()
        }
        return result
    }

    private func accountThenPushThenPull(_ requested: SyncAdmission) async -> CycleResult {
        var admission = requested
        switch await confirmAccount() {
        case .unavailable(let failure):
            return CycleResult(admission: admission, failure: failure)
        case .ready(let isNewAccount):
            /// A condition the last account was under says nothing about this one.
            if isNewAccount {
                admission = .full
            }
        }

        /// Only a run that may upload creates the zone. A download looks for it, and finding it
        /// again is how this Mac learns another device brought deleted data back.
        if metadataStorage.zoneState.createsZone(in: admission) {
            do {
                try await transport.ensureZoneExists()
                metadataStorage.zoneState = .confirmed
            } catch {
                Self.logger.error("Sync failed: \(error.localizedDescription)")
                return CycleResult(admission: admission, failure: await refined(SyncStepFailure(error)))
            }
        }

        let push = admission == .full ? await performPush() : PushReport()
        let pullFailure = await performPull(echoGuard: push.echoGuard)
        while hasDeferredNotificationPull {
            hasDeferredNotificationPull = false
            await performPull(echoGuard: push.echoGuard)
        }

        let zone = metadataStorage.zoneState
        let download = zone.reconciled(downloadFailure: pullFailure)
        var failure = SyncStepFailure.decisive(upload: push.failure, download: download)
        if let decisive = failure {
            failure = await refined(decisive)
        }
        metadataStorage.zoneState = zone.after(failure: failure, reachedZone: pullFailure == nil)
        return CycleResult(admission: admission, failure: failure)
    }

    /// Reads the account before any request, so a signed-out or restricted account is reported as
    /// itself rather than as whatever the first request fails with. Adopting its id is what keeps
    /// another account's token, tombstones and cached records from being used against this one.
    private func confirmAccount() async -> AccountCheck {
        do {
            if let blocker = SyncBlocker(accountStatus: try await transport.accountStatus()) {
                return .unavailable(SyncStepFailure(failure: .blocked(blocker), error: .blocked(blocker), retryAfter: nil))
            }
            return .ready(isNewAccount: adoptAccount(try await transport.currentAccountId()))
        } catch {
            Self.logger.error("Could not read the iCloud account: \(error.localizedDescription)")
            return .unavailable(await refined(SyncStepFailure(error)))
        }
    }

    private enum AccountCheck {
        /// Whether the account differs from the one this Mac last synced with.
        case ready(isNewAccount: Bool)
        case unavailable(SyncStepFailure)
    }

    private func adoptAccount(_ accountId: String) -> Bool {
        switch metadataStorage.adoptAccount(accountId) {
        case .firstSeen, .unchanged:
            return false
        case .switched:
            Self.logger.notice("The iCloud account changed, so sync starts over and pending edits go to the new account")
        case .previousAccountUnknown:
            Self.logger.notice("An earlier build synced without recording its iCloud account, so sync starts over once")
        }
        recordCache.removeAll()
        lastSyncDate = metadataStorage.lastSyncDate
        return true
    }

    /// CloudKit fails an operation with `notAuthenticated` for every account state that is not
    /// available, so a fresh status read says which one it is. Signed in by that read, the account
    /// is not ready yet rather than signed out.
    private func refined(_ failure: SyncStepFailure) async -> SyncStepFailure {
        guard case .blocked(let blocker) = failure.failure, blocker.isAccountState else { return failure }
        let status = try? await transport.accountStatus()
        let actual = status.flatMap { SyncBlocker(accountStatus: $0) } ?? .accountNotReady
        return SyncStepFailure(failure: .blocked(actual), error: .blocked(actual), retryAfter: failure.retryAfter)
    }

    /// Publishes the outcome of a sync run, unless something decided the status while it was in
    /// flight.
    ///
    /// A run reads `canSync()` once on entry and then suspends across the whole CloudKit round
    /// trip, so turning sync off, or losing the license, used to be overwritten by the returning
    /// run: the indicator went back to "Synced" for a sync that would now be refused. Whoever
    /// decided last wins, and a stale run reports nothing.
    private func finish(_ result: CycleResult, previousError: SyncError?, from generation: Int) {
        guard generation == statusGeneration else {
            Self.logger.info("Discarding a sync outcome the status moved on from")
            return
        }
        let settlement = SyncSettlement(failure: result.failure, admission: result.admission, previousError: previousError)
        if settlement.stampsLastSync {
            stampLastSync()
        }
        if settlement.resetsRetry {
            resetRetryState()
        }
        if settlement.needsUpload, !pendingTriggers.contains(.scheduledRetry) {
            pendingTriggers.append(.scheduledRetry)
        }
        if let counted = settlement.countedFailure {
            consecutiveFailures += 1
            let delay = SyncRetryPolicy.nextAttemptDelay(
                after: counted,
                consecutiveFailures: consecutiveFailures,
                retryAfter: result.failure?.retryAfter
            )
            nextAttempt = delay.map { Date().addingTimeInterval($0) }
            scheduleRetry(after: delay)
        }
        if settlement.throttles {
            let wait = SyncRetryPolicy.nextAttemptDelay(
                after: .busy,
                consecutiveFailures: 1,
                retryAfter: result.failure?.retryAfter
            ) ?? 30
            let until = Date().addingTimeInterval(wait)
            throttledUntil = until
            /// A held upload's own timer must not fire inside the throttle.
            if let next = nextAttempt, next < until {
                nextAttempt = until
                scheduleRetry(after: wait)
            }
        } else {
            throttledUntil = nil
        }
        syncStatus = settlement.status
        if settlement.status == .idle, result.admission == .full {
            Self.logger.info("Sync completed successfully")
        }
    }

    private func stampLastSync() {
        lastSyncDate = Date()
        metadataStorage.lastSyncDate = lastSyncDate
    }

    private func scheduleRetry(after delay: TimeInterval?) {
        retryTask?.cancel()
        retryTask = nil
        guard let delay else { return }
        Self.logger.info("Next sync attempt in \(Int(delay), privacy: .public) s")
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(delay / 10))
            guard !Task.isCancelled else { return }
            await self?.sync(.scheduledRetry)
        }
    }

    private func resetRetryState() {
        consecutiveFailures = 0
        nextAttempt = nil
        throttledUntil = nil
        retryTask?.cancel()
        retryTask = nil
    }

    /// Runs once for whatever arrived during the last run, with the trigger that may do the most.
    private func runPendingTrigger() async {
        guard !pendingTriggers.isEmpty else { return }
        let error = syncStatus.error
        /// The network coming back mid-run matters only if the run ended unable to reach iCloud.
        let triggers = pendingTriggers.filter { $0 != .networkRestored || error == .offline }
        pendingTriggers = []
        let attempt = nextAttempt
        let throttle = throttledUntil
        let reach: (SyncTrigger) -> Int = { trigger in
            switch SyncAdmission.decide(for: trigger, after: error, nextAttempt: attempt, throttledUntil: throttle) {
            case .full: return 2
            case .downloadOnly: return 1
            case .none: return 0
            }
        }
        guard let next = triggers.max(by: { reach($0) < reach($1) }), reach(next) > 0 else { return }
        await sync(next)
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
        /// Turning sync on is the person's choice to upload, a removed zone included.
        metadataStorage.zoneState = .unknown

        // Mark ALL existing local data as dirty so it gets pushed on first sync
        markAllLocalDataDirty()
        let dirtyCount = changeTracker.dirtyRecords(for: .connection).count
        Self.logger.info("enableSync() dirty marking done, dirty connections: \(dirtyCount)")

        evaluateStatus()
        guard syncStatus.isEnabled else { return }
        Task {
            await markSQLFavoritesDirty()
            await sync(.userRequest)
        }
    }

    /// The person's answer after TablePro's data was removed from iCloud: upload everything on this
    /// Mac again. Never done without asking, which is Apple's guidance for a purged zone.
    func uploadAgain() async {
        guard syncStatus.error == .blocked(.dataDeletedFromICloud) else { return }
        guard !isRunning else {
            uploadAgainRequested = true
            return
        }
        metadataStorage.zoneState = .unknown
        metadataStorage.saveToken(nil)
        recordCache.removeAll()
        markAllLocalDataDirty()
        await markSQLFavoritesDirty()
        /// Sync may have been turned off while the favorites were read.
        guard syncStatus.error == .blocked(.dataDeletedFromICloud) else { return }
        resetRetryState()
        decide(.idle)
        await sync(.userRequest)
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
    /// record, and an account with a few hundred saved column layouts built a chain of hundreds of
    /// tasks each waiting on its predecessor until the app stopped responding to the switch that
    /// started it.
    private func markAllLocalDataDirty() {
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
        changeTracker.markDirty(.settings, ids: settingsCategories + columnLayoutCategories)

        let summary = [
            "connections=\(connections.count)",
            "groups=\(groups.count)",
            "tags=\(tags.count)",
            "sshProfiles=\(sshProfiles.count)",
            "favoriteTables=\(favoriteTables.count)",
            "tableFolders=\(tableFolderIds.folders.count)",
            "settings=\(AppSettingsCategory.synced.count + 1)"
        ].joined(separator: ", ")
        Self.logger.info("Marked all local data dirty: \(summary, privacy: .public)")
    }

    /// Called when user disables sync in settings
    func disableSync() {
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

        /// Only a move out of disabled is decided here. An error stays until a run clears it: a
        /// license or account notification is no evidence that storage was freed.
        if case .disabled = syncStatus {
            decide(metadataStorage.zoneState.initialStatus)
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
        guard !status.isEnabled else { return }
        resetRetryState()
        pendingTriggers = []
        debounceTask?.cancel()
        debounceTask = nil
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

        return true
    }

    // MARK: - Push

    private struct PushReport {
        var echoGuard: SyncEchoGuard?
        var failure: SyncStepFailure?
    }

    private func performPush() async -> PushReport {
        let snapshot = changeTracker.editSnapshot()
        let boundary = syncBoundary(settings: services.appSettingsStorage.loadSync())
        let zoneID = await transport.currentZoneID
        let batch = await collectPushBatch(snapshot: snapshot, boundary: boundary, zoneID: zoneID)
        let deletions = batch.uniqueDeletions

        guard !batch.records.isEmpty || !deletions.isEmpty else {
            pruneTombstones(within: boundary)
            return PushReport()
        }

        let identities = SyncRecordMapper.identities(for: pushedLocalIds(snapshot), in: zoneID)
        var outcome: PushOutcome
        var interruption: Error?
        do {
            outcome = try await transport.push(records: batch.records, deletions: deletions)
        } catch let interrupted as SyncPushInterruption {
            outcome = interrupted.completed
            interruption = interrupted.cause
        } catch {
            Self.logger.error("Push failed: \(error.localizedDescription)")
            return PushReport(failure: SyncStepFailure(error))
        }
        outcome.acceptMissingDeletions(of: deletions)

        recordCache.store(Array(outcome.savedRecords.values))
        recordCache.remove(Array(outcome.deletedRecordIDs))

        let savedRecords = settleSavedRecords(outcome, batch: batch, identities: identities, snapshot: snapshot)

        var deletedRecords: [CKRecord.ID: SyncRecordIdentity] = [:]
        for recordID in outcome.deletedRecordIDs {
            guard let identity = identities[recordID] else { continue }
            deletedRecords[recordID] = identity
            metadataStorage.removeTombstone(identity.id, type: identity.type)
        }

        let savedCount = outcome.savedRecords.count
        let deletedCount = outcome.deletedRecordIDs.count
        let rejectedCount = outcome.failures.count
        Self.logger.info("Push completed: \(savedCount) saved, \(deletedCount) deleted, \(rejectedCount) rejected")

        let echoGuard = SyncEchoGuard(snapshot: snapshot, savedRecords: savedRecords, deletedRecords: deletedRecords)
        let itemFailure = SyncStepFailure(outcome)
        if let interruption {
            Self.logger.error("Push stopped part way: \(interruption.localizedDescription)")
            /// A blocker an earlier batch hit explains the interruption too; anything less does not.
            let failure = itemFailure.flatMap { $0.failure.stopsUpload ? $0 : nil } ?? SyncStepFailure(interruption)
            return PushReport(echoGuard: echoGuard, failure: failure)
        }
        guard let itemFailure else {
            pruneTombstones(within: boundary)
            return PushReport(echoGuard: echoGuard)
        }
        Self.logger.error("Push left \(rejectedCount, privacy: .public) items pending: \(String(describing: itemFailure.failure), privacy: .public)")
        return PushReport(echoGuard: echoGuard, failure: itemFailure)
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
            guard !changeTracker.hasEdit(identity, since: snapshot) else { continue }
            if batch.supersededTombstones.contains(identity) {
                metadataStorage.removeTombstone(identity.id, type: identity.type)
            }
            changeTracker.clearDirty(identity.type, id: identity.id)
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
        SyncFailure(error) == .tokenExpired
    }

    /// Reports a failed download instead of passing over it: a run whose pull failed did not bring
    /// this Mac up to date, and must not say Synced or move Last Synced.
    @discardableResult
    private func performPull(echoGuard: SyncEchoGuard? = nil) async -> SyncStepFailure? {
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
                return SyncStepFailure(error)
            }
        } catch {
            Self.logger.error("Pull failed: \(error.localizedDescription)")
            return SyncStepFailure(error)
        }
    }

    @discardableResult
    internal func applyPullResult(_ result: PullResult, echoGuard: SyncEchoGuard? = nil) async -> Bool {
        let settings = services.appSettingsStorage.loadSync()
        let deletedRecordIDs = result.deletedRecordIDs.filter { recordID in
            echoGuard?.withholdsDeletion(recordID, tracker: changeTracker) != true
        }
        let storesPersisted = applyRemoteChanges(
            result,
            deletedRecordIDs: deletedRecordIDs,
            settings: settings,
            echoGuard: echoGuard
        )
        let favoritesOutcome = await services.sqlFavoriteManager.applyRemote(
            remoteSQLFavoriteBatch(from: result, deletedRecordIDs: deletedRecordIDs, settings: settings),
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
    private func applyRemoteChanges(
        _ result: PullResult,
        deletedRecordIDs: [CKRecord.ID],
        settings: SyncSettings,
        echoGuard: SyncEchoGuard?
    ) -> Bool {
        services.connectionStorage.invalidateCache()

        changeTracker.isSuppressed = true
        let effects = applyRemoteRecords(
            result.changedRecords,
            deletedRecordIDs: deletedRecordIDs,
            settings: settings,
            echoGuard: echoGuard
        )
        changeTracker.isSuppressed = false

        changeTracker.markDeleted(.tableFavorite, idsByOwner: effects.tableFavoriteIdsToRetire)
        return !effects.persistenceFailed
    }

    private func applyRemoteRecords(
        _ changedRecords: [CKRecord],
        deletedRecordIDs: [CKRecord.ID],
        settings: SyncSettings,
        echoGuard: SyncEchoGuard?
    ) -> SyncRemoteDeletionEffects {
        var actualConnectionChanges = false
        var groupsOrTagsChanged = false
        var persistenceFailed = false

        let connectionTombstoneIds = Set(metadataStorage.tombstones(for: .connection).map(\.id))
        let groupTombstoneIds = Set(metadataStorage.tombstones(for: .group).map(\.id))
        let tagTombstoneIds = Set(metadataStorage.tombstones(for: .tag).map(\.id))
        let sshTombstoneIds = Set(metadataStorage.tombstones(for: .sshProfile).map(\.id))
        let credentialTombstoneIds = Set(metadataStorage.tombstones(for: .credentialProfile).map(\.id))
        let settingsTombstoneIds = Set(metadataStorage.tombstones(for: .settings).map(\.id))
        let tableFavoriteTombstoneIds = Set(metadataStorage.tombstones(for: .tableFavorite).map(\.id))
        var tableFavorites: [FavoriteTablesStorage.FavoriteEntry] = []
        let databaseFavoriteTombstoneIds = Set(metadataStorage.tombstones(for: .favoriteDatabase).map(\.id))
        var tableFolderRecords: [CKRecord] = []

        for record in changedRecords {
            if let echoGuard, echoGuard.withholds(record.recordID, tracker: changeTracker) {
                Self.logger.info("Kept a local edit made while its record was being pushed")
                continue
            }
            guard let type = SyncRecordType(rawValue: record.recordType), settings.syncs(type) else { continue }
            switch type {
            case .connection:
                switch applyRemoteConnection(record, tombstoneIds: connectionTombstoneIds) {
                case .applied: actualConnectionChanges = true
                case .failed: persistenceFailed = true
                case .skipped: break
                }
            case .group:
                switch applyRemoteGroup(record, tombstoneIds: groupTombstoneIds) {
                case .applied: groupsOrTagsChanged = true
                case .failed: persistenceFailed = true
                case .skipped: break
                }
            case .tag:
                switch applyRemoteTag(record, tombstoneIds: tagTombstoneIds) {
                case .applied: groupsOrTagsChanged = true
                case .failed: persistenceFailed = true
                case .skipped: break
                }
            case .sshProfile:
                applyRemoteSSHProfile(record, tombstoneIds: sshTombstoneIds)
            case .credentialProfile:
                if !applyRemoteCredentialProfile(record, tombstoneIds: credentialTombstoneIds) {
                    persistenceFailed = true
                }
            case .settings:
                applyRemoteSettings(record, tombstoneIds: settingsTombstoneIds)
            case .tableFavorite:
                if let favorite = remoteTableFavorite(record, tombstoneIds: tableFavoriteTombstoneIds) {
                    tableFavorites.append(favorite)
                }
            case .favoriteDatabase:
                applyRemoteDatabaseFavorite(record, tombstoneIds: databaseFavoriteTombstoneIds)
            case .tableFolder, .tableFolderItem:
                tableFolderRecords.append(record)
            case .favorite, .favoriteFolder:
                break
            }
        }
        applyRemoteTableFolderRecords(tableFolderRecords)

        var effects = applyRemoteDeletions(
            SyncPendingDeletions.parse(deletedRecordIDs, settings: settings),
            alongside: tableFavorites
        )
        actualConnectionChanges = actualConnectionChanges || effects.connectionsChanged
        groupsOrTagsChanged = groupsOrTagsChanged || effects.groupsOrTagsChanged
        effects.persistenceFailed = persistenceFailed || effects.persistenceFailed

        /// After the batch, never per record: a pull carries no dependency order, so a legal
        /// hierarchy change spread over two records passes through a state that reads as a cycle
        /// until both have landed.
        if groupsOrTagsChanged {
            services.groupStorage.repairHierarchy()
        }

        if actualConnectionChanges || groupsOrTagsChanged {
            services.appEvents.connectionUpdated.send(nil)
        }

        return effects
    }

    private func remoteSQLFavoriteBatch(
        from result: PullResult,
        deletedRecordIDs: [CKRecord.ID],
        settings: SyncSettings
    ) -> RemoteSQLFavoriteBatch {
        guard settings.syncSQLFavorites else { return RemoteSQLFavoriteBatch() }

        let deletions = SyncPendingDeletions.parse(deletedRecordIDs, settings: settings)
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
            guard !connections[index].localOnly else { return .skipped }
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
            connections[index] = incoming.adoptingDeviceLocalState(from: connections[index])
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

    private func applyRemoteSettings(_ record: CKRecord, tombstoneIds: Set<String>) {
        guard let category = SyncRecordMapper.settingsCategory(from: record),
              !tombstoneIds.contains(category),
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

    private func remoteTableFavorite(
        _ record: CKRecord,
        tombstoneIds: Set<String>
    ) -> FavoriteTablesStorage.FavoriteEntry? {
        let recordName = record.recordID.recordName
        let entry: FavoriteTablesStorage.FavoriteEntry
        do {
            entry = try SyncRecordMapper.favoriteEntry(from: record)
        } catch {
            Self.logger.error(
                "Skipping remote favorite table \(recordName, privacy: .private(mask: .hash)): \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)"
            )
            return nil
        }
        guard let recordId = SyncRecordType.parse(recordName: recordName)?.id,
              !tombstoneIds.contains(recordId),
              !tombstoneIds.contains(FavoriteTablesStorage.syncId(for: entry)) else { return nil }
        return entry
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

    /// The run that follows reads the account and adopts its id, so a sign-out, a switch to another
    /// account, and an account becoming ready are all handled where every other run handles them.
    private func observeAccountChanges() {
        let observer = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.requestSync(.accountChange)
            }
        }
        accountObserver.withLockUnchecked { $0 = observer }
    }

    /// A debounce that has elapsed is never cancelled: an edit made while its run is in flight queues
    /// one more run instead, because cancelling the run mid-request reported a failure.
    private func observeLocalChanges() {
        changeCancellable = services.appEvents.syncChangeTracked
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, syncStatus.isEnabled else { return }
                debounceTask?.cancel()
                debounceTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(2))
                    } catch {
                        return
                    }
                    guard let self else { return }
                    debounceTask = nil
                    await sync(.localChange)
                }
            }
    }

    private func observeLicenseChanges() {
        licenseCancellable = services.appEvents.licenseStatusDidChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                evaluateStatus()
                requestSync(.launch)
            }
    }

    /// The path can come back while a run is still retrying, before that run reports it could not
    /// reach iCloud, and the monitor reports the return only once. So a return during a run is kept
    /// for when it ends.
    private func observeNetwork() {
        networkMonitor?.start { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if isRunning {
                    if !pendingTriggers.contains(.networkRestored) {
                        pendingTriggers.append(.networkRestored)
                    }
                } else if syncStatus.error == .offline {
                    requestSync(.networkRestored)
                }
            }
        }
    }
}
