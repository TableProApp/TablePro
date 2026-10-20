import CloudKit
import Combine
import Foundation
import Observation
import os
import TableProModels
import TableProSync
import TableProSyncTransport

@MainActor @Observable
final class IOSSyncCoordinator {
    typealias LibraryState = (connections: [DatabaseConnection], groups: [ConnectionGroup], tags: [ConnectionTag])

    private struct EditKey: Hashable {
        let type: SyncRecordType
        let id: String
    }

    /// A run that adopts a new account runs in full whatever it was admitted to, so the admission
    /// that settles it travels with its outcome.
    private struct RunResult {
        let admission: SyncAdmission
        let failure: SyncStepFailure?
    }

    private enum AccountCheck {
        case ready(isNewAccount: Bool)
        case failed(SyncStepFailure)
        case superseded
    }

    private enum RemoteApply {
        case saved
        // Connections, groups and tags landed and the saved queries did not, so only the token waits.
        case savedQueriesHeld
        case notSaved
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "Sync")

    static let readableRecordTypes = Set(
        [SyncRecordType.connection, .group, .tag, .favorite, .favoriteFolder].map(\.rawValue)
    )

    private(set) var status: SyncStatus
    private(set) var lastSyncDate: Date?

    @ObservationIgnored private let metadata: SyncMetadataStorage
    @ObservationIgnored private let recordCache: SyncRecordCache
    @ObservationIgnored private let makeTransport: () -> any IOSSyncTransport
    @ObservationIgnored private let isEnabled: () -> Bool
    @ObservationIgnored private let networkMonitor: SyncNetworkMonitor?
    @ObservationIgnored private var transport: (any IOSSyncTransport)?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var runningSync: Task<Void, Never>?

    /// Triggers that arrived while a run was in flight. One more run follows it rather than any of
    /// them cancelling it: a cancelled request reported itself as a failure.
    @ObservationIgnored private var pendingTriggers: [SyncTrigger] = []

    /// Failed runs in a row, which sets how far the next attempt is held back.
    @ObservationIgnored private var consecutiveFailures = 0

    /// When an upload held back by the last failure may be tried by a trigger that changes nothing.
    @ObservationIgnored private var nextAttempt: Date?

    /// The end of the wait CloudKit named on its last throttle. No automatic run starts before it.
    @ObservationIgnored private var throttledUntil: Date?

    /// Bumped whenever something other than a run decides the status, so a run that suspended
    /// across the network can tell its outcome is no longer the current answer.
    @ObservationIgnored private var statusGeneration = 0
    @ObservationIgnored private var editGenerations: [EditKey: Int] = [:]
    @ObservationIgnored private var accountChangeObservation: AnyCancellable?

    // Each returns whether the merged list was saved; false holds the change token for a replay.
    @ObservationIgnored var onConnectionsChanged: (([DatabaseConnection]) -> Bool)?
    @ObservationIgnored var onGroupsChanged: (([ConnectionGroup]) -> Bool)?
    @ObservationIgnored var onTagsChanged: (([ConnectionTag]) -> Bool)?
    @ObservationIgnored var getCurrentState: (() -> LibraryState?)?
    @ObservationIgnored var getSavedQueries: (() -> SavedQueryContents?)?
    @ObservationIgnored var onSavedQueriesChanged: ((SavedQueryContents) -> Bool)?

