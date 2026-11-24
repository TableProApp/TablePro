import Combine
import Foundation
import os
import TableProCloudAPI

internal enum TeamLibrarySyncOutcome: Equatable, Sendable {
    case skipped
    case synced
    case failed(TeamLibraryFailure)
}

internal enum TeamLibraryPublishResult: Equatable, Sendable {
    case unchanged
    case published(Int)
    case conflicts(Int)
    // Kept on this Mac and pushed once the team library answers again.
    case queued(TeamLibraryFailure)
}

internal enum TeamLibraryPublishError: Error, Equatable {
    case notWritable
    case failed(TeamLibraryFailure)
}

// A team as the person picked it, in the sign-in shown then: the publish goes out only if that sign-in is still the one.
internal struct TeamLibraryDestination: Sendable {
    let teamID: String
    fileprivate let sessionID: String?
}

// Pulls each team's library from its cached cursor on launch, every 15 minutes and after each push, and pushes what
// this Mac publishes in batches. Who reads and who writes comes from GET /v2/me: a seat to read, owner or admin to write.
//
// One sign-in's library:
// I1. Unsent edits, the pushes still to go and the conflicts not resolved, live only in `teams`, for the open session.
//     Nothing about them is written to disk.
// I2. The read cache sits in a folder named from the server and account (TeamLibraryStorage). Only the open session's
//     folder is read; every other one is deleted, best-effort, on sign-out, switch and launch.
// I3. The library 0.88 and earlier kept goes only to the tablepro.app sign-in the core restored at launch: its cache is
//     copied into that account's folder and its edits pushed with that session's bearer. Its files go once a push
//     succeeds, or with the session; a failed push keeps them for the next launch. A sign-in made in this run or on a
//     company server deletes them unread.
// I4. A switch or sign-out stays in this process. Sync stops and the pass in flight ends, unsent edits are listed with
//     push, discard or cancel (an involuntary sign-out can only discard and says what went), then the session's
//     store goes. The session id lives only in the core's process and a bearer of another session is refused; a
//     publish is bound to the session shown at its confirmation and checked again before it is sent.
// I5. Quitting with unsent edits asks push, discard or cancel; while edits wait, Team Library shows them not uploaded.
// I6. Losing team_library drops the session's store and deletes its folder, best-effort.
// I7. Until the restore settles, a sign-in, a server choice or a license key waits; a restored sign-in refuses them.
@MainActor
internal final class TeamLibrarySync: ObservableObject {
    static let shared = TeamLibrarySync(account: .shared, storage: .live())

    static let pullInterval: Duration = .seconds(15 * 60)
    static let firstRetryDelay: Duration = .seconds(30)
    static let maxBatchCount = 500
    // Under the 4 MiB request limit, with room for the envelope.
    static let maxBatchBytes = 3_800_000
    static let maxItemBytes = 256 * 1_024

    private static let logger = Logger(subsystem: "com.TablePro", category: "TeamLibrarySync")

    @Published private(set) var content: TeamLibraryContent = .empty
    @Published private(set) var status: TeamLibrarySyncStatus = .idle
    @Published private(set) var conflicts: [TeamLibraryConflict] = []
    @Published private(set) var writableTeams: [TeamLibraryTeam] = []
    // Edits waiting for a push, shown as not uploaded.
    @Published private(set) var notUploadedCount = 0

    private let account: AccountServices
    private let storage: TeamLibraryStorage
    private var active: ActiveSession?
    // Set once the core has restored the last run's sign-in, with the session it restored, if any.
    private var restoreSettled = false
    private var restoredSessionID: String?
    // Once a session closed, the next one opens behind the pass that may still be out.
    private var hasStopped = false
    // Set while a sign-out or a quit asks: no pass, publish or resolve runs, so the unsent edits it listed stay the last.
    private(set) var isHeld = false
    private var resumesAfterHold = false
    private let reportDiscarded: @MainActor ([String]) -> Void
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    private var teams: [String: TeamLibraryTeamState] = [:]
    // The /v1 cache, shown until every team this account reads has a first /v2 snapshot.
    private var legacy: TeamLibraryLegacyLibrary?
    // GET /v2/me's address, the one the /v1 cache names publishers by.
    private var accountEmail: String?
    private var tail: Task<Void, Never>?
    private var queuedSync: Task<TeamLibrarySyncOutcome, Never>?
    private var scheduleTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var accessCancellable: AnyCancellable?
    // Failures in a row that the network or the server may recover from; each one doubles the wait for the next sync.
    private var retries = 0
    private var hasLoaded = false
    private var wakeRequested = false
    // A failed publish shortened the wait the schedule is in.
    private var rescheduled = false
    // Set by a 429's Retry-After: no pull or push goes out until it ends.
    private var rateLimitHold: Task<Void, Never>?
    // Bumped when a session closes, so a sync still out at that moment brings no team back.
    private var generation = 0

