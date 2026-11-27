//
//  TeamLibraryFixture.swift
//  TableProTests
//

import Combine
import Foundation
@testable import TablePro
import TableProFFI
import TableProTestSupport

// The core's Team Library as one sign-in's sync service holds it. Once the sign-in it was opened with ends, it refuses
// what reads or sends that sign-in's data, and still lists, discards, reports and deletes.
final class FakeTeamLibraryEngine: FakeTeamConflictEngine, TeamLibraryEngine, @unchecked Sendable {
    private let state = NSLock()
    private var teams: [TeamLibraryTeamInfo]
    private var statuses: [TeamScopeStatusInfo] = []
    private var unsentEdits: [UnsentTeamEditInfo] = []
    private var publishAnswer: Result<TeamPublishInfo, CoreError> = .success(TeamPublishInfo(edits: 1, conflicts: 0, unsent: 0, problem: nil))
    private var syncAnswer: CoreError?
    private var deleteFailure: CoreError?
    private var importFailure: CoreError?
    private var unsentFailure: CoreError?
    private var ended = false
    private var teamReadGate: AsyncGate?
    private var passGate: AsyncGate?
    private(set) var connectionPublishes: [(team: String, connections: [TeamConnectionArg])] = []
    private(set) var queryPublishes: [(team: String, folders: [TeamFolderArg], queries: [TeamQueryArg])] = []
    private(set) var discards: [String?] = []
    private(set) var deletes = 0
    private(set) var imports: [[TeamLibraryImportArg]] = []
    private(set) var passes = 0

    init(teams: [TeamLibraryTeamInfo] = [TeamLibraryFixture.acme()]) {
        self.teams = teams
        super.init()
    }

    func hold(teams: [TeamLibraryTeamInfo]? = nil, statuses: [TeamScopeStatusInfo]? = nil, unsent: [UnsentTeamEditInfo]? = nil) {
        state.withLock {
            if let teams { self.teams = teams }
            if let statuses { self.statuses = statuses }
            if let unsent { unsentEdits = unsent }
        }
    }

    func answerPublishes(with answer: Result<TeamPublishInfo, CoreError>) {
        state.withLock { publishAnswer = answer }
    }

    func answerPasses(with error: CoreError?) {
        state.withLock { syncAnswer = error }
    }

    func failDeletes(with error: CoreError?) {
        state.withLock { deleteFailure = error }
    }

    func failImports(with error: CoreError?) {
        state.withLock { importFailure = error }
    }

    func failUnsentReads(with error: CoreError?) {
        state.withLock { unsentFailure = error }
    }

    // The next pass waits at the gate before it answers.
    func holdNextPass(at gate: AsyncGate) {
        state.withLock { passGate = gate }
    }

    // The sign-in the service was opened with ended.
    func endSignIn() {
        state.withLock { ended = true }
    }

    // The next read of the teams waits at the gate after it took what it answers.
    func holdNextTeamRead(at gate: AsyncGate) {
        state.withLock { teamReadGate = gate }
    }

    private func signedIn() throws {
        if state.withLock({ ended }) {
            throw TeamConflictFixture.failure("sync.team_library.signed_in_changed")
        }
    }

    func teamLibrary() async throws -> [TeamLibraryTeamInfo] {
        try signedIn()
        let (answer, gate) = state.withLock { () -> ([TeamLibraryTeamInfo], AsyncGate?) in
            let gate = teamReadGate
            teamReadGate = nil
            return (teams, gate)
        }
        await gate?.wait()
        return answer
    }

    func publishTeamConnections(teamId: String, connections: [TeamConnectionArg]) async throws -> TeamPublishInfo {
        try signedIn()
        return try state.withLock {
            connectionPublishes.append((teamId, connections))
            return try publishAnswer.get()
        }
    }

    func publishTeamSavedQueries(teamId: String, folders: [TeamFolderArg], queries: [TeamQueryArg]) async throws -> TeamPublishInfo {
        try signedIn()
        return try state.withLock {
            queryPublishes.append((teamId, folders, queries))
            return try publishAnswer.get()
        }
    }

    func unsentTeamEdits() async throws -> [UnsentTeamEditInfo] {
        try state.withLock {
            if let unsentFailure { throw unsentFailure }
            return unsentEdits
        }
    }

    func discardTeamEdits(teamId: String?) async throws {
        state.withLock {
            discards.append(teamId)
            unsentEdits.removeAll { teamId == nil || $0.teamId == teamId }
        }
    }

    func deleteTeamLibraryData() async throws {
        try state.withLock {
            if let deleteFailure { throw deleteFailure }
            deletes += 1
            unsentEdits = []
            teams = []
        }
    }

    func teamScopeStatus() async throws -> [TeamScopeStatusInfo] {
        state.withLock { statuses }
    }

    func importTeamLibrary(teams: [TeamLibraryImportArg]) async throws {
        try signedIn()
        try state.withLock {
            if let importFailure { throw importFailure }
            imports.append(teams)
        }
    }

    // A pass the team took everything in, unless told otherwise.
    func syncNow(why: PassReasonTag) async throws {
        let gate = state.withLock { () -> AsyncGate? in
            let gate = passGate
            passGate = nil
            return gate
        }
        await gate?.wait()
        try state.withLock {
            passes += 1
            if let syncAnswer { throw syncAnswer }
            unsentEdits.removeAll { edit in
                if case .refused = edit.state { return false }
                return true
            }
        }
    }
}

