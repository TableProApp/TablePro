import Combine
import Foundation
import TableProFFI

// The core engine's team conflicts (core ADR 0054, the `conflicts` table; 0051, Conflict rules), so the conflict
// sheet's tests run over a fake.
nonisolated protocol TeamConflictCalls: AnyObject, Sendable {
    func conflicts() async throws -> [TeamConflictInfo]
    func resolveConflict(record: SyncRecordRef, digest: String, keep: ConflictChoiceTag) async throws
}

// Team Library on the core engine (core ADR 0054, team scopes always use the service). Every call is bound to the
// sign-in the service opened with and refused once it ends; the unsent edits, their discard, the status and the delete
// still answer after, as a sign-out needs.
nonisolated protocol TeamLibraryCalls: TeamConflictCalls {
    func teamLibrary() async throws -> [TeamLibraryTeamInfo]
    func publishTeamConnections(teamId: String, connections: [TeamConnectionArg]) async throws -> TeamPublishInfo
    func publishTeamSavedQueries(
        teamId: String,
        folders: [TeamFolderArg],
        queries: [TeamQueryArg]
    ) async throws -> TeamPublishInfo
    func removeTeamItems(teamId: String, items: [TeamLibraryItemRef]) async throws -> TeamPublishInfo
    func unsentTeamEdits() async throws -> [UnsentTeamEditInfo]
    func discardTeamEdits(teamId: String?) async throws
    func deleteTeamLibraryData() async throws
    func teamScopeStatus() async throws -> [TeamScopeStatusInfo]
    func syncNow(why: PassReasonTag) async throws
}

extension SyncService: TeamLibraryCalls {}

// Where the Team Library reaches the engine and the account it reads for.
@MainActor
struct TeamLibrarySource {
    // The engine's status, a key change and a sign-in that opened the service again.
    var changes: AnyPublisher<Void, Never>
    var engine: @MainActor () async throws -> any TeamLibraryCalls
    // The sign-in shown now; nil while signed out.
    var session: @MainActor () -> String?
    // The server's API origin and the account on it, the owner a Team Library store belongs to.
    var owner: @MainActor () -> TeamLibraryOwnerArg?
    // Every owner's Team Library data on this device but `keep`'s, verified gone. Nil where the app has no core to ask.
    var deleteOtherOwners: (@MainActor (TeamLibraryOwnerArg?) async throws -> Void)?
}

nonisolated struct TeamLibraryUnavailable: Error {}

extension TeamLibrarySource {
    static func live(
        host: IOSSyncEngineHost,
        account: AccountModel,
        deleteOtherOwners: (@MainActor (TeamLibraryOwnerArg?) async throws -> Void)? = nil
    ) -> TeamLibrarySource {
        TeamLibrarySource(
            changes: host.statusChanges.merge(with: host.reopened, host.keyChanges, host.signInChanges).eraseToAnyPublisher(),
            engine: {
                guard let engine = try await host.accountScopesEngine() as? any TeamLibraryCalls else {
                    throw TeamLibraryUnavailable()
                }
                return engine
            },
            session: { account.isSignedIn ? account.snapshot.sessionID : nil },
            owner: {
                guard account.isSignedIn, let accountID = account.snapshot.accountID else { return nil }
                return TeamLibraryOwnerArg(apiOrigin: account.server.apiOrigin.absoluteString, accountId: accountID)
            },
            deleteOtherOwners: deleteOtherOwners
        )
    }
}
