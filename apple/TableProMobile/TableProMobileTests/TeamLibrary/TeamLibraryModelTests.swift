import Combine
import Foundation
import TableProFFI
@testable import TableProMobile
import TableProModels
import TableProTestSupport
import Testing

@MainActor
private final class Fixture {
    let engine = FakeTeamLibraryCalls()
    let changes = PassthroughSubject<Void, Never>()
    var session: String? = "session_a"
    var owner: TeamLibraryOwnerArg? = TeamLibraryOwnerArg(apiOrigin: "https://api.tablepro.app", accountId: "acct_a")
    var engineOpens = 0
    var kept: [TeamLibraryOwnerArg?] = []
    private(set) var library: TeamLibraryModel!

    init(deletesOtherOwners: Bool = true) {
        let deleteOtherOwners: (@MainActor (TeamLibraryOwnerArg?) async throws -> Void)? = deletesOtherOwners
            ? { [unowned self] keep in kept.append(keep) }
            : nil
        library = TeamLibraryModel(source: TeamLibrarySource(
            changes: changes.eraseToAnyPublisher(),
            engine: { [unowned self] in
                engineOpens += 1
                return engine
            },
            session: { [unowned self] in session },
            owner: { [unowned self] in owner },
            deleteOtherOwners: deleteOtherOwners
        ))
    }
}

@MainActor
struct TeamLibraryModelTests {
    @Test("The teams show sorted by name with their items, and the newest pass dates the status")
    func refreshShowsTheTeams() async {
        let fixture = Fixture()
        fixture.engine.update {
            $0.teams = [
                TeamLibraryFixtures.team("team_b", name: "Platform", items: [TeamLibraryFixtures.connection("C1", name: "Orders")]),
                TeamLibraryFixtures.team("team_a", name: "Analytics", canWrite: false),
            ]
            $0.statuses = [
                TeamScopeStatusInfo(teamId: "team_a", lastSyncedMs: 1_000, pullOnly: false, writeForbidden: true, problem: nil),
                TeamScopeStatusInfo(teamId: "team_b", lastSyncedMs: 5_000, pullOnly: false, writeForbidden: false, problem: nil),
            ]
        }

        await fixture.library.refresh()

        #expect(fixture.library.teams.map(\.name) == ["Analytics", "Platform"])
        #expect(fixture.library.writableTeams.map(\.id) == ["team_b"])
        #expect(fixture.library.team("team_b")?.connections.map(\.id) == ["c1"])
        #expect(fixture.library.status == .synced(Date(timeIntervalSince1970: 5)))
        #expect(fixture.library.isSignedIn)
    }

    @Test("Signed out, nothing shows and the engine is never opened")
    func signedOutReadsNothing() async {
        let fixture = Fixture()
        fixture.session = nil
        fixture.owner = nil

        await fixture.library.refresh()

        #expect(fixture.library.teams.isEmpty)
        #expect(!fixture.library.isSignedIn)
        #expect(fixture.engineOpens == 0)
    }

    @Test("Another sign-in clears what the last one showed before it reads its own")
    func signInChangeClearsTheTeams() async {
        let fixture = Fixture()
        fixture.engine.update { $0.teams = [TeamLibraryFixtures.team("team_a", name: "Analytics")] }
        await fixture.library.refresh()
        fixture.engine.fail("teamLibrary", with: FakeTeamLibraryCalls.failure("sync.network"))
        fixture.session = "session_b"

        await fixture.library.refresh()

        #expect(fixture.library.teams.isEmpty)
        #expect(fixture.library.status == .failed(.offline))
    }