    private struct SessionKey: Equatable {
        let sessionID: String
        let server: AccountServer
        let accountID: String

        init?(_ state: AccountState) {
            guard state.isSignedIn, let sessionID = state.sessionID, let accountID = state.entitlement?.accountID else {
                return nil
            }
            self.sessionID = sessionID
            self.server = state.server
            self.accountID = accountID
        }
    }

    // The open session: its folder, and a client that calls only its server under its bearer.
    private struct ActiveSession {
        let key: SessionKey
        let cache: TeamLibraryStateStore
        let client: TeamLibraryClient
        // Holds the edits of the library 0.88 kept, whose files stay until a push of them succeeds.
        var usesFlat: Bool
    }

    init(
        account: AccountServices,
        storage: TeamLibraryStorage,
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Date = { Date() },
        reportDiscarded: @escaping @MainActor ([String]) -> Void = TeamLibraryUnsentChanges.presentDiscarded
    ) {
        self.account = account
        self.storage = storage
        self.clock = clock
        self.now = now
        self.reportDiscarded = reportDiscarded
    }

    var canPublish: Bool {
        !writableTeams.isEmpty
    }

    // Edits not pushed yet and conflicts not resolved, which live only in memory.
    var hasUnsentChanges: Bool {
        !unsentChanges.isEmpty
    }

    // Their names, as a sign-out or a quit lists them.
    var unsentChanges: [String] {
        teams.values.sorted { $0.teamName < $1.teamName }.flatMap { state in
            (state.pending + state.conflicts.map(\.edit)).map { Self.name(of: $0, in: state) }
        }
    }

