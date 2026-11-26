//
//  TeamLibrary.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProFFI
import TableProImport

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

// Team Library on the core engine (core ADR 0054): the engine pulls each team this account reads, keeps this Mac's
// edits on disk until the team takes them, and holds what both sides changed for Keep Mine or Keep Theirs. This shows
// what it holds for the sign-in in front of the app and publishes through it, under M1's rules:
// - Sign Out and a switch of server or account list the unsent edits and ask Upload, Discard or Cancel, and the
//   account's Team Library data is deleted, verified, once it has signed out (`signOut(through:)`).
// - An involuntary sign-out, or losing team_library, keeps the data with its owner (server and account) for that owner's
//   next sign-in. A sign-in by another owner deletes it and names the edits that went.
// - Nothing of a sign-in shows once it ends, and a publish is bound to the sign-in shown when its team was picked.
// - Quitting asks nothing: the edits wait on disk.
@MainActor
internal final class TeamLibrary: ObservableObject {
    static let shared = TeamLibrary(
        source: LiveTeamLibraryEngineSource(host: .shared, core: { try await CoreStoreHost.shared.core() }),
        account: .shared,
        legacy: .live()
    )

    private static let logger = Logger(subsystem: "com.TablePro", category: "TeamLibrary")

    @Published private(set) var content: TeamLibraryContent = .empty
    @Published private(set) var writableTeams: [TeamLibraryTeam] = []
    @Published private(set) var status: TeamLibrarySyncStatus = .idle
    // Edits the team has not taken yet: pending, in conflict, refused or waiting for a first pull.
    @Published private(set) var unsent: [UnsentTeamEditInfo] = []
    let conflicts: TeamLibraryConflictsModel

    private let source: any TeamLibraryEngineSource
    private let account: AccountServices
    private let legacy: TeamLibraryLegacyImport
    private let reportDiscarded: @MainActor ([String]) -> Void
    private var teamNames: [String: String] = [:]
    private var lastStatuses: [TeamScopeStatusInfo] = []
    private var observers: Set<AnyCancellable> = []
    // Each read and each change of sign-in takes the next one, so an answer begun under an older one changes nothing.
    private var generation = 0
    private var shownSession: String?
    // The owner whose data is on this Mac, and its edits as last read, named for the notice a later owner's sign-in gives.
    private var owner: TeamLibraryOwnerArg?
    private var ownerUnsent: [String] = []
    private var publishing = 0
    private var hasRestored = false
    // Each change of the sign-in or of the owner takes the next one. The account publishes its state before the host
    // opens the next sign-in's service, so work that sees the same value after an await still holds that sign-in's
    // service.
    private var signIn = 0

    init(
        source: any TeamLibraryEngineSource,
        account: AccountServices,
        legacy: TeamLibraryLegacyImport,
        reportDiscarded: @escaping @MainActor ([String]) -> Void = TeamLibraryUnsentChanges.presentDiscarded
    ) {
        self.source = source
        self.account = account
        self.legacy = legacy
        self.reportDiscarded = reportDiscarded
        conflicts = TeamLibraryConflictsModel(engine: { try await source.engine() })
    }

    var notUploadedCount: Int {
        unsent.count
    }

    func start() {
        guard observers.isEmpty else { return }
        source.changes
            .sink { [weak self] in
                Task { @MainActor [weak self] in await self?.refresh() }
            }
            .store(in: &observers)
        // In order and at once: `state` is the one being published, which `access.state` holds only after this.
        account.access.$state
            .removeDuplicates()
            .sink { [weak self] state in self?.follow(state) }
            .store(in: &observers)
    }

    // Taken when the person picks the team, before any confirmation waits.
    func destination(_ teamID: String) -> TeamLibraryDestination {
        TeamLibraryDestination(teamID: teamID, sessionID: shownSession)
    }

    func teamName(of teamID: String) -> String? {
        teamNames[teamID]
    }

