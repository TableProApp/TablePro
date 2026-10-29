//
//  TeamLibrarySync.swift
//  TablePro
//

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

// Pulls each team's library from its persisted cursor on launch, every 15 minutes and after each push, and pushes
// what this Mac publishes in batches. Who reads and who writes comes from GET /v2/me: a seat to read, owner or admin
// to write.
@MainActor
internal final class TeamLibrarySync: ObservableObject {
    static let shared = TeamLibrarySync(account: .shared, store: .live())

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

    private let account: AccountServices
    private let client: TeamLibraryClient
    private let store: TeamLibraryStateStore
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
    // Bumped by sign-out, so a sync still out at that moment brings no team back.
    private var generation = 0

    init(
        account: AccountServices,
        store: TeamLibraryStateStore,
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.account = account
        self.client = TeamLibraryClient(api: account.api)
        self.store = store
        self.clock = clock
        self.now = now
    }

    var canPublish: Bool {
        !writableTeams.isEmpty
    }

    func start() {
        guard scheduleTask == nil else { return }
        loadIfNeeded()
        observeAccount()
        scheduleTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.record(await self.sync())
                await self.pause()
            }
        }
    }

    func stop() {
        scheduleTask?.cancel()
        scheduleTask = nil
        sleepTask?.cancel()
        accessCancellable = nil
    }

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        teams = Dictionary(store.loadAll().map { ($0.teamID, $0) }, uniquingKeysWith: { first, _ in first })
        legacy = store.loadLegacy(now: now())
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

    func publishConnections(
        _ connections: [TeamLibraryPublishPlan.Connection],
        to teamID: String
    ) async throws(TeamLibraryPublishError) -> TeamLibraryPublishResult {
        try await publish(to: teamID, owns: { _ in true }) { try TeamLibraryPublishPlan.connections(connections, in: $0) }
    }

    func publishSavedQueries(
        favorites: [SQLFavorite],
        folders: [SQLFavoriteFolder],
        to teamID: String
    ) async throws(TeamLibraryPublishError) -> TeamLibraryPublishResult {
        let local = TeamLibraryPublishPlan.keys(favorites: favorites, folders: folders)
        return try await publish(to: teamID, owns: { local.contains($0) }) {
            try TeamLibraryPublishPlan.savedQueries(favorites: favorites, folders: folders, in: $0)
        }
    }

    func resolve(_ conflict: TeamLibraryConflict, keepingMine: Bool) async {
        guard var state = teams[conflict.teamID] else { return }
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

    // Sign-out: the next account may belong to other teams.
    func clear() {
        generation += 1
        teams = [:]
        legacy = nil
        accountEmail = nil
        store.removeAll()
        status = .idle
        publishContent()
    }

    // MARK: - Sync

    private func performSync() async -> TeamLibrarySyncOutcome {
        guard account.session.isSignedIn else { return .skipped }
        guard account.access.isAvailable(.teamLibrary) else {
            // A current entitlement without team_library: the seat or the plan is gone, and with it what this Mac read.
            if account.access.currentEntitlement != nil, !teams.isEmpty || legacy != nil {
                Self.logger.notice("The entitlement no longer includes the team library; dropping this Mac's copy")
                clear()
            }
            return .skipped
        }
        status = .syncing
        let started = generation
        let profile: AccountProfile
        do throws(AccountError) {
            profile = try await account.fetchProfile()
        } catch {
            guard started == generation else { return .skipped }
            return finish(.failed(TeamLibraryFailure.from(error)))
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
            store.removeLegacy()
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
            store.remove(teamID: teamID)
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
            try await push(teamID)
            try await pull(teamID)
        } else if !pulled {
            try await pull(teamID)
        }
    }

    private func pull(_ teamID: String) async throws(TeamLibraryFailure) {
        guard let start = teams[teamID] else { return }
        var cursor = start.cursor
        // Without a cursor the answer is a snapshot, which replaces what this Mac holds once its last page is in.
        var snapshot: [TeamLibraryKey: TeamLibraryChange]? = cursor == nil ? [:] : nil
        while true {
            let page: TeamLibraryPage
            do throws(TeamLibraryFailure) {
                page = try await client.pull(teamID: teamID, cursor: cursor)
            } catch .cursorExpired where cursor != nil {
                Self.logger.notice("The team library cursor expired; pulling a snapshot")
                cursor = nil
                snapshot = [:]
                continue
            } catch .unreadable {
                teams[teamID] = nil
                store.remove(teamID: teamID)
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
                store.remove(teamID: teamID)
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

    // MARK: - Publish

    // `owns` tells this Mac's own items from someone else's that a publish only moves.
    private func publish(
        to teamID: String,
        owns: @escaping (TeamLibraryKey) -> Bool,
        plan: @escaping (TeamLibraryTeamState) throws -> [TeamLibraryEdit]
    ) async throws(TeamLibraryPublishError) -> TeamLibraryPublishResult {
        let result = await serially { [weak self] () -> Result<TeamLibraryPublishResult, TeamLibraryPublishError> in
            guard let self else { return .failure(.failed(.signedOut)) }
            return await self.performPublish(to: teamID, owns: owns, plan: plan)
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
        do throws(TeamLibraryFailure) {
            try await push(teamID)
            try await pull(teamID)
        } catch {
            guard started == generation else { return .failure(.failed(.signedOut)) }
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

    // MARK: - Helpers

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
        store.save(state)
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
        wakeRequested = false
    }

    // Signing out, signing in or a new entitlement syncs at once; signing out also drops what the old account read.
    private func observeAccount() {
        var previous = account.access.state
        accessCancellable = account.access.$state
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                let hadAccount = previous.isSignedIn || previous.legacy != nil
                previous = state
                if hadAccount, !state.isSignedIn, state.legacy == nil {
                    self.clear()
                }
                self.syncSoon()
            }
    }
}
