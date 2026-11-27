import Combine
import Foundation
import Observation
import os
import TableProFFI
import TableProImport
import TableProModels

nonisolated enum TeamLibraryPublishResult: Equatable, Sendable {
    case unchanged
    case published(Int)
    case conflicts(Int)
    // Kept on this device and sent once the team library answers again.
    case queued(TeamLibraryProblem)
}

nonisolated enum TeamLibraryStatus: Equatable, Sendable {
    case idle
    case syncing
    case synced(Date)
    case failed(TeamLibraryProblem)
}

// A team as the person picked it, in the sign-in shown then: a publish goes out only if that sign-in is still the one.
nonisolated struct TeamLibraryDestination: Equatable, Sendable {
    let teamID: String
    let sessionID: String?
}

// Team Library on the core engine (core ADR 0054): the engine pulls each team this account reads, keeps this device's
// edits on disk until the team takes them, and holds what both sides changed for Keep Mine or Keep Theirs. This shows
// what it holds for the sign-in in front of the app and publishes through it, by the Mac's rules (TeamLibrary.swift):
// nothing of a sign-in shows once it ends, a publish is bound to the sign-in shown when its team was picked, and a
// sign-in by another owner deletes what the last one left on this device.
@MainActor @Observable
final class TeamLibraryModel {
    private static let logger = Logger(subsystem: "com.TablePro", category: "TeamLibrary")

    private(set) var teams: [TeamLibraryTeam] = []
    private(set) var status: TeamLibraryStatus = .idle
    // Edits the team has not taken yet: pending, in conflict, refused or waiting for a first pull.
    private(set) var unsent: [UnsentTeamEditInfo] = []
    // Edits another owner left here, deleted when this one signed in, named once for the person.
    private(set) var discardedForAnotherOwner: [String] = []
    private(set) var isSignedIn = false
    let conflicts: TeamConflictsModel

    @ObservationIgnored private let source: TeamLibrarySource
    @ObservationIgnored private var observers: Set<AnyCancellable> = []
    @ObservationIgnored private var lastStatuses: [TeamScopeStatusInfo] = []
    // Each read and each change of sign-in takes the next one, so an answer begun under an older one changes nothing.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var shownSession: String?
    @ObservationIgnored private var owner: TeamLibraryOwnerArg?
    @ObservationIgnored private var ownerUnsent: [String] = []
    @ObservationIgnored private var publishing = 0

    init(source: TeamLibrarySource) {
        self.source = source
        conflicts = TeamConflictsModel(engine: { try await source.engine() })
    }

    var writableTeams: [TeamLibraryTeam] {
        teams.filter(\.canWrite)
    }

    func start() {
        guard observers.isEmpty else { return }
        source.changes
            .sink { [weak self] in
                Task { @MainActor [weak self] in await self?.refresh() }
            }
            .store(in: &observers)
        Task { await refresh() }
    }

    func team(_ id: String) -> TeamLibraryTeam? {
        teams.first { $0.id == id }
    }

    // Taken when the person picks the team, before any confirmation waits.
    func destination(_ teamID: String) -> TeamLibraryDestination {
        TeamLibraryDestination(teamID: teamID, sessionID: shownSession)
    }

    func acknowledgeDiscarded() {
        discardedForAnotherOwner = []
    }

    // A failed read keeps what shows.
    func refresh() async {
        follow()
        guard let session = shownSession else { return }
        generation += 1
        let started = generation
        do {
            let engine = try await source.engine()
            let teams = try await engine.teamLibrary()
            // The teams show whatever else fails to read; the status and the edits keep their last reading.
            let statuses = (try? await engine.teamScopeStatus()) ?? lastStatuses
            let unsent = (try? await engine.unsentTeamEdits()) ?? self.unsent
            guard started == generation, session == shownSession else { return }
            commit(teams: teams, statuses: statuses, unsent: unsent)
            await conflicts.refresh()
        } catch {
            guard started == generation, session == shownSession else { return }
            TeamLibraryLog.failure(Self.logger, "Reading the team library failed", error)
            if publishing == 0 {
                status = .failed(TeamLibraryProblem(error))
            }
        }
    }

    // MARK: - Publishing