    func start() {
        guard scheduleTask == nil else { return }
        loadIfNeeded()
        observeAccount()
        scheduleTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.record(await self.sync())
                // Stopped while the pass ran: a sleep started now would outlive the stop.
                guard !Task.isCancelled else { return }
                await self.pause()
            }
        }
    }

    func stop() {
        stopSchedule()
        accessCancellable = nil
    }

    private func stopSchedule() {
        scheduleTask?.cancel()
        scheduleTask = nil
        sleepTask?.cancel()
    }

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        follow(account.access.state)
    }

    // Stops the schedule and waits for the pass or publish still out, so what it returns stays final while held.
    func hold() async -> [String] {
        if !isHeld {
            isHeld = true
            resumesAfterHold = scheduleTask != nil
            stopSchedule()
        }
        await tail?.value
        return unsentChanges
    }

    // The sign-out or the quit was canceled.
    func release() {
        guard isHeld else { return }
        isHeld = false
        if resumesAfterHold {
            start()
        }
    }

    // Push now: one pass while held. What is still not uploaded comes back, with why.
    func pushHeld() async -> (unsent: [String], failure: TeamLibraryFailure?) {
        guard isHeld else { return (unsentChanges, nil) }
        let outcome = await serially { [weak self] () -> TeamLibrarySyncOutcome in
            await self?.performSync(whileHeld: true) ?? .skipped
        }.value
        if case .failed(let failure) = outcome {
            return (unsentChanges, failure)
        }
        return (unsentChanges, nil)
    }

    // Discard: the unsent edits go, and the library 0.88 kept with them.
    func discardHeld() {
        guard isHeld else { return }
        for var state in teams.values where !state.pending.isEmpty || !state.conflicts.isEmpty {
            state.pending = []
            state.conflicts = []
            commit(state)
        }
        if active?.usesFlat == true {
            storage.removeFlat()
            active?.usesFlat = false
        }
        publishContent()
    }

    // Ends the wait for the next scheduled pull, or skips it when the request lands during a sync.
    func syncSoon() {
        wakeRequested = true
        sleepTask?.cancel()
    }

    @discardableResult
    func sync() async -> TeamLibrarySyncOutcome {
        if let queuedSync {
            return await queuedSync.value
        }
        let task = serially { [weak self] () -> TeamLibrarySyncOutcome in
            guard let self else { return .skipped }
            self.queuedSync = nil
            return await self.performSync()
        }
        queuedSync = task
        return await task.value
    }

    // Taken when the person picks the team, before any confirmation waits.
    func destination(_ teamID: String) -> TeamLibraryDestination {
        TeamLibraryDestination(teamID: teamID, sessionID: active?.key.sessionID)
    }

    func publishConnections(
        _ connections: [TeamLibraryPublishPlan.Connection],
        to teamID: String
    ) async throws(TeamLibraryPublishError) -> TeamLibraryPublishResult {
        try await publishConnections(connections, to: destination(teamID))
    }

    func publishConnections(
        _ connections: [TeamLibraryPublishPlan.Connection],
        to destination: TeamLibraryDestination
    ) async throws(TeamLibraryPublishError) -> TeamLibraryPublishResult {
        try await publish(to: destination, owns: { _ in true }) { try TeamLibraryPublishPlan.connections(connections, in: $0) }
    }

    func publishSavedQueries(
        favorites: [SQLFavorite],
        folders: [SQLFavoriteFolder],
        to teamID: String
    ) async throws(TeamLibraryPublishError) -> TeamLibraryPublishResult {
        try await publishSavedQueries(favorites: favorites, folders: folders, to: destination(teamID))
    }

    func publishSavedQueries(
        favorites: [SQLFavorite],
        folders: [SQLFavoriteFolder],
        to destination: TeamLibraryDestination
    ) async throws(TeamLibraryPublishError) -> TeamLibraryPublishResult {
        let local = TeamLibraryPublishPlan.keys(favorites: favorites, folders: folders)
        return try await publish(to: destination, owns: { local.contains($0) }) {
            try TeamLibraryPublishPlan.savedQueries(favorites: favorites, folders: folders, in: $0)
        }
    }

    func resolve(_ conflict: TeamLibraryConflict, keepingMine: Bool) async {
        // Only a conflict of the open session: one a sheet kept from the last session is no one's to push.
        guard !isHeld, var state = teams[conflict.teamID], state.conflicts.contains(where: { $0.id == conflict.id }) else {
            return
        }
        let key = conflict.key
        let stored = state.items[key]
        state.conflicts.removeAll { $0.id == conflict.id }
        var pushes = false
        if keepingMine {
            state.declined[key] = nil
            var edit = conflict.edit
            edit.baseVersion = stored.map(\.version)
            edit.clientId = stored?.clientId ?? edit.clientId
            if state.canWrite, edit.op == .upsert || stored?.deleted == false {
                state.pending.append(edit)
                if conflict.isMove {
                    state.moves.insert(key)
                }
                pushes = true
            }
        } else if conflict.edit.op == .delete {
            // The team keeps what this Mac removed, so it is no longer this Mac's to remove.
            state.published.remove(key)
        } else if let data = conflict.edit.data?.additionalProperties {
            state.declined[key] = data
        }
        commit(state)
        publishContent()
        if pushes {
            await sync()
        }
    }

    func current(for conflict: TeamLibraryConflict) -> TeamLibraryChange? {
        teams[conflict.teamID]?.items[conflict.key] ?? conflict.current
    }

    func teamName(of teamID: String) -> String? {
        teams[teamID]?.teamName
    }

    // The entitlement no longer includes the team library: this Mac's copy goes, unsent edits included.
    func clear() {
        generation += 1
        rateLimitHold?.cancel()
        rateLimitHold = nil
        teams = [:]
        legacy = nil
        accountEmail = nil
        if let active {
            storage.removeFolders(except: nil)
            if active.usesFlat {
                storage.removeFlat()
                self.active?.usesFlat = false
            }
        }
        status = .idle
        publishContent()
    }

    private func performSync(whileHeld: Bool = false) async -> TeamLibrarySyncOutcome {
        guard !isHeld || whileHeld else { return .skipped }
        follow(account.access.state, inPass: true)
        guard account.isSignedIn, let client = active?.client else { return .skipped }
        guard account.access.isAvailable(.teamLibrary) else {
            // A current entitlement without team_library: the seat or the plan is gone, and with it what this Mac read.
            if account.access.currentEntitlement != nil, !teams.isEmpty || legacy != nil {
                Self.logger.notice("The entitlement no longer includes the team library; dropping this Mac's copy")
                clear()
            }
            return .skipped
        }
        guard rateLimitHold == nil else { return .failed(.rateLimited(retryAfter: nil)) }
        status = .syncing
        let started = generation
        let profile: AccountProfile
        do throws(TeamLibraryFailure) {
            profile = try await client.profile()
        } catch {
            guard started == generation else { return .skipped }
            holdIfRateLimited(error)
            return finish(.failed(error))
        }
        guard started == generation else { return .skipped }
        accountEmail = profile.email
        adopt(profile.memberships)

        var failure: TeamLibraryFailure?
        for teamID in teams.keys.sorted() where started == generation {
            do throws(TeamLibraryFailure) {
                try await syncTeam(teamID)
            } catch {
                Self.logger.warning("Team library sync failed: \(error.logName, privacy: .public)")
                holdIfRateLimited(error)
                if error != .unreadable {
                    failure = failure ?? error
                }
                if error.isRetryable { break }
            }
        }
        // Signed out while a pull or a push was out: clear() already dropped everything it would bring back.
        guard started == generation else { return .skipped }
        if legacy != nil, teams.values.allSatisfy({ $0.cursor != nil }) {
            legacy = nil
            active?.cache.removeLegacy()
        }
        if failure == nil, active?.usesFlat == true {
            storage.removeFlat()
            active?.usesFlat = false
        }
        publishContent()
        return finish(failure.map { .failed($0) } ?? .synced)
    }

    private func finish(_ outcome: TeamLibrarySyncOutcome) -> TeamLibrarySyncOutcome {
        switch outcome {
        case .skipped:
            break
        case .synced:
            status = .synced(now())
        case .failed(let failure):
            status = .failed(failure)
        }
        return outcome
    }

    // A seat reads, an owner or admin with a seat writes; a team no longer listed is dropped with its edits.
    private func adopt(_ memberships: [AccountMembership]) {
        let seated = memberships.filter(\.hasSeat)
        let listed = Set(seated.map(\.teamID))
        for teamID in teams.keys where !listed.contains(teamID) {
            teams[teamID] = nil
            active?.cache.remove(teamID: teamID)
        }
        for membership in seated {
            var state = teams[membership.teamID]
                ?? TeamLibraryTeamState(teamID: membership.teamID, teamName: membership.teamName, canWrite: false)
            state.teamName = membership.teamName
            state.canWrite = membership.role == "owner" || membership.role == "admin"
            if !state.canWrite, !state.pending.isEmpty || !state.conflicts.isEmpty {
                Self.logger.notice(
                    "Dropping \(state.pending.count) unpushed team library edits and \(state.conflicts.count) conflicts: this account only reads the team's library"
                )
                state.pending = []
                state.conflicts = []
            }
            commit(state)
        }
    }

    private func syncTeam(_ teamID: String) async throws(TeamLibraryFailure) {
        var pulled = false
        if teams[teamID]?.cursor == nil {
            try await pull(teamID)
            pulled = true
        }
        if let state = teams[teamID], state.canWrite, !state.pending.isEmpty {
            do throws(TeamLibraryFailure) {
                try await push(teamID)
            } catch .licenseExpired {
                // Past its license's grace the server still answers pulls; the edits wait for a renewed license.
                try await pull(teamID)
                throw .licenseExpired
            }
            try await pull(teamID)
        } else if !pulled {
            try await pull(teamID)
        }
    }

    private func pull(_ teamID: String) async throws(TeamLibraryFailure) {
        guard let client = active?.client, let start = teams[teamID] else { return }
        var cursor = start.cursor
        // Without a cursor the answer is a snapshot, which replaces what this Mac holds once its last page is in.
        var snapshot: [TeamLibraryKey: TeamLibraryChange]? = cursor == nil ? [:] : nil
        while true {
            let page: TeamLibraryPage
            do throws(TeamLibraryFailure) {
                page = try await client.pull(teamID: teamID, cursor: cursor)
            } catch .cursorRefused where cursor != nil {
                Self.logger.notice("The server refused the team library cursor; pulling a snapshot")
                cursor = nil
                snapshot = [:]
                continue
            } catch .unreadable {
                teams[teamID] = nil
                active?.cache.remove(teamID: teamID)
                throw .unreadable
            }
            guard var state = teams[teamID] else { return }
            if snapshot != nil {
                for change in page.changes {
                    snapshot?[change.key] = change
                }
            } else {
                for change in page.changes {
                    state.items[change.key] = change
                }
                state.cursor = page.cursor
                commit(state)
            }
            cursor = page.cursor
            guard page.hasMore else { break }
        }
        guard var state = teams[teamID] else { return }
        if let snapshot {
            state.items = snapshot
            state.cursor = cursor
            if let legacy, let accountEmail {
                // The first snapshot after the update: what this account published over /v1 is this Mac's to remove.
                state.published.formUnion(legacy.published(by: accountEmail, in: snapshot))
            }
        }
        state.syncedAt = now()
        commit(state)
    }

    private func push(_ teamID: String) async throws(TeamLibraryFailure) {
        guard let client = active?.client else { return }
        dropOversizedEdits(teamID)
        var refusal: TeamLibraryFailure?
        while let state = teams[teamID], state.canWrite, !state.pending.isEmpty {
            let batch = Self.batch(state.pending)
            let answer: TeamLibraryPushAnswer
            do throws(TeamLibraryFailure) {
                answer = try await client.push(teamID: teamID, edits: batch)
            } catch .writeForbidden {
                if var current = teams[teamID] {
                    current.canWrite = false
                    current.pending = []
                    current.conflicts = []
                    commit(current)
                }
                throw .writeForbidden
            } catch .refused(_) {
                Self.logger.error("The team library refused a push of \(batch.count) changes without naming one")
                if var current = teams[teamID] {
                    current.pending.removeFirst(min(batch.count, current.pending.count))
                    commit(current)
                }
                throw .refused(nil)
            } catch .unreadable {
                teams[teamID] = nil
                active?.cache.remove(teamID: teamID)
                throw .unreadable
            }
            guard var current = teams[teamID] else { return }
            switch answer {
            case .refusedChange(let index):
                // Nothing in the batch was applied: only the change the server named is dropped, the rest goes again.
                Self.logger.error("The team library refused change \(index) of a push of \(batch.count)")
                if batch.indices.contains(index), current.pending.indices.contains(index),
                   TeamLibraryKey(current.pending[index]) == TeamLibraryKey(batch[index]) {
                    let edit = current.pending.remove(at: index)
                    refusal = refusal ?? .refused(Self.name(of: edit, in: current))
                } else {
                    current.pending.removeFirst(min(batch.count, current.pending.count))
                    refusal = refusal ?? .refused(nil)
                }
                commit(current)
            case .results(let results):
                current.pending.removeFirst(min(batch.count, current.pending.count))
                for (edit, result) in zip(batch, results) {
                    apply(result, of: edit, to: &current)
                }
                commit(current)
            }
        }
        if let refusal {
            throw refusal
        }
    }

    private static func name(of edit: TeamLibraryEdit, in state: TeamLibraryTeamState) -> String {
        let kind = edit.kind.rawValue
        return TeamLibraryPayload.name(kind: kind, data: edit.data?.additionalProperties)
            ?? TeamLibraryPayload.name(kind: kind, data: state.items[TeamLibraryKey(edit)]?.dataValues)
            ?? edit.clientId
    }

    private func apply(_ result: Components.Schemas.LibraryResult, of edit: TeamLibraryEdit, to state: inout TeamLibraryTeamState) {
        let key = TeamLibraryKey(edit)
        // Moving someone else's item out of a deleted folder never makes it this Mac's to remove later.
        let isMove = state.moves.contains(key)
        switch result.status {
        case "applied":
            state.conflicts.removeAll { $0.key == key }
            state.items[key] = TeamLibraryChange(
                clientId: edit.clientId,
                data: edit.op == .delete ? nil : .init(additionalProperties: edit.data?.additionalProperties ?? [:]),
                deleted: edit.op == .delete,
                kind: edit.kind.rawValue,
                updatedAt: now(),
                version: result.version
            )
            state.declined[key] = nil
            if edit.op == .delete {
                state.published.remove(key)
            } else if !isMove {
                state.published.insert(key)
            }
        case "conflict":
            state.items[key] = result.current
            state.conflicts.removeAll { $0.key == key }
            if Self.holds(result.current, as: edit) {
                if edit.op == .upsert, !isMove {
                    state.published.insert(key)
                }
            } else {
                state.conflicts.append(TeamLibraryConflict(
                    teamID: state.teamID, edit: edit, current: result.current, isMove: isMove
                ))
            }
        default:
            Self.logger.warning("Unknown team library result status \(result.status, privacy: .public)")
        }
    }

    // A conflict over an item the team already holds as this Mac sent it is no conflict.
    static func holds(_ current: TeamLibraryChange?, as edit: TeamLibraryEdit) -> Bool {
        guard let current, !current.deleted else { return edit.op == .delete }
        guard edit.op == .upsert else { return false }
        let mine = edit.data?.additionalProperties
        switch edit.kind {
        case .folder:
            guard let theirs = current.folder,
                  let sent = TeamLibraryPayload.decode(TeamLibraryFolderData.self, from: mine) else { return false }
            return theirs.matches(sent)
        case .query:
            guard let theirs = current.query,
                  let sent = TeamLibraryPayload.decode(TeamLibraryQueryData.self, from: mine) else { return false }
            return theirs.matches(sent)
        case .connection:
            return current.dataValues == mine
        }
    }

    static func batch(_ edits: [TeamLibraryEdit]) -> [TeamLibraryEdit] {
        let encoder = JSONEncoder()
        var batch: [TeamLibraryEdit] = []
        var bytes = 0
        for edit in edits {
            let size = ((try? encoder.encode(edit))?.count ?? maxItemBytes) + 1
            guard batch.count < maxBatchCount, batch.isEmpty || bytes + size <= maxBatchBytes else { break }
            batch.append(edit)
            bytes += size
        }
        return batch
    }

    // The server refuses a whole push over one item past 256 KiB, so that item stays here.
    private func dropOversizedEdits(_ teamID: String) {
        guard var state = teams[teamID] else { return }
        let kept = state.pending.filter { edit in
            guard let data = edit.data?.additionalProperties else { return true }
            return TeamLibraryPayload.byteCount(of: data) <= Self.maxItemBytes
        }
        guard kept.count != state.pending.count else { return }
        Self.logger.error("Not publishing \(state.pending.count - kept.count) team library items larger than 256 KiB")
        state.pending = kept
        commit(state)
    }

    // `owns` tells this Mac's own items from someone else's that a publish only moves.
    private func publish(
        to destination: TeamLibraryDestination,
        owns: @escaping (TeamLibraryKey) -> Bool,
        plan: @escaping (TeamLibraryTeamState) throws -> [TeamLibraryEdit]
    ) async throws(TeamLibraryPublishError) -> TeamLibraryPublishResult {
        let result = await serially { [weak self] () -> Result<TeamLibraryPublishResult, TeamLibraryPublishError> in
            guard let self, !self.isHeld, let sessionID = destination.sessionID, self.active?.key.sessionID == sessionID,
                  self.account.access.state.sessionID == sessionID
            else { return .failure(.failed(.signedOut)) }
            return await self.performPublish(to: destination.teamID, owns: owns, plan: plan)
        }.value
        return try result.get()
    }

    private func performPublish(
        to teamID: String,
        owns: (TeamLibraryKey) -> Bool,
        plan: (TeamLibraryTeamState) throws -> [TeamLibraryEdit]
    ) async -> Result<TeamLibraryPublishResult, TeamLibraryPublishError> {
        let started = generation
        let outcome = await performSync()
        guard started == generation else { return .failure(.failed(.signedOut)) }
        guard let state = teams[teamID], state.canWrite else {
            if case .failed(let failure) = outcome, teams[teamID] == nil {
                return .failure(.failed(failure))
            }
            return .failure(.notWritable)
        }
        // Base versions come from a pull: an edit sent without one would conflict with the item it updates.
        guard state.cursor != nil else {
            if case .failed(let failure) = outcome {
                return .failure(.failed(failure))
            }
            return .failure(.failed(.offline))
        }
        let edits: [TeamLibraryEdit]
        do {
            edits = try plan(state)
        } catch {
            Self.logger.error("Could not encode the items to publish: \(error.publicLogShape, privacy: .public)")
            return .failure(.failed(.refused(nil)))
        }
        guard !edits.isEmpty else { return .success(.unchanged) }

        var queued = state
        queued.pending += edits
        queued.moves.formUnion(edits.compactMap { $0.op == .upsert && !owns(TeamLibraryKey($0)) ? TeamLibraryKey($0) : nil })
        commit(queued)
        // The schedule pushes them once the hold ends.
        guard rateLimitHold == nil else { return .success(.queued(.rateLimited(retryAfter: nil))) }
        do throws(TeamLibraryFailure) {
            try await push(teamID)
            try await pull(teamID)
        } catch {
            guard started == generation else { return .failure(.failed(.signedOut)) }
            holdIfRateLimited(error)
            publishContent()
            _ = finish(.failed(error))
            guard error.isRetryable else { return .failure(.failed(error)) }
            retryLater()
            return .success(.queued(error))
        }
        guard started == generation else { return .failure(.failed(.signedOut)) }
        publishContent()
        _ = finish(.synced)
        let keys = Set(edits.map { TeamLibraryKey($0) })
        let conflicted = teams[teamID]?.conflicts.filter { keys.contains($0.key) }.count ?? 0
        return .success(conflicted > 0 ? .conflicts(conflicted) : .published(edits.count))
    }

    private func serially<Value: Sendable>(_ work: @escaping @MainActor () async -> Value) -> Task<Value, Never> {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return await work()
        }
        tail = Task { _ = await task.value }
        return task
    }

    private func commit(_ state: TeamLibraryTeamState) {
        var state = state
        // A move stays marked only while its edit waits to be pushed.
        if !state.moves.isEmpty {
            state.moves.formIntersection(state.pending.map { TeamLibraryKey($0) })
        }
        teams[state.teamID] = state
        active?.cache.save(state)
    }

    private func publishContent() {
        var items = legacy?.changes ?? []
        for state in teams.values.sorted(by: { $0.teamName < $1.teamName }) {
            items += state.liveItems
        }
        let next = TeamLibraryContent(items: items)
        if next != content {
            content = next
            AppEvents.shared.teamLibraryDidUpdate.send()
        }
        let nextConflicts = teams.values.sorted(by: { $0.teamID < $1.teamID }).flatMap(\.conflicts)
        if nextConflicts != conflicts {
            conflicts = nextConflicts
        }
        let pendingCount = teams.values.reduce(0) { $0 + $1.pending.count }
        if pendingCount != notUploadedCount {
            notUploadedCount = pendingCount
        }
        let writable = teams.values.filter(\.canWrite)
            .map { TeamLibraryTeam(id: $0.teamID, name: $0.teamName) }
            .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        if writable != writableTeams {
            writableTeams = writable
        }
    }

    private func record(_ outcome: TeamLibrarySyncOutcome) {
        if case .failed(let failure) = outcome, failure.isRetryable {
            retries += 1
        } else {
            retries = 0
        }
    }

    // 30 seconds after the first failure, doubling up to the 15-minute schedule.
    private var nextDelay: Duration {
        guard retries > 0 else { return Self.pullInterval }
        return min(Self.firstRetryDelay * (1 << min(retries - 1, 5)), Self.pullInterval)
    }

    private func holdIfRateLimited(_ failure: TeamLibraryFailure) {
        guard case .rateLimited(let retryAfter?) = failure else { return }
        rateLimitHold?.cancel()
        rateLimitHold = Task { [weak self, clock] in
            _ = try? await clock.sleep(for: retryAfter)
            guard !Task.isCancelled else { return }
            self?.rateLimitHold = nil
        }
    }

    // A publish the network or the server failed: its queued edits go out after the backoff, not the next pull.
    private func retryLater() {
        retries += 1
        rescheduled = true
        sleepTask?.cancel()
    }

    private func pause() async {
        rescheduled = false
        while !wakeRequested {
            let delay = nextDelay
            let task = Task { [clock] in
                _ = try? await clock.sleep(for: delay)
            }
            sleepTask = task
            await task.value
            if sleepTask == task {
                sleepTask = nil
            }
            guard rescheduled else { break }
            rescheduled = false
        }
        // Neither a wake nor a backoff shorter than a 429's Retry-After cuts it short.
        await rateLimitHold?.value
        wakeRequested = false
    }

    // Signing out, signing in or a new entitlement syncs at once.
    private func observeAccount() {
        accessCancellable = account.access.$state
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                self.follow(state)
                self.syncSoon()
            }
    }

    // Opens and closes the session with the sign-in. `state` is the one being published: the subscription sees it
    // before `access.state` holds it. `inPass` is a pass's own call, which no other pass can be out beside.
    private func follow(_ state: AccountState, inPass: Bool = false) {
        guard state.isRestored else { return }
        let next = SessionKey(state)
        if !restoreSettled {
            restoreSettled = true
            restoredSessionID = state.isSignedIn ? state.sessionID : nil
            // Only tablepro.app's sign-in of 0.88 can be restored, and a company server's core never restores it.
            if !state.server.isProduction {
                storage.removeFlat()
            }
            if next == nil {
                storage.removeFolders(except: nil)
            }
        }
        guard next != active?.key else { return }
        guard inPass || active == nil && !hasStopped else {
            // Behind the pass in flight, with the sign-in as it is by then.
            _ = serially { [weak self] in
                guard let self else { return }
                self.open(SessionKey(self.account.access.state))
            }
            return
        }
        open(next)
    }

    private func open(_ next: SessionKey?) {
        guard next != active?.key else { return }
        close()
        guard let next else { return }
        let folder = storage.folder(server: next.server.apiOrigin, accountID: next.accountID)
        let cache = storage.cache(in: folder)
        storage.removeFolders(except: folder)
        var loaded = cache.loadAll().map(\.cached)
        var usesFlat = false
        if next.sessionID == restoredSessionID, next.server.isProduction, storage.hasFlat {
            loaded = storage.adoptFlat(into: cache)
            usesFlat = loaded.contains { !$0.pending.isEmpty || !$0.conflicts.isEmpty }
            if !usesFlat {
                storage.removeFlat()
            }
        } else {
            storage.removeFlat()
        }
        active = ActiveSession(
            key: next,
            cache: cache,
            client: TeamLibraryClient(api: account.api(pinnedTo: next.server, session: next.sessionID)),
            usesFlat: usesFlat
        )
        teams = Dictionary(loaded.map { ($0.teamID, $0) }, uniquingKeysWith: { first, _ in first })
        legacy = cache.loadLegacy(now: now())
        publishContent()
    }

    // Drops the session's store and every folder; unsent edits still here at this point had no one to ask.
    private func close() {
        guard let closing = active else { return }
        let dropped = unsentChanges
        active = nil
        hasStopped = true
        generation += 1
        rateLimitHold?.cancel()
        rateLimitHold = nil
        teams = [:]
        legacy = nil
        accountEmail = nil
        status = .idle
        storage.removeFolders(except: nil)
        if closing.usesFlat {
            storage.removeFlat()
        }
        publishContent()
        if !dropped.isEmpty {
            Self.logger.notice("Discarding \(dropped.count) team library changes the sign-out left unsent")
            reportDiscarded(dropped)
        }
        if isHeld {
            release()
        }
    }
}