    // A failed read keeps what shows.
    func refresh() async {
        guard let session = shownSession else { return }
        generation += 1
        let started = generation
        do {
            let engine = try await source.engine()
            let teams = try await engine.teamLibrary()
            let statuses = try await engine.teamScopeStatus()
            let unsent = try await engine.unsentTeamEdits()
            guard started == generation, session == shownSession else { return }
            commit(teams: teams, statuses: statuses, unsent: unsent)
            await conflicts.refresh()
        } catch {
            guard started == generation, session == shownSession else { return }
            Self.logger.error("Reading the team library failed: \(error.publicLogShape, privacy: .public)")
            if publishing == 0 {
                status = .failed(TeamLibraryFailure(error))
            }
        }
    }

    // MARK: - Publishing

    func publishConnections(
        _ connections: [DatabaseConnection],
        exporter: ConnectionBundleExporter = ConnectionBundleExporter(),
        to destination: TeamLibraryDestination
    ) async throws(TeamLibraryPublishError) -> TeamLibraryPublishResult {
        let arguments: [TeamConnectionArg]
        do {
            arguments = try Self.connectionArguments(connections, exporter: exporter)
        } catch {
            Self.logger.error("Could not encode the connections to publish: \(error.publicLogShape, privacy: .public)")
            throw .failed(.refused)
        }
        return try await publish(to: destination) { engine in
            try await engine.publishTeamConnections(teamId: destination.teamID, connections: arguments)
        }
    }

    // Every saved query and folder this Mac holds: the core removes what this Mac published and no longer holds.
    func publishSavedQueries(
        favorites: [SQLFavorite],
        folders: [SQLFavoriteFolder],
        to destination: TeamLibraryDestination
    ) async throws(TeamLibraryPublishError) -> TeamLibraryPublishResult {
        let folderArguments = folders.map {
            TeamFolderArg(
                id: TeamLibraryID.of($0.id),
                name: $0.name,
                parentId: $0.parentId.map(TeamLibraryID.of),
                sortOrder: Int64($0.sortOrder)
            )
        }
        let queryArguments = favorites.map {
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
        return try await publish(to: destination) { engine in
            try await engine.publishTeamSavedQueries(
                teamId: destination.teamID,
                folders: folderArguments,
                queries: queryArguments
            )
        }
    }

    nonisolated static func connectionArguments(
        _ connections: [DatabaseConnection],
        exporter: ConnectionBundleExporter
    ) throws -> [TeamConnectionArg] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try connections.map { connection in
            let settings = try encoder.encode(exporter.teamShareableSettings(for: connection))
            guard let json = String(bytes: settings, encoding: .utf8) else {
                throw EncodingError.invalidValue(settings, .init(codingPath: [], debugDescription: "not UTF-8"))
            }
            return TeamConnectionArg(id: TeamLibraryID.of(connection.id), settingsJson: json)
        }
    }

    nonisolated static func result(of publish: TeamPublishInfo) throws(TeamLibraryPublishError) -> TeamLibraryPublishResult {
        if publish.conflicts > 0 {
            return .conflicts(Int(publish.conflicts))
        }
        if publish.unsent > 0 {
            let failure = publish.problem.map(TeamLibraryFailure.init(code:)) ?? .offline
            guard failure.isRetryable else { throw .failed(failure) }
            return .queued(failure)
        }
        return publish.edits == 0 ? .unchanged : .published(Int(publish.edits))
    }

    private func publish(
        to destination: TeamLibraryDestination,
        _ call: (any TeamLibraryEngine) async throws -> TeamPublishInfo
    ) async throws(TeamLibraryPublishError) -> TeamLibraryPublishResult {
        guard let session = destination.sessionID, session == shownSession, account.access.state.sessionID == session else {
            throw .failed(.signedOut)
        }
        // The roles come from the engine's first read of the teams, which may not have answered yet.
        if !writableTeams.contains(where: { $0.id == destination.teamID }) {
            await refresh()
            guard session == shownSession else { throw .failed(.signedOut) }
        }
        guard writableTeams.contains(where: { $0.id == destination.teamID }) else { throw .notWritable }
        publishing += 1
        status = .syncing
        defer {
            publishing -= 1
            if publishing == 0 {
                status = Self.status(of: lastStatuses)
            }
        }
        let answer: Result<TeamPublishInfo, TeamLibraryFailure>
        do {
            let engine = try await source.engine()
            guard session == shownSession else { throw TeamLibraryFailure.signedOut }
            answer = .success(try await call(engine))
        } catch {
            answer = .failure(error as? TeamLibraryFailure ?? TeamLibraryFailure(error))
        }
        await refresh()
        switch answer {
        case .success(let publish):
            return try Self.result(of: publish)
        case .failure(.writeForbidden):
            throw .notWritable
        case .failure(let failure):
            Self.logger.error("Publishing to the team library failed: \(failure.logName, privacy: .public)")
            throw .failed(failure)
        }
    }