    func publishConnections(
        _ connections: [DatabaseConnection],
        to destination: TeamLibraryDestination
    ) async throws(TeamLibraryProblem) -> TeamLibraryPublishResult {
        let arguments: [TeamConnectionArg]
        do {
            arguments = try Self.connectionArguments(connections)
        } catch {
            TeamLibraryLog.failure(Self.logger, "Could not encode the connections to publish", error)
            throw .refused
        }
        return try await publish(to: destination) { engine in
            try await engine.publishTeamConnections(teamId: destination.teamID, connections: arguments)
        }
    }

    // Every saved query and folder this device holds: the core removes what this device published and no longer holds.
    func publishSavedQueries(
        _ contents: SavedQueryContents,
        to destination: TeamLibraryDestination
    ) async throws(TeamLibraryProblem) -> TeamLibraryPublishResult {
        let arguments = Self.savedQueryArguments(contents)
        return try await publish(to: destination) { engine in
            try await engine.publishTeamSavedQueries(
                teamId: destination.teamID,
                folders: arguments.folders,
                queries: arguments.queries
            )
        }
    }

    func remove(_ items: [TeamLibraryItemRef], from destination: TeamLibraryDestination) async throws(TeamLibraryProblem)
        -> TeamLibraryPublishResult {
        try await publish(to: destination) { engine in
            try await engine.removeTeamItems(teamId: destination.teamID, items: items)
        }
    }