    @Test("A publish picked under one sign-in never goes out under the next")
    func publishIsBoundToTheSignIn() async {
        let fixture = Fixture()
        fixture.engine.update { $0.teams = [TeamLibraryFixtures.team("team_a")] }
        await fixture.library.refresh()
        let destination = fixture.library.destination("team_a")
        fixture.session = "session_b"

        await #expect(throws: TeamLibraryProblem.signedOut) {
            _ = try await fixture.library.publishSavedQueries(SavedQueryContents(), to: destination)
        }
        #expect(fixture.engine.read { $0.publishedQueries.isEmpty })
    }

    @Test("A team this account only reads takes no publish")
    func readOnlyTeamRefusesThePublish() async {
        let fixture = Fixture()
        fixture.engine.update { $0.teams = [TeamLibraryFixtures.team("team_a", canWrite: false)] }
        await fixture.library.refresh()

        await #expect(throws: TeamLibraryProblem.writeForbidden) {
            _ = try await fixture.library.publishSavedQueries(SavedQueryContents(), to: fixture.library.destination("team_a"))
        }
    }

    @Test("Saved queries go up with their folders by lowercase id, and the result names what went")
    func publishesSavedQueries() async throws {
        let fixture = Fixture()
        fixture.engine.update {
            $0.teams = [TeamLibraryFixtures.team("team_a")]
            $0.publish = TeamPublishInfo(edits: 2, conflicts: 0, unsent: 0, problem: nil)
        }
        await fixture.library.refresh()
        let folder = SavedQueryFolder(name: "Reports")
        let query = SavedQuery(name: "Daily", query: "SELECT 1", keyword: "", folderId: folder.id)

        let result = try await fixture.library.publishSavedQueries(
            SavedQueryContents(queries: [query], folders: [folder]),
            to: fixture.library.destination("team_a")
        )

        #expect(result == .published(2))
        let sent = try #require(fixture.engine.read { $0.publishedQueries.first })
        #expect(sent.team == "team_a")
        #expect(sent.folders.map(\.id) == [folder.id.uuidString.lowercased()])
        #expect(sent.queries.first?.folderId == folder.id.uuidString.lowercased())
        #expect(sent.queries.first?.keyword == nil)
    }

    @Test("A publish the team holds for review reads as conflicts, a retryable one waits, and a refusal throws")
    func publishResults() throws {
        #expect(try TeamLibraryModel.result(of: TeamPublishInfo(edits: 0, conflicts: 2, unsent: 0, problem: nil)) == .conflicts(2))
        #expect(try TeamLibraryModel.result(of: TeamPublishInfo(edits: 0, conflicts: 0, unsent: 1, problem: "sync.network")) == .queued(.offline))
        #expect(try TeamLibraryModel.result(of: TeamPublishInfo(edits: 0, conflicts: 0, unsent: 0, problem: nil)) == .unchanged)
        #expect(throws: TeamLibraryProblem.licenseExpired) {
            _ = try TeamLibraryModel.result(of: TeamPublishInfo(edits: 0, conflicts: 0, unsent: 1, problem: "sync.license_expired"))
        }
    }

    @Test("Removing an item sends its reference to the team it was picked from")
    func removesItems() async throws {
        let fixture = Fixture()
        fixture.engine.update { $0.teams = [TeamLibraryFixtures.team("team_a")] }
        await fixture.library.refresh()
        let ref = TeamLibraryItemRef(kind: .connection, id: "c1")

        _ = try await fixture.library.remove([ref], from: fixture.library.destination("team_a"))

        #expect(fixture.engine.read { $0.removed.first?.team } == "team_a")
        #expect(fixture.engine.read { $0.removed.first?.items } == [ref])
    }

    @Test("Discarding one team's edits leaves the others, and the list reads again")
    func discardsOneTeam() async throws {
        let fixture = Fixture()
        fixture.engine.update {
            $0.teams = [TeamLibraryFixtures.team("team_a"), TeamLibraryFixtures.team("team_b")]
            $0.unsent = [
                UnsentTeamEditInfo(teamId: "team_a", item: TeamLibraryItemRef(kind: .query, id: "q1"), name: "Daily", deletion: false, state: .pending),
                UnsentTeamEditInfo(teamId: "team_b", item: TeamLibraryItemRef(kind: .query, id: "q2"), name: "Weekly", deletion: false, state: .pending),
            ]
        }
        await fixture.library.refresh()

        try await fixture.library.discardUnsent(team: "team_a", under: "session_a")

        #expect(fixture.engine.read { $0.discarded } == ["team_a"])
        #expect(fixture.library.unsent.map(\.teamId) == ["team_b"])
    }

    @Test("A discard picked under one sign-in never discards another account's edits")
    func discardOfAnEndedSignInIsRefused() async {
        let fixture = Fixture()
        await fixture.library.refresh()
        fixture.session = "session_b"

        await #expect(throws: TeamLibraryProblem.signedOut) {
            try await fixture.library.discardUnsent(team: nil, under: "session_a")
        }
        #expect(fixture.engine.read { $0.discarded }.isEmpty)
    }

    @Test("A sign-in by another owner deletes what the last one left and names its unsent edits")
    func anotherOwnerDeletesTheLastOnesData() async throws {
        let fixture = Fixture()
        fixture.engine.update {
            $0.teams = [TeamLibraryFixtures.team("team_a")]
            $0.unsent = [
                UnsentTeamEditInfo(teamId: "team_a", item: TeamLibraryItemRef(kind: .query, id: "q1"), name: "Daily", deletion: false, state: .pending),
            ]
        }
        await fixture.library.refresh()
        try await waitUntil { fixture.kept.count == 1 }
        let next = TeamLibraryOwnerArg(apiOrigin: "https://api.tablepro.app", accountId: "acct_b")
        fixture.session = "session_b"
        fixture.owner = next

        await fixture.library.refresh()

        try await waitUntil { fixture.kept.count == 2 }
        #expect(fixture.kept.last == next)
        try await waitUntil { fixture.library.discardedForAnotherOwner == ["Daily"] }
    }

    @Test("Without a core to ask, a new owner's sign-in deletes nothing and names nothing")
    func noCoreDeletesNothing() async {
        let fixture = Fixture(deletesOtherOwners: false)
        fixture.engine.update { $0.teams = [TeamLibraryFixtures.team("team_a")] }

        await fixture.library.refresh()

        #expect(fixture.kept.isEmpty)
        #expect(fixture.library.discardedForAnotherOwner.isEmpty)
    }

    @Test("A problem a team reports, or a lapsed license, is the status; otherwise the newest pass")
    func statusOfTheScopes() {
        let ok = TeamScopeStatusInfo(teamId: "team_a", lastSyncedMs: 2_000, pullOnly: false, writeForbidden: false, problem: nil)
        let lapsed = TeamScopeStatusInfo(teamId: "team_b", lastSyncedMs: 3_000, pullOnly: true, writeForbidden: false, problem: nil)
        let failing = TeamScopeStatusInfo(teamId: "team_c", lastSyncedMs: nil, pullOnly: false, writeForbidden: false, problem: "sync.rate_limited")

        #expect(TeamLibraryModel.status(of: []) == .idle)
        #expect(TeamLibraryModel.status(of: [ok]) == .synced(Date(timeIntervalSince1970: 2)))
        #expect(TeamLibraryModel.status(of: [ok, lapsed]) == .failed(.licenseExpired))
        #expect(TeamLibraryModel.status(of: [ok, failing]) == .failed(.rateLimited))
    }

    @Test("An unsent edit names what holds it")
    func unsentNames() {
        let item = TeamLibraryItemRef(kind: .connection, id: "c1")
        let conflict = UnsentTeamEditInfo(teamId: "team_a", item: item, name: "Orders", deletion: false, state: .conflict)
        let unnamed = UnsentTeamEditInfo(teamId: "team_a", item: item, name: nil, deletion: true, state: .pending)

        #expect(TeamLibraryModel.name(of: conflict) == String(format: String(localized: "%@ (in conflict)"), "Orders"))
        #expect(TeamLibraryModel.name(of: unnamed) == "c1")
        #expect(TeamLibraryModel.state(of: unnamed) == String(localized: "Removal waiting to send"))
    }

    @Test("Sign Out signs out the sign-in it was asked for, then deletes that account's Team Library data")
    func signOutDeletesAfterSigningOut() async {
        let fixture = Fixture()
        await fixture.library.refresh()
        var signedOut = 0

        let deleted = await fixture.library.signOut(session: "session_a") {
            signedOut += 1
            fixture.session = nil
        }

        #expect(deleted == true)
        #expect(signedOut == 1)
        #expect(fixture.engine.read { $0.deletes } == 1)
    }

    @Test("Another sign-in in place of the one asked about is neither signed out nor deleted")
    func signOutOfAnEndedSessionDoesNothing() async {
        let fixture = Fixture()
        fixture.session = "session_b"
        var signedOut = 0

        let deleted = await fixture.library.signOut(session: "session_a") { signedOut += 1 }

        #expect(deleted == nil)
        #expect(signedOut == 0)
        #expect(fixture.engine.read { $0.deletes } == 0)
    }

    @Test("A delete that fails after the sign-out says the data is still here")
    func failedDeleteIsReported() async {
        let fixture = Fixture()
        fixture.engine.fail("delete", with: FakeTeamLibraryCalls.failure("sync.network"))

        let deleted = await fixture.library.signOut(session: "session_a") { fixture.session = nil }

        #expect(deleted == false)
    }
}