    // MARK: - Sign Out

    // The edits Sign Out lists, read from the engine whatever shows, since a lost team_library hides the library but
    // keeps its edits. Nil when they could not be read.
    func unsentChanges() async -> [String]? {
        do {
            return try await source.engine().unsentTeamEdits().map(Self.name(of:))
        } catch {
            Self.logger.error("Listing the unsent Team Library edits failed: \(error.publicLogShape, privacy: .public)")
            return nil
        }
    }

    // Upload: one pass now. What the team has still not taken comes back, with why; nil when it could not be read.
    func upload() async -> (unsent: [String]?, failure: TeamLibraryFailure?) {
        var failure: TeamLibraryFailure?
        do {
            try await source.engine().syncNow(why: .person)
        } catch {
            failure = TeamLibraryFailure(error)
        }
        await refresh()
        guard let left = await unsentChanges() else { return (nil, failure ?? .unavailable) }
        guard !left.isEmpty else { return ([], nil) }
        let problem = lastStatuses.lazy.compactMap(\.problem).first.map(TeamLibraryFailure.init(code:))
        return (left, failure ?? problem ?? .offline)
    }

    // The sign-out, then the account's Team Library data, unsent edits included, verified gone, through the service of
    // the sign-in that ends: it still deletes after the sign-in ended. False when the delete failed, which keeps Team
    // Library off for that account until a later delete succeeds.
    func signOut(through signOut: @MainActor () async -> Void) async -> Bool {
        let held = owner != nil
        let engine = try? await source.engine()
        await signOut()
        guard let engine else { return !held }
        do {
            try await engine.deleteTeamLibraryData()
        } catch {
            Self.logger.error("Deleting the Team Library data failed: \(error.publicLogShape, privacy: .public)")
            return false
        }
        owner = nil
        ownerUnsent = []
        return true
    }

    nonisolated static func name(of edit: UnsentTeamEditInfo) -> String {
        let name = edit.name.flatMap { $0.isEmpty ? nil : $0 } ?? edit.item.id
        switch edit.state {
        case .pending, .waiting:
            return name
        case .conflict:
            return TeamLibraryUnsentChanges.conflicted(name)
        case .refused(let code):
            return TeamLibraryUnsentChanges.refused(name, because: TeamLibraryFailure(code: code))
        }
    }

    // MARK: - Sign-ins

    // The session ends for good the moment the account reports another sign-in, a sign-out of any kind, or a lost
    // team_library: nothing of it shows from here on.
    private func follow(_ state: AccountState) {
        guard state.isRestored else { return }
        let session = state.isSignedIn && FeatureAccess.resolve(.teamLibrary, state: state) != .notIncluded
            ? state.sessionID
            : nil
        if session != shownSession {
            generation += 1
            signIn += 1
            if shownSession != nil {
                ownerUnsent = unsent.map(Self.name(of:))
            }
            shownSession = session
            clear()
        }
        let isLaunch = !hasRestored
        hasRestored = true
        guard let next = TeamLibraryOwnerArg(state), next != owner else {
            Task { await refresh() }
            return
        }
        let discarded = owner == nil ? [] : ownerUnsent
        owner = next
        ownerUnsent = []
        signIn += 1
        let adopted = signIn
        let isProduction = state.server.isProduction
        Task {
            await adopt(next, discarding: discarded, restoredAtLaunch: isLaunch, isProduction: isProduction, signIn: adopted)
            await refresh()
        }
    }