@MainActor
final class FakeTeamLibrarySource: TeamLibraryEngineSource {
    var current: FakeTeamLibraryEngine
    let signals = PassthroughSubject<Void, Never>()
    private(set) var keptOwners: [TeamLibraryOwnerArg?] = []
    var deleteOthersFailure: CoreError?
    // The next delete of other owners' data waits at the gate.
    var deleteOthersGate: AsyncGate?

    init(_ engine: FakeTeamLibraryEngine) {
        current = engine
    }

    var changes: AnyPublisher<Void, Never> {
        signals.eraseToAnyPublisher()
    }

    func engine() async throws -> any TeamLibraryEngine {
        current
    }

    func deleteOtherOwners(keep: TeamLibraryOwnerArg?) async throws {
        keptOwners.append(keep)
        if let gate = deleteOthersGate {
            deleteOthersGate = nil
            await gate.wait()
        }
        if let deleteOthersFailure { throw deleteOthersFailure }
    }
}

// A signed-in account with the team_library feature over a fake engine, with earlier builds' folders in a temporary one.
@MainActor
final class TeamLibraryFixture {
    nonisolated static let team = "team_01jbvh7pn9e3sv4bzq4rqk4kzh"
    nonisolated static let owner = TeamLibraryOwnerArg(apiOrigin: AccountServer.production.apiOrigin.absoluteString, accountId: "acct_test")

    let account: AccountFixture
    let engine: FakeTeamLibraryEngine
    let source: FakeTeamLibrarySource
    let defaults: EphemeralDefaults
    let directory: URL
    let legacy: TeamLibraryLegacyImport
    private(set) var discarded: [[String]] = []
    private(set) var library: TeamLibrary!

    init(engine: FakeTeamLibraryEngine = FakeTeamLibraryEngine(), signedIn: Bool = true) async throws {
        account = try AccountFixture()
        await account.server.set { $0.features = ["team_library"] }
        if signedIn {
            try await account.signIn()
        }
        self.engine = engine
        source = FakeTeamLibrarySource(engine)
        defaults = try EphemeralDefaults()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TeamLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        legacy = TeamLibraryLegacyImport(
            flatDirectory: directory.appendingPathComponent("TeamLibrary", isDirectory: true),
            legacyFile: directory.appendingPathComponent("team_library.json"),
            cacheRoot: directory.appendingPathComponent("TeamLibraryCache", isDirectory: true),
            defaults: defaults.defaults
        )
        library = makeLibrary()
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    // A new launch over the same engine and folders.
    func relaunch() {
        library = makeLibrary()
    }

    private func makeLibrary() -> TeamLibrary {
        TeamLibrary(source: source, account: account.services, legacy: legacy) { [weak self] in
            self?.discarded.append($0)
        }
    }

    // Started; signed in, until it shows the engine's teams this account writes.
    func start() async throws {
        library.start()
        guard account.access.state.isSignedIn else { return }
        try await waitUntil { !self.library.writableTeams.isEmpty }
    }

    func refuseRefresh() async throws {
        await account.server.set { $0.refusesRefresh = true }
        await account.services.refreshEntitlement()
        try await waitUntil { !self.account.access.state.isSignedIn }
        await account.server.set { $0.refusesRefresh = false }
    }

    // MARK: - Records

    nonisolated static func acme(role: TeamRoleTag? = .owner, canWrite: Bool = true, items: [TeamLibraryItemInfo] = []) -> TeamLibraryTeamInfo {
        TeamLibraryTeamInfo(teamId: team, name: "Acme", role: role, canWrite: canWrite, items: items)
    }

    nonisolated static func item(
        _ kind: TeamLibraryKindTag,
        _ id: String,
        _ fields: [String: Any],
        updatedBy: String? = nil
    ) -> TeamLibraryItemInfo {
        TeamLibraryItemInfo(kind: kind, id: id, fieldsJson: json(fields), updatedBy: updatedBy, updatedAtMs: nil)
    }

    nonisolated static func connection(_ id: String, name: String, extra: [String: Any] = [:]) -> TeamLibraryItemInfo {
        var fields: [String: Any] = ["name": name, "host": "db.internal", "port": 5_432, "database": "app", "username": "app", "type": "PostgreSQL"]
        fields.merge(extra) { _, new in new }
        return item(.connection, id, fields)
    }

    nonisolated static func unsent(_ name: String, state: UnsentTeamEditTag = .pending) -> UnsentTeamEditInfo {
        UnsentTeamEditInfo(
            teamId: team,
            item: TeamLibraryItemRef(kind: .query, id: name.lowercased()),
            name: name,
            deletion: false,
            state: state
        )
    }

    nonisolated static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated static func object(_ json: String?) -> [String: Any]? {
        json.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }

    nonisolated static func favorite(name: String, folderID: UUID? = nil) -> SQLFavorite {
        SQLFavorite(
            id: UUID(), name: name, query: "SELECT 1", keyword: nil, folderId: folderID, connectionId: nil,
            sortOrder: 0, createdAt: Date(), updatedAt: Date()
        )
    }
}
