//
//  TeamLibraryEngine.swift
//  TablePro
//

import Combine
import Foundation
import TableProFFI

// Team Library on the core engine (core ADR 0054, team scopes always use the service), so the app's tests run over a
// fake engine. Every call is bound to the sign-in the service opened with and refused once it ends; the unsent edits,
// their discard, the status and the delete still answer after, as a sign-out needs. Each call names the owner it is
// for, and the engine refuses one for another owner with `sync.team_library.other_owner`.
nonisolated protocol TeamLibraryEngine: TeamConflictEngine {
    func teamLibraryOwner() -> TeamLibraryOwnerArg?
    func teamLibrary(expectedOwner: TeamLibraryOwnerArg) async throws -> [TeamLibraryTeamInfo]
    func publishTeamConnections(
        expectedOwner: TeamLibraryOwnerArg,
        teamId: String,
        connections: [LibraryConnectionRecord]
    ) async throws -> TeamPublishInfo
    func publishTeamSavedQueries(
        expectedOwner: TeamLibraryOwnerArg,
        teamId: String,
        folders: [TeamFolderArg],
        queries: [TeamQueryArg]
    ) async throws -> TeamPublishInfo
    func unsentTeamEdits(expectedOwner: TeamLibraryOwnerArg) async throws -> [UnsentTeamEditInfo]
    func discardTeamEdits(expectedOwner: TeamLibraryOwnerArg, teamId: String?) async throws
    func deleteTeamLibraryData(expectedOwner: TeamLibraryOwnerArg) async throws
    func teamScopeStatus(expectedOwner: TeamLibraryOwnerArg) async throws -> [TeamScopeStatusInfo]
    func importTeamLibrary(expectedOwner: TeamLibraryOwnerArg, teams: [TeamLibraryImportArg]) async throws
    func syncNow(why: PassReasonTag) async throws
}

extension SyncService: TeamLibraryEngine {}

// Where the app reaches the engine. A Team Library owner is the server's API origin and the account on it.
@MainActor
internal protocol TeamLibraryEngineSource {
    var changes: AnyPublisher<Void, Never> { get }
    func engine() async throws -> any TeamLibraryEngine
    // Every owner's Team Library data on this Mac but `keep`'s, verified gone.
    func deleteOtherOwners(keep: TeamLibraryOwnerArg?) async throws
}

internal struct TeamLibraryUnavailable: Error {}

@MainActor
internal struct LiveTeamLibraryEngineSource: TeamLibraryEngineSource {
    let host: SyncEngineHost
    let core: @MainActor () async throws -> Core

    // A sign-in change opens the service again, whose teams are read anew.
    var changes: AnyPublisher<Void, Never> {
        host.statusChanges.merge(with: host.reopened).eraseToAnyPublisher()
    }

    func engine() async throws -> any TeamLibraryEngine {
        guard let engine = try await host.accountScopesEngine() as? any TeamLibraryEngine else {
            throw TeamLibraryUnavailable()
        }
        return engine
    }

    func deleteOtherOwners(keep: TeamLibraryOwnerArg?) async throws {
        try await core().deleteOtherTeamLibraryData(keep: keep)
    }
}

extension TeamLibraryOwnerArg {
    // The owner of the sign-in this state shows, or none while signed out.
    init?(_ state: AccountState) {
        guard state.isSignedIn, let accountID = state.entitlement?.accountID else { return nil }
        self.init(apiOrigin: state.server.apiOrigin.absoluteString, accountId: accountID)
    }
}