    // A sign-in by another owner deletes what the last one left on this Mac, so it never reaches this account.
    private func adopt(
        _ next: TeamLibraryOwnerArg,
        discarding discarded: [String],
        restoredAtLaunch: Bool,
        isProduction: Bool,
        signIn adopted: Int
    ) async {
        do {
            try await source.deleteOtherOwners(keep: next)
            if !discarded.isEmpty {
                Self.logger.notice("Deleted \(discarded.count) Team Library edits another account left unsent")
                reportDiscarded(discarded)
            }
        } catch {
            Self.logger.error("Deleting another account's Team Library data failed: \(error.publicLogShape, privacy: .public)")
        }
        // Another sign-in meanwhile adopts its own owner; this one's earlier library waits for its next launch.
        guard adopted == signIn else { return }
        await importEarlierLibraries(for: next, restoredAtLaunch: restoredAtLaunch, isProduction: isProduction, signIn: adopted)
    }

    // The library 0.88 kept, once and only for the sign-in the core restores at launch, and what 0.89 knew of the
    // items this Mac published: handed to the core, which pushes them against the versions they were made on.
    private func importEarlierLibraries(
        for owner: TeamLibraryOwnerArg,
        restoredAtLaunch: Bool,
        isProduction: Bool,
        signIn adopted: Int
    ) async {
        // Nil when a file could not be read: everything stays for this owner's next launch.
        guard let teams = legacy.take(for: owner, restoredAtLaunch: restoredAtLaunch, isProduction: isProduction) else { return }
        guard !teams.isEmpty else {
            legacy.imported(for: owner)
            return
        }
        do {
            let engine = try await source.engine()
            guard adopted == signIn else { return }
            try await engine.importTeamLibrary(teams: teams)
            legacy.imported(for: owner)
        } catch {
            Self.logger.error("Importing the earlier Team Library failed: \(error.publicLogShape, privacy: .public)")
        }
    }

    private func clear() {
        if content != .empty {
            content = .empty
            AppEvents.shared.teamLibraryDidUpdate.send()
        }
        writableTeams = []
        unsent = []
        lastStatuses = []
        teamNames = [:]
        status = .idle
        conflicts.end()
    }

    private func commit(teams: [TeamLibraryTeamInfo], statuses: [TeamScopeStatusInfo], unsent: [UnsentTeamEditInfo]) {
        let next = TeamLibraryContent(teams: teams)
        if next != content {
            content = next
            AppEvents.shared.teamLibraryDidUpdate.send()
        }
        teamNames = Dictionary(
            teams.compactMap { team in team.name.map { (team.teamId, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        var writers: [String: String] = [:]
        for team in teams {
            for item in team.items {
                guard let writer = TeamLibraryContent.writer(of: item) else { continue }
                let key = TeamLibraryConflictsModel.writerKey(
                    scope: team.teamId, kind: TeamLibraryContent.wireKind(item.kind), id: item.id
                )
                writers[key] = writer
            }
        }
        conflicts.name(teamNames, writers: writers)
        let writable = teams.filter(\.canWrite)
            .map { TeamLibraryTeam(id: $0.teamId, name: $0.name ?? String(localized: "Team Library")) }
            .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        if writable != writableTeams {
            writableTeams = writable
        }
        if unsent != self.unsent {
            self.unsent = unsent
        }
        lastStatuses = statuses
        if publishing == 0 {
            status = Self.status(of: statuses)
        }
    }

    // A member that only reads is no failure; a team past its license's grace is, since its edits wait.
    nonisolated static func status(of statuses: [TeamScopeStatusInfo]) -> TeamLibrarySyncStatus {
        if let problem = statuses.lazy.compactMap(\.problem).first {
            return .failed(TeamLibraryFailure(code: problem))
        }
        if statuses.contains(where: \.pullOnly) {
            return .failed(.licenseExpired)
        }
        guard let last = statuses.compactMap(\.lastSyncedMs).max() else { return .idle }
        return .synced(Date(timeIntervalSince1970: TimeInterval(last) / 1_000))
    }
}
