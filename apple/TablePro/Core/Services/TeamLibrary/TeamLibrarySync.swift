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
// I1. Unsent edits, the pushes still to go, the conflicts not resolved and the edits the server refused, live only in
//     memory, in the session's store. Nothing about them is written to disk.
// I2. The read cache sits in a folder named from the server and account (TeamLibraryStorage). Only the open session's
//     folder is read; every other one is deleted, best-effort, on sign-out, switch and launch.
// I3. The library 0.88 and earlier kept is read once, on the launch whose restored sign-in is tablepro.app's: a flag
//     saying so is written and read back first (if it does not stick, nothing is read), its cache is copied into that
//     account's folder and its files deleted. Its unsent edits are uploaded once, under that session's bearer, outside
//     the sync queue and with no hold; what is refused or conflicts is listed once and dropped, and ending the session
//     cancels the upload. Any other sign-in, and choosing a company server, set the flag and delete it unread at once.
// I4. A switch or sign-out stays in this process, in two steps. End the session: the moment the account reports a
//     sign-out of any kind, another account or server, or a lost team_library, the session ends for good, on the main
//     actor: nothing of it shows any more, its unsent edits are listed as discarded, and no result of it is recorded
//     or shown after any await. A returning team_library opens a new session. Drop the store: its folder goes after the
//     pass in flight drains, without holding up the next session, whose store is another object. Sign Out and quit
//     first stop sync, wait for the pass in flight and ask push, discard or cancel. A refused edit stays listed, with
//     why, until it is discarded or a later publish of the same item is accepted: the latest wins. The session id lives
//     only in the core's process and a bearer of another session is refused; a publish is bound to the session shown
//     at its confirmation and checked again before it is sent.
// I5. Quitting with unsent edits asks push, discard or cancel, and a discard waits for the quit to be committed. While
//     edits wait, Team Library counts them as not uploaded.
// I6. Losing team_library ends the session as an involuntary sign-out does, and says what it discarded.
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
    // The open session's store; nil between sessions.
    private var session: SessionStore?
    // Set once the core has restored the last run's sign-in, with the session it restored, if any.
    private var restoreSettled = false
    private var restoredSessionID: String?
    // Holds taken by a sign-out or a quit asking: while any is out, no pass, publish or resolve runs, so the unsent
    // edits listed stay the last.
    private var holds = 0
    private var resumesAfterHold = false
    private let reportDiscarded: @MainActor ([String]) -> Void
    private let reportEarlierEditsNotTaken: @MainActor ([String]) -> Void
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
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

    fileprivate struct SessionKey: Equatable {
        let sessionID: String
        let server: AccountServer
        let accountID: String

        // None once the entitlement leaves team_library out: losing it ends the session like a sign-out.
        init?(_ state: AccountState) {
            guard state.isSignedIn, let sessionID = state.sessionID, let accountID = state.entitlement?.accountID,
                  FeatureAccess.resolve(.teamLibrary, state: state) != .notIncluded
            else { return nil }
            self.sessionID = sessionID
            self.server = state.server
            self.accountID = accountID
        }
    }

    fileprivate struct RefusedEdit {
        let teamID: String
        let key: TeamLibraryKey
        let name: String
        let reason: TeamLibraryFailure
    }

    // One session's store: what it read, and the edits it has not sent. A pass, a publish or the 0.88 upload holds the
    // store it began with and records nothing into it once it has ended; the next session gets another store.
    @MainActor
    fileprivate final class SessionStore {
        let key: SessionKey
        let folder: URL
        let cache: TeamLibraryStateStore
        // Calls only the session's server, under its bearer.
        let client: TeamLibraryClient
        weak var owner: TeamLibrarySync?
        var teams: [String: TeamLibraryTeamState] = [:] {
            didSet { owner?.storeChanged(self) }
        }
        // Edits the server refused, with why: unsent until they are discarded.
        var refused: [RefusedEdit] = [] {
            didSet { owner?.storeChanged(self) }
        }
        // The unsent edits 0.88 left, while their one upload runs.
        var earlier: [TeamLibraryTeamState] = [] {
            didSet { owner?.storeChanged(self) }
        }
        var earlierUpload: Task<Void, Never>?
        // The /v1 cache, shown until every team this account reads has a first /v2 snapshot.
        var legacy: TeamLibraryLegacyLibrary?
        // GET /v2/me's address, the one the /v1 cache names publishers by.
        var accountEmail: String?
        private(set) var hasEnded = false

        init(key: SessionKey, folder: URL, cache: TeamLibraryStateStore, client: TeamLibraryClient) {
            self.key = key
            self.folder = folder
            self.cache = cache
            self.client = client
        }

        var unsentChanges: [String] {
            (earlier + teams.values.sorted { $0.teamName < $1.teamName }).flatMap { state in
                (state.pending + state.conflicts.map(\.edit)).map { TeamLibrarySync.name(of: $0, in: state) }
            } + refused.map { TeamLibraryUnsentChanges.refused($0.name, because: $0.reason) }
        }

        func end() {
            hasEnded = true
            earlierUpload?.cancel()
            earlierUpload = nil
        }
    }

    init(
        account: AccountServices,
        storage: TeamLibraryStorage,
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Date = { Date() },
        reportDiscarded: @escaping @MainActor ([String]) -> Void = TeamLibraryUnsentChanges.presentDiscarded,
        reportEarlierEditsNotTaken: @escaping @MainActor ([String]) -> Void = TeamLibraryUnsentChanges.presentEarlierEditsNotTaken
    ) {
        self.account = account
        self.storage = storage
        self.clock = clock
        self.now = now
        self.reportDiscarded = reportDiscarded
        self.reportEarlierEditsNotTaken = reportEarlierEditsNotTaken
    }

    var canPublish: Bool {
        !writableTeams.isEmpty
    }

    // Edits not pushed yet and conflicts not resolved, which live only in memory.
    var hasUnsentChanges: Bool {
        !unsentChanges.isEmpty
    }

    // Their names, as a sign-out or a quit lists them, and the refused ones with why.
    var unsentChanges: [String] {
        session?.unsentChanges ?? []
    }

    var isHeld: Bool {
        holds > 0
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

    // The 0.88 upload finishes first, outside the hold, so nothing held waits on it. Then the schedule stops and the
    // pass or publish still out ends, so `unsentChanges` stays final until the release.
    func hold() async -> TeamLibraryHold {
        if let upload = session?.earlierUpload {
            await upload.value
        }
        let hold = beginHold()
        await tail?.value
        return hold
    }

    private func beginHold() -> TeamLibraryHold {
        if holds == 0 {
            resumesAfterHold = scheduleTask != nil
            stopSchedule()
        }
        holds += 1
        return TeamLibraryHold { [weak self] in self?.endHold() }
    }

    private func endHold() {
        holds -= 1
        guard holds == 0 else { return }
        if resumesAfterHold {
            start()
        } else if scheduleTask != nil {
            // A schedule started while held skipped its pass and sleeps.
            syncSoon()
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

    // Discard: the unsent edits go, refused ones and the upload of 0.88's included.
    func discardHeld() {
        guard isHeld, let store = session else { return }
        store.earlierUpload?.cancel()
        store.earlierUpload = nil
        store.earlier = []
        for var state in store.teams.values where !state.pending.isEmpty || !state.conflicts.isEmpty {
            state.pending = []
            state.conflicts = []
            commit(state, in: store)
        }
        store.refused = []
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
        TeamLibraryDestination(teamID: teamID, sessionID: session?.key.sessionID)
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
        guard !isHeld, let store = session, var state = store.teams[conflict.teamID],
              state.conflicts.contains(where: { $0.id == conflict.id })
        else { return }
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
        commit(state, in: store)
        publishContent()
        if pushes {
            await sync()
        }
    }

    func current(for conflict: TeamLibraryConflict) -> TeamLibraryChange? {
        session?.teams[conflict.teamID]?.items[conflict.key] ?? conflict.current
    }

    func teamName(of teamID: String) -> String? {
        session?.teams[teamID]?.teamName
    }

    private func performSync(whileHeld: Bool = false) async -> TeamLibrarySyncOutcome {
        follow(account.access.state)
        guard !isHeld || whileHeld else { return .skipped }
        guard account.isSignedIn, let store = session else { return .skipped }
        guard account.access.isAvailable(.teamLibrary) else { return .skipped }
        guard rateLimitHold == nil else { return .failed(.rateLimited(retryAfter: nil)) }
        status = .syncing
        let profile: AccountProfile
        do throws(TeamLibraryFailure) {
            profile = try await store.client.profile()
        } catch {
            guard !store.hasEnded else { return .skipped }
            holdIfRateLimited(error)
            return finish(.failed(error))
        }
        guard !store.hasEnded else { return .skipped }
        store.accountEmail = profile.email
        adopt(profile.memberships, in: store)

        var failure: TeamLibraryFailure?
        for teamID in store.teams.keys.sorted() where !store.hasEnded {
            do throws(TeamLibraryFailure) {
                try await syncTeam(teamID, in: store)
            } catch {
                guard !store.hasEnded else { break }
                Self.logger.warning("Team library sync failed: \(error.logName, privacy: .public)")
                holdIfRateLimited(error)
                if error != .unreadable {
                    failure = failure ?? error
                }
                if error.isRetryable { break }
            }
        }
        // The session ended while a pull or a push was out: nothing it brought back is recorded or shown.
        guard !store.hasEnded else { return .skipped }
        if store.legacy != nil, store.teams.values.allSatisfy({ $0.cursor != nil }) {
            store.legacy = nil
            store.cache.removeLegacy()
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
    private func adopt(_ memberships: [AccountMembership], in store: SessionStore) {
        let seated = memberships.filter(\.hasSeat)
        let listed = Set(seated.map(\.teamID))
        for teamID in store.teams.keys where !listed.contains(teamID) {
            drop(teamID, because: .unreadable, in: store)
        }
        for membership in seated {
            var state = store.teams[membership.teamID]
                ?? TeamLibraryTeamState(teamID: membership.teamID, teamName: membership.teamName, canWrite: false)
            state.teamName = membership.teamName
            state.canWrite = membership.role == "owner" || membership.role == "admin"
            if !state.canWrite, !state.pending.isEmpty || !state.conflicts.isEmpty {
                Self.logger.notice(
                    "Refusing \(state.pending.count) unpushed team library edits and \(state.conflicts.count) conflicts: this account only reads the team's library"
                )
                refuse(state.pending + state.conflicts.map(\.edit), in: state, because: .writeForbidden, store: store)
                state.pending = []
                state.conflicts = []
            }
            commit(state, in: store)
        }
    }

    private func syncTeam(_ teamID: String, in store: SessionStore) async throws(TeamLibraryFailure) {
        var pulled = false
        if store.teams[teamID]?.cursor == nil {
            try await pull(teamID, in: store)
            pulled = true
        }
        guard !store.hasEnded else { return }
        if let state = store.teams[teamID], state.canWrite, !state.pending.isEmpty {
            do throws(TeamLibraryFailure) {
                try await push(teamID, in: store)
            } catch .licenseExpired {
                // Past its license's grace the server still answers pulls; the edits wait for a renewed license.
                try await pull(teamID, in: store)
                throw .licenseExpired
            }
            try await pull(teamID, in: store)
        } else if !pulled {
            try await pull(teamID, in: store)
        }
    }

    private func pull(_ teamID: String, in store: SessionStore) async throws(TeamLibraryFailure) {
        guard !store.hasEnded, let start = store.teams[teamID] else { return }
        var cursor = start.cursor
        // Without a cursor the answer is a snapshot, which replaces what this Mac holds once its last page is in.
        var snapshot: [TeamLibraryKey: TeamLibraryChange]? = cursor == nil ? [:] : nil
        while true {
            let page: TeamLibraryPage
            do throws(TeamLibraryFailure) {
                page = try await store.client.pull(teamID: teamID, cursor: cursor)
            } catch .cursorRefused where cursor != nil {
                guard !store.hasEnded else { return }
                Self.logger.notice("The server refused the team library cursor; pulling a snapshot")
                cursor = nil
                snapshot = [:]
                continue
            } catch .unreadable {
                guard !store.hasEnded else { return }
                drop(teamID, because: .unreadable, in: store)
                throw .unreadable
            }
            guard !store.hasEnded, var state = store.teams[teamID] else { return }
            if snapshot != nil {
                for change in page.changes {
                    snapshot?[change.key] = change
                }
            } else {
                for change in page.changes {
                    state.items[change.key] = change
                }
                state.cursor = page.cursor
                commit(state, in: store)
            }
            cursor = page.cursor
            guard page.hasMore else { break }
        }
        guard var state = store.teams[teamID] else { return }
        if let snapshot {
            state.items = snapshot
            state.cursor = cursor
            if let legacy = store.legacy, let accountEmail = store.accountEmail {
                // The first snapshot after the update: what this account published over /v1 is this Mac's to remove.
                state.published.formUnion(legacy.published(by: accountEmail, in: snapshot))
            }
        }
        state.syncedAt = now()
        commit(state, in: store)
    }

    private func push(_ teamID: String, in store: SessionStore) async throws(TeamLibraryFailure) {
        dropOversizedEdits(teamID, in: store)
        var refusal: TeamLibraryFailure?
        while !store.hasEnded, let state = store.teams[teamID], state.canWrite, !state.pending.isEmpty {
            let batch = Self.batch(state.pending)
            let answer: TeamLibraryPushAnswer
            do throws(TeamLibraryFailure) {
                answer = try await store.client.push(teamID: teamID, edits: batch)
            } catch .writeForbidden {
                guard !store.hasEnded else { return }
                if var current = store.teams[teamID] {
                    refuse(current.pending + current.conflicts.map(\.edit), in: current, because: .writeForbidden, store: store)
                    current.canWrite = false
                    current.pending = []
                    current.conflicts = []
                    commit(current, in: store)
                }
                throw .writeForbidden
            } catch .refused(_) {
                guard !store.hasEnded else { return }
                Self.logger.error("The team library refused a push of \(batch.count) changes without naming one")
                if var current = store.teams[teamID] {
                    let count = min(batch.count, current.pending.count)
                    refuse(Array(current.pending.prefix(count)), in: current, because: .refused(nil), store: store)
                    current.pending.removeFirst(count)
                    commit(current, in: store)
                }
                throw .refused(nil)
            } catch .unreadable {
                guard !store.hasEnded else { return }
                drop(teamID, because: .unreadable, in: store)
                throw .unreadable
            }
            guard !store.hasEnded, var current = store.teams[teamID] else { return }
            switch answer {
            case .refusedChange(let index):
                // Nothing in the batch was applied: only the change the server named is dropped, the rest goes again.
                Self.logger.error("The team library refused change \(index) of a push of \(batch.count)")
                if batch.indices.contains(index), current.pending.indices.contains(index),
                   TeamLibraryKey(current.pending[index]) == TeamLibraryKey(batch[index]) {
                    let reason = TeamLibraryFailure.refused(Self.name(of: current.pending[index], in: current))
                    refuse([current.pending[index]], in: current, because: reason, store: store)
                    current.pending.remove(at: index)
                    refusal = refusal ?? reason
                } else {
                    let count = min(batch.count, current.pending.count)
                    refuse(Array(current.pending.prefix(count)), in: current, because: .refused(nil), store: store)
                    current.pending.removeFirst(count)
                    refusal = refusal ?? .refused(nil)
                }
                commit(current, in: store)
            case .results(let results):
                current.pending.removeFirst(min(batch.count, current.pending.count))
                for (edit, result) in zip(batch, results) {
                    apply(result, of: edit, to: &current, in: store)
                }
                commit(current, in: store)
            }
        }
        if let refusal {
            throw refusal
        }
    }

    fileprivate static func name(of edit: TeamLibraryEdit, in state: TeamLibraryTeamState) -> String {
        let kind = edit.kind.rawValue
        return TeamLibraryPayload.name(kind: kind, data: edit.data?.additionalProperties)
            ?? TeamLibraryPayload.name(kind: kind, data: state.items[TeamLibraryKey(edit)]?.dataValues)
            ?? edit.clientId
    }

    private func apply(
        _ result: Components.Schemas.LibraryResult,
        of edit: TeamLibraryEdit,
        to state: inout TeamLibraryTeamState,
        in store: SessionStore
    ) {
        let key = TeamLibraryKey(edit)
        // Moving someone else's item out of a deleted folder never makes it this Mac's to remove later.
        let isMove = state.moves.contains(key)
        switch result.status {
        case "applied":
            store.refused.removeAll { $0.teamID == state.teamID && $0.key == key }
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
                // The team holds it as sent, so it was taken: a refusal of it before is over too.
                store.refused.removeAll { $0.teamID == state.teamID && $0.key == key }
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
    private func dropOversizedEdits(_ teamID: String, in store: SessionStore) {
        guard var state = store.teams[teamID] else { return }
        let oversized = { (edit: TeamLibraryEdit) -> Bool in
            guard let data = edit.data?.additionalProperties else { return false }
            return TeamLibraryPayload.byteCount(of: data) > Self.maxItemBytes
        }
        let dropped = state.pending.filter(oversized)
        guard !dropped.isEmpty else { return }
        Self.logger.error("Not publishing \(dropped.count) team library items larger than 256 KiB")
        refuse(dropped, in: state, because: .refused(nil), store: store)
        state.pending.removeAll(where: oversized)
        commit(state, in: store)
    }

    // An edit that can never be sent as it is: listed with why until the person discards it.
    private func refuse(
        _ edits: [TeamLibraryEdit], in state: TeamLibraryTeamState, because reason: TeamLibraryFailure, store: SessionStore
    ) {
        guard !store.hasEnded else { return }
        store.refused += edits.map {
            RefusedEdit(teamID: state.teamID, key: TeamLibraryKey($0), name: Self.name(of: $0, in: state), reason: reason)
        }
    }

    // A team this account no longer reads goes, and its unsent edits stay listed as refused.
    private func drop(_ teamID: String, because reason: TeamLibraryFailure, in store: SessionStore) {
        guard !store.hasEnded else { return }
        if let state = store.teams[teamID] {
            refuse(state.pending + state.conflicts.map(\.edit), in: state, because: reason, store: store)
        }
        store.teams[teamID] = nil
        store.cache.remove(teamID: teamID)
    }

    fileprivate func storeChanged(_ store: SessionStore) {
        guard store === session else { return }
        countNotUploaded()
    }

    private func countNotUploaded() {
        let count = session.map { store in
            (store.earlier + store.teams.values).reduce(store.refused.count) { $0 + $1.pending.count + $1.conflicts.count }
        } ?? 0
        if count != notUploadedCount {
            notUploadedCount = count
        }
    }

    // `owns` tells this Mac's own items from someone else's that a publish only moves.
    private func publish(
        to destination: TeamLibraryDestination,
        owns: @escaping (TeamLibraryKey) -> Bool,
        plan: @escaping (TeamLibraryTeamState) throws -> [TeamLibraryEdit]
    ) async throws(TeamLibraryPublishError) -> TeamLibraryPublishResult {
        let result = await serially { [weak self] () -> Result<TeamLibraryPublishResult, TeamLibraryPublishError> in
            guard let self, !self.isHeld, let store = self.session, let sessionID = destination.sessionID,
                  store.key.sessionID == sessionID, self.account.access.state.sessionID == sessionID
            else { return .failure(.failed(.signedOut)) }
            return await self.performPublish(to: destination.teamID, owns: owns, plan: plan, in: store)
        }.value
        return try result.get()
    }

    private func performPublish(
        to teamID: String,
        owns: (TeamLibraryKey) -> Bool,
        plan: (TeamLibraryTeamState) throws -> [TeamLibraryEdit],
        in store: SessionStore
    ) async -> Result<TeamLibraryPublishResult, TeamLibraryPublishError> {
        let outcome = await performSync()
        guard !store.hasEnded, session === store else { return .failure(.failed(.signedOut)) }
        guard let state = store.teams[teamID], state.canWrite else {
            if case .failed(let failure) = outcome, store.teams[teamID] == nil {
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
        commit(queued, in: store)
        // The schedule pushes them once the hold ends.
        guard rateLimitHold == nil else { return .success(.queued(.rateLimited(retryAfter: nil))) }
        do throws(TeamLibraryFailure) {
            try await push(teamID, in: store)
            try await pull(teamID, in: store)
        } catch {
            guard !store.hasEnded else { return .failure(.failed(.signedOut)) }
            holdIfRateLimited(error)
            publishContent()
            _ = finish(.failed(error))
            guard error.isRetryable else { return .failure(.failed(error)) }
            retryLater()
            return .success(.queued(error))
        }
        guard !store.hasEnded else { return .failure(.failed(.signedOut)) }
        publishContent()
        _ = finish(.synced)
        let keys = Set(edits.map { TeamLibraryKey($0) })
        let conflicted = store.teams[teamID]?.conflicts.filter { keys.contains($0.key) }.count ?? 0
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

    // Nothing is recorded into a store whose session has ended.
    private func commit(_ state: TeamLibraryTeamState, in store: SessionStore) {
        guard !store.hasEnded else { return }
        var state = state
        // A move stays marked only while its edit waits to be pushed.
        if !state.moves.isEmpty {
            state.moves.formIntersection(state.pending.map { TeamLibraryKey($0) })
        }
        store.teams[state.teamID] = state
        store.cache.save(state)
    }

    // Shows the open session's library only; between sessions, nothing.
    private func publishContent() {
        let teams = session?.teams ?? [:]
        var items = session?.legacy?.changes ?? []
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
        countNotUploaded()
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

    // Ends the session and opens the next as the account reports them, at once. `state` is the one being published: the
    // subscription sees it before `access.state` holds it.
    private func follow(_ state: AccountState) {
        guard state.isRestored else { return }
        let next = SessionKey(state)
        if !restoreSettled {
            restoreSettled = true
            restoredSessionID = state.isSignedIn ? state.sessionID : nil
            if next == nil {
                storage.removeFolders(except: nil)
            }
        }
        // Any sign-in but the restored tablepro.app one, entitlement or not, and any company server, signed in or not,
        // decide the library 0.88 kept at once: only that restored sign-in can be its owner.
        if !state.server.isProduction || state.isSignedIn && state.sessionID != restoredSessionID {
            storage.discardFlat()
        }
        guard next != session?.key else { return }
        endSession()
        if let next {
            open(next)
        }
    }

    private func open(_ next: SessionKey) {
        let folder = storage.folder(server: next.server.apiOrigin, accountID: next.accountID)
        let cache = storage.cache(in: folder)
        storage.removeFolders(except: folder)
        var kept: [TeamLibraryTeamState] = []
        if next.sessionID == restoredSessionID, next.server.isProduction {
            kept = storage.takeFlat(into: cache, server: next.server.apiOrigin, accountID: next.accountID)
        } else {
            storage.discardFlat()
        }
        let client = TeamLibraryClient(api: account.api(pinnedTo: next.server, session: next.sessionID))
        let store = SessionStore(key: next, folder: folder, cache: cache, client: client)
        store.teams = Dictionary(cache.loadAll().map { ($0.teamID, $0.cached) }, uniquingKeysWith: { first, _ in first })
        store.legacy = cache.loadLegacy(now: now())
        store.earlier = kept.filter { !$0.pending.isEmpty || !$0.conflicts.isEmpty }
        store.owner = self
        session = store
        publishContent()
        guard !store.earlier.isEmpty else { return }
        store.earlierUpload = Task { [weak self] in
            await self?.uploadEarlierEdits(in: store)
        }
    }

    // End the session: for good, at once, on the main actor. Nothing of it shows from here on, and its unsent edits are
    // listed as discarded; a pass still out records nothing into it. Drop the store: its folder goes once that pass
    // has drained, never the next session's.
    private func endSession() {
        guard let ended = session else { return }
        let dropped = ended.unsentChanges
        ended.end()
        session = nil
        rateLimitHold?.cancel()
        rateLimitHold = nil
        status = .idle
        publishContent()
        _ = serially { [weak self] in
            guard let self else { return }
            self.storage.removeFolders(except: self.session?.folder)
        }
        if !dropped.isEmpty {
            Self.logger.notice("Discarding \(dropped.count) team library changes the session left unsent")
            reportDiscarded(dropped)
        }
    }

    // Once, beside the schedule rather than in its queue, so nothing waits on it; ending the session cancels it.
    private func uploadEarlierEdits(in store: SessionStore) async {
        var notTaken: [String] = []
        for state in store.earlier {
            notTaken += state.conflicts.map { TeamLibraryUnsentChanges.conflicted(Self.name(of: $0.edit, in: state)) }
            notTaken += await pushEarlier(state, in: store)
        }
        guard isLive(store) else { return }
        store.earlier = []
        store.earlierUpload = nil
        if !notTaken.isEmpty {
            Self.logger.notice("\(notTaken.count) team library changes from before the update were not taken")
            reportEarlierEditsNotTaken(notTaken)
        }
        syncSoon()
    }

    // What was not taken, named with why.
    private func pushEarlier(_ state: TeamLibraryTeamState, in store: SessionStore) async -> [String] {
        let name = { (edit: TeamLibraryEdit) in Self.name(of: edit, in: state) }
        let fits = { (edit: TeamLibraryEdit) -> Bool in
            guard let data = edit.data?.additionalProperties else { return true }
            return TeamLibraryPayload.byteCount(of: data) <= Self.maxItemBytes
        }
        var notTaken = state.pending.filter { !fits($0) }.map { TeamLibraryUnsentChanges.refused(name($0), because: .refused(nil)) }
        var pending = state.pending.filter(fits)
        while !pending.isEmpty, isLive(store) {
            let batch = Self.batch(pending)
            let answer: TeamLibraryPushAnswer
            do throws(TeamLibraryFailure) {
                answer = try await store.client.push(teamID: state.teamID, edits: batch)
            } catch {
                return notTaken + pending.map { TeamLibraryUnsentChanges.refused(name($0), because: error) }
            }
            // An answer that comes after the session ended changes nothing.
            guard isLive(store) else { return notTaken }
            switch answer {
            case .refusedChange(let index) where batch.indices.contains(index):
                notTaken.append(TeamLibraryUnsentChanges.refused(name(batch[index]), because: .refused(name(batch[index]))))
                pending.remove(at: index)
            case .refusedChange:
                notTaken += batch.map { TeamLibraryUnsentChanges.refused(name($0), because: .refused(nil)) }
                pending.removeFirst(batch.count)
            case .results(let results):
                pending.removeFirst(batch.count)
                for (edit, result) in zip(batch, results) {
                    if result.status == "applied" || result.status == "conflict" && Self.holds(result.current, as: edit) {
                        markPublished(edit, kept: state, in: store)
                    } else if result.status == "conflict" {
                        notTaken.append(TeamLibraryUnsentChanges.conflicted(name(edit)))
                    }
                }
            }
        }
        return notTaken
    }

    // The store's session has not ended, and the account still names it.
    private func isLive(_ store: SessionStore) -> Bool {
        !Task.isCancelled && !store.hasEnded && account.access.state.sessionID == store.key.sessionID
    }

    // An item this Mac put there is this Mac's to remove later, as after any push it made.
    private func markPublished(_ edit: TeamLibraryEdit, kept: TeamLibraryTeamState, in store: SessionStore) {
        let key = TeamLibraryKey(edit)
        guard isLive(store), var state = store.teams[kept.teamID], !kept.moves.contains(key) else { return }
        if edit.op == .delete {
            state.published.remove(key)
        } else {
            state.published.insert(key)
        }
        commit(state, in: store)
    }
}

// One reason Team Library sync is stopped: a sign-out or a quit asking. Sync goes on once every hold is released; each
// owner releases its own, with `defer` where it can.
@MainActor
internal final class TeamLibraryHold {
    private var end: (@MainActor () -> Void)?

    init(end: @escaping @MainActor () -> Void) {
        self.end = end
    }

    func release() {
        let end = self.end
        self.end = nil
        end?()
    }
}