    // A team the account can publish to, by the iOS export of each connection: no password, passphrase or one-time
    // code secret, as the Mac's team copy.
    static func connectionArguments(_ connections: [DatabaseConnection]) throws -> [TeamConnectionArg] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try connections.map { connection in
            let settings = IOSConnectionExportService.portableSettings(for: connection, keepingLocalCredentials: true)
            let data = try encoder.encode(settings)
            guard let json = String(bytes: data, encoding: .utf8) else {
                throw EncodingError.invalidValue(data, .init(codingPath: [], debugDescription: "not UTF-8"))
            }
            return TeamConnectionArg(id: TeamLibraryID.of(connection.id), settingsJson: json)
        }
    }

    nonisolated static func savedQueryArguments(_ contents: SavedQueryContents) -> (folders: [TeamFolderArg], queries: [TeamQueryArg]) {
        let folders = contents.folders.map {
            TeamFolderArg(
                id: TeamLibraryID.of($0.id),
                name: $0.name,
                parentId: $0.parentId.map(TeamLibraryID.of),
                sortOrder: Int64($0.sortOrder)
            )
        }
        let queries = contents.queries.map {
            TeamQueryArg(
                id: TeamLibraryID.of($0.id),
                name: $0.name,
                query: $0.query,
                keyword: $0.keyword.flatMap { $0.isEmpty ? nil : $0 },
                folderId: $0.folderId.map(TeamLibraryID.of),
                connectionId: $0.connectionId.map(TeamLibraryID.of),
                sortOrder: Int64($0.sortOrder)
            )
        }
        return (folders, queries)
    }

    nonisolated static func result(of publish: TeamPublishInfo) throws(TeamLibraryProblem) -> TeamLibraryPublishResult {
        if publish.conflicts > 0 {
            return .conflicts(Int(publish.conflicts))
        }
        if publish.unsent > 0 {
            let problem = publish.problem.map(TeamLibraryProblem.init(code:)) ?? .offline
            guard problem.isRetryable else { throw problem }
            return .queued(problem)
        }
        return publish.edits == 0 ? .unchanged : .published(Int(publish.edits))
    }

    private func publish(
        to destination: TeamLibraryDestination,
        _ call: (any TeamLibraryCalls) async throws -> TeamPublishInfo
    ) async throws(TeamLibraryProblem) -> TeamLibraryPublishResult {
        follow()
        guard let session = destination.sessionID, session == shownSession else { throw .signedOut }
        // The roles come from the engine's first read of the teams, which may not have answered yet.
        if team(destination.teamID)?.canWrite != true {
            await refresh()
            guard session == shownSession else { throw .signedOut }
        }
        guard team(destination.teamID)?.canWrite == true else { throw .writeForbidden }
        publishing += 1
        status = .syncing
        defer {
            publishing -= 1
            if publishing == 0 {
                status = Self.status(of: lastStatuses)
            }
        }
        let answer: Result<TeamPublishInfo, TeamLibraryProblem>
        do {
            let engine = try await source.engine()
            guard session == shownSession else { throw TeamLibraryProblem.signedOut }
            answer = .success(try await call(engine))
        } catch {
            answer = .failure(TeamLibraryProblem(error))
            TeamLibraryLog.failure(Self.logger, "Publishing to the team library failed", error)
        }
        await refresh()
        switch answer {
        case .success(let publish):
            return try Self.result(of: publish)
        case .failure(let problem):
            throw problem
        }
    }

    // MARK: - Unsent edits

    // The sign-in shown now, which an action the person picks carries until they confirm it.
    var shownSessionID: String? {
        follow()
        return shownSession
    }

    // None discards every team's, refused and waiting edits included. `session` is the sign-in the list was shown
    // under: another account's edits are never discarded for it.
    func discardUnsent(team: String?, under session: String?) async throws(TeamLibraryProblem) {
        follow()
        guard let session, session == shownSession else { throw .signedOut }
        do {
            try await source.engine().discardTeamEdits(teamId: team)
        } catch {
            TeamLibraryLog.failure(Self.logger, "Discarding the unsent Team Library edits failed", error)
            throw TeamLibraryProblem(error)
        }
        await refresh()
    }

    // One pass now. What the team has still not taken stays listed with why.
    func sendUnsent() async throws(TeamLibraryProblem) {
        do {
            try await source.engine().syncNow(why: .person)
        } catch {
            TeamLibraryLog.failure(Self.logger, "Sending the unsent Team Library edits failed", error)
            await refresh()
            throw TeamLibraryProblem(error)
        }
        await refresh()
    }

    // The edits a sign-out lists, read from the engine whatever shows, since a lost team_library hides the library but
    // keeps its edits. Nil when they could not be read.
    func unsentNames() async -> [String]? {
        do {
            return try await source.engine().unsentTeamEdits().map(Self.name(of:))
        } catch {
            TeamLibraryLog.failure(Self.logger, "Listing the unsent Team Library edits failed", error)
            return nil
        }
    }

    // Sign Out's Upload: one pass now. What the team has still not taken comes back, with why; nil when it could not be
    // read.
    func upload() async -> (unsent: [String]?, problem: TeamLibraryProblem?) {
        var problem: TeamLibraryProblem?
        do throws(TeamLibraryProblem) {
            try await sendUnsent()
        } catch {
            problem = error
        }
        guard let left = await unsentNames() else { return (nil, problem) }
        return (left, left.isEmpty ? nil : problem)
    }

    // The sign-out of `session`, then all of the account's Team Library data, as the Mac's TeamLibrary.signOut. The
    // engine is the service of the sign-in that ends, read before it ends, which still deletes after. Nil when the
    // session ended another way first, so nothing was signed out or deleted.
    func signOut(session: String?, through signOut: @MainActor () async -> Void) async -> Bool? {
        let engine = try? await source.engine()
        guard source.session() == session, session != nil else { return nil }
        await signOut()
        return await deleteDataAfterSignOut(through: engine)
    }

    // All of the signing-out account's Team Library data, verified gone, through the service of the sign-in that ends,
    // which still deletes after it ended. False when any of it remains, which keeps Team Library off for that account
    // until a later delete succeeds.
    func deleteDataAfterSignOut(through engine: (any TeamLibraryCalls)?) async -> Bool {
        guard let engine else { return owner == nil }
        do {
            try await engine.deleteTeamLibraryData()
        } catch {
            TeamLibraryLog.failure(Self.logger, "Deleting the Team Library data failed", error)
            return false
        }
        owner = nil
        ownerUnsent = []
        return true
    }

    nonisolated static func name(of edit: UnsentTeamEditInfo) -> String {
        let name = edit.name.flatMap { $0.isEmpty ? nil : TeamLibraryVisibleText.name($0) } ?? edit.item.id
        switch edit.state {
        case .pending, .waiting:
            return name
        case .conflict:
            return String(format: String(localized: "%@ (in conflict)"), name)
        case .refused(let code):
            return String(format: String(localized: "%1$@ (%2$@)"), name, TeamLibraryProblem(code: code).message)
        }
    }

    nonisolated static func state(of edit: UnsentTeamEditInfo) -> String {
        switch edit.state {
        case .pending:
            edit.deletion ? String(localized: "Removal waiting to send") : String(localized: "Waiting to send")
        case .waiting:
            String(localized: "Waiting for the team's first download")
        case .conflict:
            String(localized: "Changed by you and the team")
        case .refused(let code):
            TeamLibraryProblem(code: code).message
        }
    }

    // MARK: - My connections

    // A team connection is copied into this device's library under an id derived from the team item, so adding it
    // again finds the copy already there. Nil when the library refused the copy.
    // Nil also when the sign-in the item was shown under has ended: nothing of it is copied after.
    func addToMyConnections(
        _ item: TeamLibraryConnectionItem,
        of team: TeamLibraryTeam,
        shownUnder session: String?,
        in appState: AppState
    ) -> UUID? {
        follow()
        guard let session, session == shownSession else { return nil }
        let id = TeamLibraryID.copy(team: team.id, item: item.id)
        if appState.connections.contains(where: { $0.id == id }) {
            return id
        }
        let copy = DatabaseConnection(importedSettings: item.settings, id: id)
        return appState.addConnection(copy) ? id : nil
    }

    // MARK: - Sign-ins

    // The session ends for good the moment the account reports another sign-in or a sign-out: nothing of it shows from
    // here on. Another owner's sign-in deletes what the last one left on this device.
    private func follow() {
        let session = source.session()
        if isSignedIn != (session != nil) {
            isSignedIn = session != nil
        }
        if session != shownSession {
            generation += 1
            if shownSession != nil {
                ownerUnsent = unsent.map(Self.name(of:))
            }
            shownSession = session
            clear()
        }
        guard let next = source.owner(), next != owner else { return }
        let discarded = owner == nil ? [] : ownerUnsent
        owner = next
        ownerUnsent = []
        Task { await adopt(next, discarding: discarded) }
    }

    private func adopt(_ next: TeamLibraryOwnerArg, discarding discarded: [String]) async {
        guard let deleteOtherOwners = source.deleteOtherOwners else { return }
        do {
            try await deleteOtherOwners(next)
            if !discarded.isEmpty {
                Self.logger.notice("Deleted \(discarded.count) Team Library edits another account left unsent")
                discardedForAnotherOwner = discarded
            }
        } catch {
            TeamLibraryLog.failure(Self.logger, "Deleting another account's Team Library data failed", error)
        }
    }

    private func clear() {
        teams = []
        unsent = []
        lastStatuses = []
        status = .idle
        conflicts.end()
    }

    private func commit(teams infos: [TeamLibraryTeamInfo], statuses: [TeamScopeStatusInfo], unsent: [UnsentTeamEditInfo]) {
        let next = infos.map(TeamLibraryTeam.init)
            .sorted { ($0.name.localizedLowercase, $0.id) < ($1.name.localizedLowercase, $1.id) }
        if next != teams {
            teams = next
        }
        let names = Dictionary(next.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var writers: [String: String] = [:]
        for info in infos {
            for item in info.items {
                guard let writer = TeamLibraryChange(item).writer else { continue }
                let key = TeamConflictsModel.writerKey(
                    scope: info.teamId, kind: TeamConflictsModel.wireKind(item.kind), id: item.id
                )
                writers[key] = writer
            }
        }
        conflicts.name(names, writers: writers)
        if unsent != self.unsent {
            self.unsent = unsent
        }
        lastStatuses = statuses
        if publishing == 0 {
            status = Self.status(of: statuses)
        }
    }

    // A member that only reads is no failure; a team past its license's grace is, since its edits wait.
    nonisolated static func status(of statuses: [TeamScopeStatusInfo]) -> TeamLibraryStatus {
        if let problem = statuses.lazy.compactMap(\.problem).first {
            return .failed(TeamLibraryProblem(code: problem))
        }
        if statuses.contains(where: \.pullOnly) {
            return .failed(.licenseExpired)
        }
        guard let last = statuses.compactMap(\.lastSyncedMs).max() else { return .idle }
        return .synced(Date(timeIntervalSince1970: TimeInterval(last) / 1_000))
    }
}