    private static var recordCacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("TablePro/SyncRecordCache", isDirectory: true)
    }

    init(
        metadata: SyncMetadataStorage = SyncMetadataStorage(userDefaults: .standard),
        recordCache: SyncRecordCache = SyncRecordCache(
            directory: IOSSyncCoordinator.recordCacheDirectory,
            defaults: .standard
        ),
        makeTransport: @escaping () -> any IOSSyncTransport = { CloudKitSyncEngine() },
        isEnabled: @escaping () -> Bool = { AppPreferences.isCloudSyncEnabled },
        notificationCenter: NotificationCenter = .default,
        networkMonitor: SyncNetworkMonitor? = SyncNetworkMonitor()
    ) {
        self.metadata = metadata
        self.recordCache = recordCache
        self.makeTransport = makeTransport
        self.isEnabled = isEnabled
        self.networkMonitor = networkMonitor
        self.status = isEnabled() ? metadata.zoneState.initialStatus : .disabled(.userDisabled)
        self.lastSyncDate = metadata.lastSyncDate
        accountChangeObservation = notificationCenter.publisher(for: .CKAccountChanged)
            .sink { @Sendable [weak self] _ in
                Task { @MainActor in
                    await self?.sync(.accountChange)
                }
            }
        networkMonitor?.start { [weak self] in
            Task { @MainActor in
                self?.networkDidReturn()
            }
        }
    }

    deinit {
        debounceTask?.cancel()
        retryTask?.cancel()
    }

    private func currentTransport() -> any IOSSyncTransport {
        if let transport { return transport }
        let created = makeTransport()
        transport = created
        return created
    }

    var hasCompletedFirstSync: Bool {
        lastSyncDate != nil
    }

    func accountStatus() async -> CKAccountStatus {
        do {
            return try await currentTransport().accountStatus()
        } catch {
            Self.logger.warning("iCloud account status unavailable: \(error.localizedDescription, privacy: .private)")
            return .couldNotDetermine
        }
    }

    // MARK: - Enable / Disable

    func setEnabled(_ enabled: Bool) {
        resetRetryState()
        guard enabled else {
            debounceTask?.cancel()
            debounceTask = nil
            pendingTriggers = []
            metadata.lastSyncDate = nil
            lastSyncDate = nil
            decide(.disabled(.userDisabled))
            return
        }
        /// Turning sync on is the person's choice to upload, into a removed zone too.
        if metadata.zoneState == .removed {
            prepareFullUpload()
        }
        decide(.idle)
        Task { await sync(.userRequest) }
    }

    /// The person's answer after TablePro's data was removed from iCloud: upload everything this
    /// device holds again. Never done on a trigger, which is Apple's guidance for a purged zone.
    func uploadAgain() async {
        /// The notice, and its button, stay on screen during an automatic check of the zone, so the
        /// person's answer waits for that check rather than being dropped.
        await runningSync?.value
        guard status.error == .blocked(.dataDeletedFromICloud) else { return }
        prepareFullUpload()
        resetRetryState()
        decide(.idle)
        await sync(.userRequest)
    }

    private func prepareFullUpload() {
        metadata.saveToken(nil)
        metadata.zoneState = .unknown
        recordCache.removeAll()
        markAllLocalDataDirty()
    }

    // MARK: - Sync

    /// Runs as much of a sync as `trigger` is admitted to, given how the last run ended. A trigger
    /// that arrives while a run is in flight queues one more run and waits for both.
    func sync(_ trigger: SyncTrigger = .userRequest) async {
        guard isEnabled() else {
            if status != .disabled(.userDisabled) {
                decide(.disabled(.userDisabled))
            }
            return
        }
        if let runningSync {
            if !pendingTriggers.contains(trigger) {
                pendingTriggers.append(trigger)
            }
            await runningSync.value
            return
        }
        let task = Task { await runThenPending(trigger) }
        runningSync = task
        await task.value
    }

    private func runThenPending(_ trigger: SyncTrigger) async {
        var next: SyncTrigger? = trigger
        while let current = next {
            await run(current)
            next = takePendingTrigger()
        }
        runningSync = nil
    }

    private func run(_ trigger: SyncTrigger) async {
        guard isEnabled() else {
            if status != .disabled(.userDisabled) {
                decide(.disabled(.userDisabled))
            }
            return
        }
        guard getCurrentState?() != nil else {
            Self.logger.info("Sync skipped: the library has not loaded")
            return
        }
        let previousError = status.error
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
        /// A standing condition stays on screen through the automatic runs that check on it, so the
        /// notice does not blink away at every foreground. Only the person's own request shows
        /// progress over it.
        if previousError == nil || trigger == .userRequest {
            status = .syncing
        }
        guard let result = await perform(admission, generation: generation) else {
            Self.logger.info("Discarding a sync run the status moved on from")
            return
        }
        finish(result, previousError: previousError, from: generation)
    }

    /// The trigger that may do the most among those that arrived during the last run.
    private func takePendingTrigger() -> SyncTrigger? {
        guard !pendingTriggers.isEmpty else { return nil }
        let error = status.error
        /// The network coming back mid-run matters only if the run ended unable to reach iCloud.
        let triggers = pendingTriggers.filter { $0 != .networkRestored || error == .offline }
        pendingTriggers = []
        let attempt = nextAttempt
        let throttle = throttledUntil
        let reach: (SyncTrigger) -> Int = { trigger in
            let scope: Int
            switch SyncAdmission.decide(for: trigger, after: error, nextAttempt: attempt, throttledUntil: throttle) {
            case .full: scope = 2
            case .downloadOnly: scope = 1
            case .none: return 0
            }
            /// Between equals, the person's request wins, since only it shows progress.
            return scope * 2 + (trigger == .userRequest ? 1 : 0)
        }
        guard let next = triggers.max(by: { reach($0) < reach($1) }), reach(next) > 0 else { return nil }
        return next
    }

    /// Nil when the status moved on while the run was in flight.
    private func perform(_ requested: SyncAdmission, generation: Int) async -> RunResult? {
        let transport = currentTransport()
        var admission = requested
        switch await confirmAccount(using: transport, generation: generation) {
        case .superseded:
            return nil
        case .failed(let failure):
            return RunResult(admission: admission, failure: failure)
        case .ready(let isNewAccount):
            /// A condition the last account was under says nothing about this one.
            if isNewAccount {
                admission = .full
            }
        }

        guard let result = await pullThenPush(admission, generation: generation, using: transport) else { return nil }
        let zone = metadata.zoneState
        let nextZone = zone.after(failure: result.failure, reachedZone: false)
        /// The old zone's records went with it. Kept, their system fields would make every later
        /// save into a zone another device recreated fail as an unknown record.
        if nextZone == .removed, zone != .removed {
            recordCache.removeAll()
            metadata.saveToken(nil)
        }
        metadata.zoneState = nextZone
        return result
    }

    /// Reads the account before any request, so a signed-out or restricted account is reported as
    /// itself rather than as whatever the first request fails with. Adopting its id is what keeps
    /// another account's token, tombstones and cached records from being used against this one.
    private func confirmAccount(using transport: any IOSSyncTransport, generation: Int) async -> AccountCheck {
        do {
            let accountStatus = try await transport.accountStatus()
            if let blocker = SyncBlocker(accountStatus: accountStatus) {
                return .failed(SyncStepFailure(failure: .blocked(blocker), error: .blocked(blocker), retryAfter: nil))
            }
            let accountId = try await transport.currentAccountId()
            guard generation == statusGeneration else { return .superseded }
            return .ready(isNewAccount: adoptAccount(accountId))
        } catch {
            Self.logger.error("Could not read the iCloud account: \(error.localizedDescription, privacy: .private)")
            return .failed(await refined(SyncStepFailure(error), using: transport))
        }
    }

    /// Whether the account differs from the one this device last synced with.
    private func adoptAccount(_ accountId: String) -> Bool {
        switch metadata.adoptAccount(accountId) {
        case .firstSeen, .unchanged:
            return false
        case .switched:
            Self.logger.notice("The iCloud account changed, so sync starts over and pending edits go to the new account")
        case .previousAccountUnknown:
            Self.logger.notice("An earlier build synced without recording its iCloud account, so sync starts over once")
        }
        recordCache.removeAll()
        lastSyncDate = metadata.lastSyncDate
        return true
    }

    private func pullThenPush(
        _ admission: SyncAdmission,
        generation: Int,
        using transport: any IOSSyncTransport
    ) async -> RunResult? {
        /// Only a run that may upload creates the zone. A download looks for it, and finding it
        /// again is how this device learns another one brought deleted data back.
        if metadata.zoneState.createsZone(in: admission) {
            do {
                try await transport.ensureZoneExists()
                metadata.zoneState = .confirmed
            } catch {
                Self.logger.error("Could not create the sync zone: \(error.localizedDescription, privacy: .private)")
                return RunResult(admission: admission, failure: await refined(SyncStepFailure(error), using: transport))
            }
        }

        let pulled: PullResult
        do {
            pulled = try await fetchChanges(using: transport)
        } catch {
            Self.logger.error("Pull failed: \(error.localizedDescription, privacy: .private)")
            guard generation == statusGeneration else { return nil }
            guard let failure = metadata.zoneState.reconciled(downloadFailure: SyncStepFailure(error)) else {
                return RunResult(admission: admission, failure: nil)
            }
            return RunResult(admission: admission, failure: await refined(failure, using: transport))
        }
        guard generation == statusGeneration else { return nil }
        metadata.zoneState = .confirmed

        let changes = PullChanges(pulled)
        let connCount = changes.changedConnections.count
        let groupCount = changes.changedGroups.count
        let tagCount = changes.changedTags.count
        let queryCount = changes.savedQueries.changedQueries.count
        let folderCount = changes.savedQueries.changedFolders.count
        Self.logger.info(
            "Pulled \(connCount) connections, \(groupCount) groups, \(tagCount) tags, \(queryCount) saved queries, \(folderCount) folders"
        )

        let applied = applyRemoteChanges(changes)
        guard applied != .notSaved else {
            return RunResult(admission: admission, failure: .pullNotSaved)
        }
        // Committed before the upload, so a failed upload does not make every later run download everything again.
        if applied == .saved, let newToken = pulled.newToken {
            metadata.saveToken(newToken)
        }
        // The connection writes landed, and a dirty connection pushed over a stale change tag would conflict.
        recordCache.store(pulled.changedRecords)
        recordCache.remove(pulled.deletedRecordIDs)
        let heldDownload: SyncStepFailure? = applied == .saved ? nil : .pullNotSaved

        guard admission == .full else { return RunResult(admission: admission, failure: heldDownload) }
        guard let pushFailure = await push(using: transport) else {
            return RunResult(admission: admission, failure: heldDownload)
        }
        let upload = await refined(pushFailure, using: transport)
        return RunResult(admission: admission, failure: SyncStepFailure.decisive(upload: upload, download: heldDownload))
    }

    private func fetchChanges(using transport: any IOSSyncTransport) async throws -> PullResult {
        // A delta never resends what an earlier build skipped, so a build that reads more types fetches everything once.
        if metadata.adoptReadableRecordTypes(Self.readableRecordTypes) {
            Self.logger.notice("This build reads record types an earlier one skipped, so it fetches everything once")
            metadata.saveToken(nil)
        }
        do {
            return try await transport.pull(since: metadata.loadToken())
        } catch let error where SyncFailure(error) == .tokenExpired {
            Self.logger.warning("Change token expired, clearing it and fetching everything")
            metadata.saveToken(nil)
            return try await transport.pull(since: nil)
        }
    }

    /// CloudKit fails an operation with `notAuthenticated` for every account state that is not
    /// available, so a fresh status read says which one it is.
    private func refined(_ failure: SyncStepFailure, using transport: any IOSSyncTransport) async -> SyncStepFailure {
        guard case .blocked(let blocker) = failure.failure, blocker.isAccountState else { return failure }
        let current = try? await transport.accountStatus()
        let actual = current.flatMap { SyncBlocker(accountStatus: $0) } ?? .accountNotReady
        return SyncStepFailure(failure: .blocked(actual), error: .blocked(actual), retryAfter: failure.retryAfter)
    }

    /// Publishes the outcome of a run, unless something decided the status while it was in flight.
    private func finish(_ result: RunResult, previousError: SyncError?, from generation: Int) {
        guard generation == statusGeneration else {
            Self.logger.info("Discarding a sync outcome the status moved on from")
            return
        }
        let settlement = SyncSettlement(failure: result.failure, admission: result.admission, previousError: previousError)
        if settlement.stampsLastSync {
            metadata.lastSyncDate = Date()
            lastSyncDate = metadata.lastSyncDate
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
            /// The next attempt comes once the throttle is over, never inside it, and also when
            /// nothing else was going to try again.
            if nextAttempt.map({ $0 < until }) ?? true {
                nextAttempt = until
                scheduleRetry(after: wait)
            }
        } else {
            throttledUntil = nil
        }
        status = settlement.status
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

    /// The path can come back while a run is still retrying, before that run reports it could not
    /// reach iCloud, and the monitor reports the return only once. So a return during a run is kept
    /// for when it ends.
    private func networkDidReturn() {
        if runningSync != nil {
            if !pendingTriggers.contains(.networkRestored) {
                pendingTriggers.append(.networkRestored)
            }
        } else if status.error == .offline {
            Task { await sync(.networkRestored) }
        }
    }

    /// Settles the status from outside a run, which retires whatever run is in flight.
    private func decide(_ outcome: SyncStatus) {
        statusGeneration += 1
        status = outcome
    }

    // MARK: - Dirty / Tombstone Tracking

    func markDirty(_ connectionId: UUID) {
        markDirty([connectionId.uuidString], type: .connection)
    }

    func markDeleted(_ connectionId: UUID) {
        addTombstone(connectionId.uuidString, type: .connection)
    }

    func markDirtyGroup(_ groupId: UUID) {
        markDirty([groupId.uuidString], type: .group)
    }

    func markDeletedGroup(_ groupId: UUID) {
        addTombstone(groupId.uuidString, type: .group)
    }

    func markDirtyTag(_ tagId: UUID) {
        markDirty([tagId.uuidString], type: .tag)
    }

    func markDeletedTag(_ tagId: UUID) {
        addTombstone(tagId.uuidString, type: .tag)
    }

    func markDirty(savedQueries queryIds: [UUID], folders folderIds: [UUID] = []) {
        markDirty(queryIds.map(\.uuidString), type: .favorite)
        markDirty(folderIds.map(\.uuidString), type: .favoriteFolder)
    }

    func markDeleted(savedQueries queryIds: [UUID], folders folderIds: [UUID] = []) {
        metadata.addTombstones(queryIds.map(\.uuidString), type: .favorite)
        metadata.addTombstones(folderIds.map(\.uuidString), type: .favoriteFolder)
    }

    private func markDirty(_ ids: [String], type: SyncRecordType) {
        for id in ids {
            editGenerations[EditKey(type: type, id: id), default: 0] += 1
        }
        metadata.markDirty(ids, type: type)
    }

    private func addTombstone(_ id: String, type: SyncRecordType) {
        metadata.addTombstone(id, type: type)
    }

    private func markAllLocalDataDirty() {
        guard let state = getCurrentState?() else { return }
        markDirty(state.connections.filter(\.participatesInSync).map(\.id.uuidString), type: .connection)
        markDirty(state.groups.map(\.id.uuidString), type: .group)
        markDirty(state.tags.map(\.id.uuidString), type: .tag)
        guard let savedQueries = getSavedQueries?() else { return }
        let syncs = Self.ownerSyncs(in: state.connections)
        markDirty(savedQueries.queries.filter { syncs($0.connectionId) }.map(\.id.uuidString), type: .favorite)
        markDirty(savedQueries.folders.filter { syncs($0.connectionId) }.map(\.id.uuidString), type: .favoriteFolder)
    }

    // A record owned by a connection that never leaves the device (the sample) stays local too.
    private static func ownersKeptOff(in connections: [DatabaseConnection]) -> Set<UUID> {
        Set(connections.filter { !$0.participatesInSync }.map(\.id))
    }

    private static func ownerSyncs(keptOff: Set<UUID>) -> (UUID?) -> Bool {
        { owner in owner.map { !keptOff.contains($0) } ?? true }
    }

    private static func ownerSyncs(in connections: [DatabaseConnection]) -> (UUID?) -> Bool {
        ownerSyncs(keptOff: ownersKeptOff(in: connections))
    }

    /// An edit made while a run is in flight queues one more run instead of cancelling it, because
    /// a cancelled request reported a failure.
    func scheduleSyncAfterChange() {
        debounceTask?.cancel()
        guard isEnabled() else {
            debounceTask = nil
            return
        }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.sync(.localChange)
        }
    }

    // MARK: - Apply

    private func applyRemoteChanges(_ remote: PullChanges) -> RemoteApply {
        guard let state = getCurrentState?() else { return .notSaved }
        let connectionsSaved = onConnectionsChanged?(mergeConnections(local: state.connections, remote: remote)) ?? true
        let groupsSaved = onGroupsChanged?(mergeGroups(local: state.groups, remote: remote)) ?? true
        let tagsSaved = onTagsChanged?(mergeTags(local: state.tags, remote: remote)) ?? true
        guard connectionsSaved, groupsSaved, tagsSaved else {
            Self.logger.error("A pulled library change was not saved, so the change token is held")
            return .notSaved
        }
        return applyRemoteSavedQueries(remote.savedQueries) ? .saved : .savedQueriesHeld
    }

    // Read after the connection callbacks ran, so a connection deleted elsewhere has already taken its records.
    private func applyRemoteSavedQueries(_ remote: SavedQueryRemoteChanges) -> Bool {
        guard !remote.isEmpty else { return true }
        guard let local = getSavedQueries?() else {
            Self.logger.error("Saved queries arrived while the stored ones are not loaded, so the change token is held")
            return false
        }
        let keptOff = Self.ownersKeptOff(in: getCurrentState?()?.connections ?? [])
        let outcome = SavedQueryRemoteMerge.merge(
            local: local,
            remote: remote,
            pending: pendingSavedQueryEdits(),
            keptLocalOwners: keptOff
        )
        if outcome.contents != local {
            guard onSavedQueriesChanged?(outcome.contents) == true else {
                Self.logger.error("Pulled saved queries were not saved, so the change token is held")
                return false
            }
        }
        // Pushed even when nothing changed here: a stale copy that lost its keyword still holds it in iCloud.
        guard !outcome.releasedKeywordIds.isEmpty else { return true }
        Self.logger.info("Keyword conflicts resolved: \(outcome.releasedKeywordIds.count, privacy: .public)")
        let syncs = Self.ownerSyncs(keptOff: keptOff)
        let released = Set(outcome.releasedKeywordIds)
        let pushed = outcome.contents.queries.filter { released.contains($0.id) && syncs($0.connectionId) }
        markDirty(pushed.map(\.id.uuidString), type: .favorite)
        return true
    }

    private func pendingSavedQueryEdits() -> SavedQueryPendingEdits {
        SavedQueryPendingEdits(
            dirtyQueryIds: metadata.dirtyIds(for: .favorite),
            dirtyFolderIds: metadata.dirtyIds(for: .favoriteFolder),
            deletedQueryIds: tombstonedIds(for: .favorite),
            deletedFolderIds: tombstonedIds(for: .favoriteFolder)
        )
    }

    private func tombstonedIds(for type: SyncRecordType) -> Set<String> {
        Set(metadata.tombstones(for: type).map(\.id))
    }

    // MARK: - Push

    /// Whatever went through is settled even when a later batch threw, so a saved record is not
    /// sent again and a cached record does not stand in with a stale change tag.
    private func push(using transport: any IOSSyncTransport) async -> SyncStepFailure? {
        let zoneID = await transport.currentZoneID
        guard let state = getCurrentState?() else { return nil }
        let generationsAtPush = editGenerations
        let batch = pushBatch(from: state, savedQueries: getSavedQueries?(), in: zoneID)
        guard !batch.records.isEmpty || !batch.deletions.isEmpty else { return nil }

        var outcome: PushOutcome
        var interruption: (any Error)?
        do {
            outcome = try await transport.push(records: batch.records, deletions: batch.deletions)
        } catch let interrupted as SyncPushInterruption {
            outcome = interrupted.completed
            interruption = interrupted.cause
        } catch {
            Self.logger.error("Push failed: \(error.localizedDescription, privacy: .private)")
            return SyncStepFailure(error)
        }
        outcome.acceptMissingDeletions(of: batch.deletions)
        settle(outcome, generationsAtPush: generationsAtPush)

        let itemFailure = SyncStepFailure(outcome)
        if let interruption {
            Self.logger.error("Push stopped part way: \(interruption.localizedDescription, privacy: .private)")
            /// A blocker an earlier batch hit explains the interruption too; anything less does not.
            return itemFailure.flatMap { $0.failure.stopsUpload ? $0 : nil } ?? SyncStepFailure(interruption)
        }
        if let itemFailure {
            let pending = outcome.failures.count
            Self.logger.error("Push left \(pending, privacy: .public) items pending: \(String(describing: itemFailure.failure), privacy: .public)")
        }
        return itemFailure
    }

    private func settle(_ outcome: PushOutcome, generationsAtPush: [EditKey: Int]) {
        recordCache.store(Array(outcome.savedRecords.values))
        recordCache.remove(Array(outcome.deletedRecordIDs))

        for recordID in outcome.savedRecords.keys {
            guard let parsed = SyncRecordMapper.parse(recordName: recordID.recordName) else { continue }
            let key = EditKey(type: parsed.type, id: parsed.id)
            guard editGenerations[key] == generationsAtPush[key] else { continue }
            editGenerations[key] = nil
            metadata.removeDirty(parsed.id, type: parsed.type)
        }

        for recordID in outcome.deletedRecordIDs {
            guard let parsed = SyncRecordMapper.parse(recordName: recordID.recordName) else { continue }
            metadata.removeTombstone(parsed.id, type: parsed.type)
        }
    }

    private func pushBatch(
        from state: LibraryState,
        savedQueries: SavedQueryContents?,
        in zoneID: CKRecordZone.ID
    ) -> (records: [CKRecord], deletions: [CKRecord.ID]) {
        var records: [CKRecord] = []
        var deletions: [CKRecord.ID] = []

        let dirtyConnIDs = metadata.dirtyIds(for: .connection)
        for connection in state.connections
            where connection.participatesInSync && dirtyConnIDs.contains(connection.id.uuidString) {
            let recordID = SyncRecordMapper.recordID(type: .connection, id: connection.id.uuidString, in: zoneID)
            if let existing = recordCache.record(for: recordID) {
                SyncRecordMapper.updateRecord(existing, with: connection)
                records.append(existing)
            } else {
                records.append(SyncRecordMapper.toRecord(connection, zoneID: zoneID))
            }
        }

        let dirtyGroupIDs = metadata.dirtyIds(for: .group)
        for group in state.groups where dirtyGroupIDs.contains(group.id.uuidString) {
            let recordID = SyncRecordMapper.recordID(type: .group, id: group.id.uuidString, in: zoneID)
            if let existing = recordCache.record(for: recordID) {
                SyncRecordMapper.updateRecord(existing, with: group)
                records.append(existing)
            } else {
                records.append(SyncRecordMapper.toRecord(group, zoneID: zoneID))
            }
        }

        let dirtyTagIDs = metadata.dirtyIds(for: .tag)
        for tag in state.tags where dirtyTagIDs.contains(tag.id.uuidString) {
            let recordID = SyncRecordMapper.recordID(type: .tag, id: tag.id.uuidString, in: zoneID)
            if let existing = recordCache.record(for: recordID) {
                SyncRecordMapper.updateRecord(existing, with: tag)
                records.append(existing)
            } else {
                records.append(SyncRecordMapper.toRecord(tag, zoneID: zoneID))
            }
        }

        var deletedTypes: [SyncRecordType] = [.connection, .group, .tag]
        if let savedQueries {
            records += savedQueryRecords(savedQueries, connections: state.connections, in: zoneID)
            deletedTypes += [.favorite, .favoriteFolder]
        }

        for type in deletedTypes {
            for tombstone in metadata.tombstones(for: type) {
                deletions.append(SyncRecordMapper.recordID(type: type, id: tombstone.id, in: zoneID))
            }
        }

        return (records, deletions)
    }

    // Built fresh, not from the cache: `.changedKeys` clears a keyword, folder or connection only when the key is named.
    private func savedQueryRecords(
        _ contents: SavedQueryContents,
        connections: [DatabaseConnection],
        in zoneID: CKRecordZone.ID
    ) -> [CKRecord] {
        let syncs = Self.ownerSyncs(in: connections)
        let dirtyFolderIds = metadata.dirtyIds(for: .favoriteFolder)
        let dirtyQueryIds = metadata.dirtyIds(for: .favorite)
        let folders = contents.folders
            .filter { dirtyFolderIds.contains($0.id.uuidString) && syncs($0.connectionId) }
            .map { SyncRecordMapper.toRecord($0, zoneID: zoneID) }
        let queries = contents.queries
            .filter { dirtyQueryIds.contains($0.id.uuidString) && syncs($0.connectionId) }
            .map { SyncRecordMapper.toRecord($0, zoneID: zoneID) }
        return folders + queries
    }

    // MARK: - Pull

    private struct PullChanges {
        var changedConnections: [DatabaseConnection] = []
        var deletedConnectionIDs: Set<UUID> = []
        var changedGroups: [ConnectionGroup] = []
        var deletedGroupIDs: Set<UUID> = []
        var changedTags: [ConnectionTag] = []
        var deletedTagIDs: Set<UUID> = []
        var savedQueries = SavedQueryRemoteChanges()

        init(_ result: PullResult) {
            for record in result.changedRecords {
                switch record.recordType {
                case SyncRecordType.connection.rawValue:
                    if let connection = SyncRecordMapper.toConnection(record) {
                        changedConnections.append(connection)
                    }
                case SyncRecordType.group.rawValue:
                    if let group = SyncRecordMapper.toGroup(record) {
                        changedGroups.append(group)
                    }
                case SyncRecordType.tag.rawValue:
                    if let tag = SyncRecordMapper.toTag(record) {
                        changedTags.append(tag)
                    }
                case SyncRecordType.favorite.rawValue:
                    if let query = SyncRecordMapper.toSavedQuery(record) {
                        savedQueries.changedQueries.append(query)
                    }
                case SyncRecordType.favoriteFolder.rawValue:
                    if let folder = SyncRecordMapper.toSavedQueryFolder(record) {
                        savedQueries.changedFolders.append(folder)
                    }
                default:
                    break
                }
            }

            for recordID in result.deletedRecordIDs {
                guard let parsed = SyncRecordType.parse(recordName: recordID.recordName),
                      let uuid = UUID(uuidString: parsed.id) else { continue }
                switch parsed.type {
                case .connection:
                    deletedConnectionIDs.insert(uuid)
                case .group:
                    deletedGroupIDs.insert(uuid)
                case .tag:
                    deletedTagIDs.insert(uuid)
                case .favorite:
                    savedQueries.deletedQueryIds.insert(uuid)
                case .favoriteFolder:
                    savedQueries.deletedFolderIds.insert(uuid)
                default:
                    break
                }
            }
        }
    }

    // MARK: - Merge

    private func mergeConnections(local: [DatabaseConnection], remote: PullChanges) -> [DatabaseConnection] {
        merge(
            local: local,
            changed: remote.changedConnections,
            deleted: remote.deletedConnectionIDs,
            dirtyIds: metadata.dirtyIds(for: .connection),
            tombstonedIds: tombstonedIds(for: .connection)
        )
    }

    private func mergeGroups(local: [ConnectionGroup], remote: PullChanges) -> [ConnectionGroup] {
        merge(
            local: local,
            changed: remote.changedGroups,
            deleted: remote.deletedGroupIDs,
            dirtyIds: metadata.dirtyIds(for: .group),
            tombstonedIds: tombstonedIds(for: .group)
        )
    }

    private func mergeTags(local: [ConnectionTag], remote: PullChanges) -> [ConnectionTag] {
        merge(
            local: local,
            changed: remote.changedTags,
            deleted: remote.deletedTagIDs,
            dirtyIds: metadata.dirtyIds(for: .tag),
            tombstonedIds: tombstonedIds(for: .tag)
        )
    }

    private func merge<Item: Identifiable & Equatable>(
        local: [Item],
        changed: [Item],
        deleted: Set<UUID>,
        dirtyIds: Set<String>,
        tombstonedIds: Set<String>
    ) -> [Item] where Item.ID == UUID {
        var result = local.filter { !deleted.contains($0.id) }
        // A record deleted here and not pushed yet stays deleted, or the pull brings it back before the push.
        for remoteItem in changed
            where !deleted.contains(remoteItem.id) && !tombstonedIds.contains(remoteItem.id.uuidString) {
            guard let index = result.firstIndex(where: { $0.id == remoteItem.id }) else {
                result.append(remoteItem)
                continue
            }
            guard !dirtyIds.contains(remoteItem.id.uuidString), result[index] != remoteItem else { continue }
            result[index] = remoteItem
        }
        return result
    }
}
