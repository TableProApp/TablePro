//
//  TeamLibraryTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProFFI
import TableProImport
import TableProTestSupport
import Testing

@MainActor
struct TeamLibraryTests {
    // MARK: - What shows

    @Test("Signed in, the library shows each team's connections and queries, the teams it writes, and the edits not taken")
    func showsWhatTheEngineHolds() async throws {
        let engine = FakeTeamLibraryEngine(teams: [TeamLibraryFixture.acme(items: [
            TeamLibraryFixture.connection("C1", name: "Prod"),
            TeamLibraryFixture.item(.folder, "F1", ["name": "Reports", "sort_order": 0]),
            TeamLibraryFixture.item(.query, "q1", ["name": "Orders", "query": "select 1", "folder_client_id": "f1", "sort_order": 0])
        ])])
        engine.hold(unsent: [TeamLibraryFixture.unsent("Orders")])
        let fixture = try await TeamLibraryFixture(engine: engine)

        try await fixture.start()
        try await waitUntil { fixture.library.notUploadedCount == 1 }

        let connections = fixture.library.content.connections.map { $0.id }
        let queries = fixture.library.content.queries.map { "\($0.name) in \($0.folderName ?? "-")" }
        #expect(connections == ["c1"])
        #expect(queries == ["Orders in Reports"])
        #expect(fixture.library.writableTeams == [TeamLibraryTeam(id: TeamLibraryFixture.team, name: "Acme")])
        #expect(fixture.library.teamName(of: TeamLibraryFixture.team) == "Acme")
    }

    @Test("A team query shows who last changed it, and its folder when the pull names no one; a conflict names that writer")
    func lastWriterShows() async throws {
        let engine = FakeTeamLibraryEngine(teams: [TeamLibraryFixture.acme(items: [
            TeamLibraryFixture.item(.folder, "f1", ["name": "Reports", "sort_order": 0]),
            TeamLibraryFixture.item(.query, "q1", ["name": "Orders", "query": "select 1", "sort_order": 0], updatedBy: "Grace Hopper"),
            TeamLibraryFixture.item(.query, "q2", ["name": "Signups", "query": "select 2", "folder_client_id": "f1", "sort_order": 1], updatedBy: "  ")
        ])])
        engine.set([TeamConflictFixture.conflict("q1")])
        let fixture = try await TeamLibraryFixture(engine: engine)

        try await fixture.start()
        try await waitUntil { fixture.library.content.queries.count == 2 && fixture.library.conflicts.conflicts.count == 1 }

        let details = fixture.library.content.queries.map { "\($0.name): \($0.detail ?? "-")" }
        #expect(details.sorted() == ["Orders: Grace Hopper", "Signups: Reports"])
        let conflict = try #require(fixture.library.conflicts.conflicts.first)
        #expect(fixture.library.conflicts.writer(of: conflict.record) == "Grace Hopper")
    }

    @Test("A connection whose SSH host ssh would refuse is dropped, and one that shows runs nothing by itself")
    func pulledConnectionsRunNothing() async throws {
        let engine = FakeTeamLibraryEngine(teams: [TeamLibraryFixture.acme(items: [
            TeamLibraryFixture.connection("c1", name: "Hostile", extra: [
                "sshConfig": ["enabled": true, "host": "-oProxyCommand=touch /tmp/x", "port": 22, "username": "a", "authMethod": "password"]
            ]),
            TeamLibraryFixture.connection("c2", name: "Prod", extra: [
                "startupCommands": "SET app.token = 'S3cret';",
                "tunnelCommand": ["method": "custom", "command": "nc evil 1"]
            ])
        ])])
        let fixture = try await TeamLibraryFixture(engine: engine)

        try await fixture.start()
        try await waitUntil { !fixture.library.content.connections.isEmpty }

        let names = fixture.library.content.connections.map { $0.settings.name }
        #expect(names == ["Prod"])
        let prod = try #require(fixture.library.content.connections.first)
        #expect(prod.settings.startupCommands == nil)
        #expect(prod.settings.tunnelCommand == nil)
    }

    @Test("A team that only reads shows its items, and is not a team to publish to")
    func readerTeamIsNotWritable() async throws {
        let engine = FakeTeamLibraryEngine(teams: [TeamLibraryFixture.acme(role: .member, canWrite: false, items: [
            TeamLibraryFixture.connection("c1", name: "Prod")
        ])])
        let fixture = try await TeamLibraryFixture(engine: engine)

        fixture.library.start()
        try await waitUntil { !fixture.library.content.connections.isEmpty }

        #expect(fixture.library.writableTeams.isEmpty)
        let destination = fixture.library.destination(TeamLibraryFixture.team)
        await #expect(throws: TeamLibraryPublishError.notWritable) {
            try await fixture.library.publishConnections([DatabaseConnection(name: "Prod")], to: destination)
        }
        #expect(engine.connectionPublishes.isEmpty)
    }

    @Test("A failed read keeps what shows and says why in the header")
    func failedReadKeepsContent() async throws {
        let engine = FakeTeamLibraryEngine(teams: [TeamLibraryFixture.acme(items: [TeamLibraryFixture.connection("c1", name: "Prod")])])
        let fixture = try await TeamLibraryFixture(engine: engine)
        try await fixture.start()

        engine.endSignIn()
        await fixture.library.refresh()

        let names = fixture.library.content.connections.map { $0.settings.name }
        #expect(names == ["Prod"])
        #expect(fixture.library.status == .failed(.signedOut))
    }

    @Test("A team past its license's grace reads as such, and the last sync's time shows otherwise")
    func statusFromTheTeams() {
        let synced = TeamScopeStatusInfo(teamId: "t1", lastSyncedMs: 1_700_000_000_000, pullOnly: false, writeForbidden: true, problem: nil)
        let lapsed = TeamScopeStatusInfo(teamId: "t2", lastSyncedMs: nil, pullOnly: true, writeForbidden: false, problem: nil)
        let offline = TeamScopeStatusInfo(teamId: "t3", lastSyncedMs: nil, pullOnly: false, writeForbidden: false, problem: "sync.network")

        #expect(TeamLibrary.status(of: [synced]) == .synced(Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(TeamLibrary.status(of: [synced, lapsed]) == .failed(.licenseExpired))
        #expect(TeamLibrary.status(of: [synced, offline]) == .failed(.offline))
        #expect(TeamLibrary.status(of: []) == .idle)
    }

    @Test("The engine's signal reads the library and its conflicts again")
    func signalRefreshes() async throws {
        let fixture = try await TeamLibraryFixture()
        try await fixture.start()

        fixture.engine.hold(teams: [TeamLibraryFixture.acme(items: [TeamLibraryFixture.connection("c9", name: "New")])])
        fixture.engine.set([TeamConflictFixture.conflict(fields: ["query"])])
        fixture.source.signals.send()

        try await waitUntil { fixture.library.content.connections.count == 1 && fixture.library.conflicts.conflicts.count == 1 }
    }

    // MARK: - Sign-ins

    @Test("An involuntary sign-out hides the library and its conflicts at once and keeps the data for the same account")
    func involuntarySignOutKeepsTheData() async throws {
        let engine = FakeTeamLibraryEngine(teams: [TeamLibraryFixture.acme(items: [TeamLibraryFixture.connection("c1", name: "Prod")])])
        engine.hold(unsent: [TeamLibraryFixture.unsent("Orders")])
        engine.set([TeamConflictFixture.conflict()])
        let fixture = try await TeamLibraryFixture(engine: engine)
        try await fixture.start()
        try await waitUntil { fixture.library.conflicts.conflicts.count == 1 }

        try await fixture.refuseRefresh()
        try await waitUntil { fixture.library.content == .empty }

        #expect(fixture.library.writableTeams.isEmpty)
        #expect(fixture.library.notUploadedCount == 0)
        #expect(fixture.library.conflicts.conflicts.isEmpty)
        #expect(engine.deletes == 0)
        #expect(engine.discards.isEmpty)

        try await fixture.account.signIn()
        try await waitUntil { fixture.library.notUploadedCount == 1 }
        #expect(fixture.source.keptOwners.last == TeamLibraryFixture.owner)
        #expect(fixture.discarded.isEmpty)
    }

    @Test("Another account's sign-in deletes what the last one left on this Mac and names the edits that went")
    func anotherAccountDeletesTheLastOne() async throws {
        let engine = FakeTeamLibraryEngine()
        engine.hold(unsent: [TeamLibraryFixture.unsent("Orders")])
        let fixture = try await TeamLibraryFixture(engine: engine)
        try await fixture.start()
        try await waitUntil { fixture.library.notUploadedCount == 1 }

        try await fixture.refuseRefresh()
        await fixture.account.server.set { $0.accountID = "acct_other" }
        engine.hold(unsent: [])
        try await fixture.account.signIn()

        try await waitUntil { fixture.discarded == [["Orders"]] }
        let other = TeamLibraryOwnerArg(apiOrigin: TeamLibraryFixture.owner.apiOrigin, accountId: "acct_other")
        #expect(fixture.source.keptOwners == [TeamLibraryFixture.owner, other])
    }

    @Test("Losing team_library hides the library like an involuntary sign-out")
    func lostFeatureHidesTheLibrary() async throws {
        let engine = FakeTeamLibraryEngine(teams: [TeamLibraryFixture.acme(items: [TeamLibraryFixture.connection("c1", name: "Prod")])])
        let fixture = try await TeamLibraryFixture(engine: engine)
        try await fixture.start()

        await fixture.account.server.set { $0.features = [] }
        _ = await fixture.account.services.refreshEntitlement()

        try await waitUntil { fixture.library.content == .empty }
        #expect(engine.deletes == 0)
    }

    @Test("A read that answers after the sign-in ended shows nothing of it")
    func lateReadShowsNothing() async throws {
        let engine = FakeTeamLibraryEngine()
        let fixture = try await TeamLibraryFixture(engine: engine)
        try await fixture.start()

        let gate = AsyncGate()
        engine.hold(teams: [TeamLibraryFixture.acme(items: [TeamLibraryFixture.connection("c1", name: "Late")])])
        engine.holdNextTeamRead(at: gate)
        let late = Task { await fixture.library.refresh() }
        await gate.arrived(1)
        try await fixture.refuseRefresh()
        try await waitUntil { fixture.library.writableTeams.isEmpty }
        await gate.open()
        await late.value

        #expect(fixture.library.content == .empty)
    }

    @Test("Quitting asks nothing and drops nothing: the next launch lists the same unsent edits")
    func quitKeepsTheUnsentEdits() async throws {
        let engine = FakeTeamLibraryEngine()
        engine.hold(unsent: [TeamLibraryFixture.unsent("Orders")])
        let fixture = try await TeamLibraryFixture(engine: engine)
        try await fixture.start()
        try await waitUntil { fixture.library.notUploadedCount == 1 }

        fixture.relaunch()
        try await fixture.start()

        try await waitUntil { fixture.library.notUploadedCount == 1 }
        #expect(engine.discards.isEmpty)
        #expect(engine.deletes == 0)
    }

    // MARK: - Publishing

    @Test("Publishing sends each connection under its lowercase id, its settings without passwords or commands")
    func publishSendsConnections() async throws {
        let fixture = try await TeamLibraryFixture()
        try await fixture.start()
        var prod = DatabaseConnection(name: "Prod", type: .postgresql)
        prod.startupCommands = "SET app.token = 'S3cret';"
        let staging = DatabaseConnection(name: "Staging")

        let result = try await fixture.library.publishConnections(
            [prod, staging],
            to: fixture.library.destination(TeamLibraryFixture.team)
        )

        #expect(result == .published(1))
        let sent = try #require(fixture.engine.connectionPublishes.first)
        #expect(sent.team == TeamLibraryFixture.team)
        let ids = sent.connections.map { $0.id }
        #expect(ids == [prod.id, staging.id].map { $0.uuidString.lowercased() })
        let settings = sent.connections.compactMap { TeamLibraryFixture.object($0.settingsJson) }
        let names = settings.map { $0["name"] as? String }
        #expect(names == ["Prod", "Staging"])
        #expect(settings.allSatisfy { $0["startupCommands"] == nil && $0["tunnelCommand"] == nil && $0["password"] == nil })
    }

    @Test("Publishing saved queries sends every query and folder this Mac holds under lowercase ids")
    func publishSendsSavedQueries() async throws {
        let fixture = try await TeamLibraryFixture()
        try await fixture.start()
        let folder = SQLFavoriteFolder(id: UUID(), name: "Reports", parentId: nil, connectionId: nil, sortOrder: 2, createdAt: Date(), updatedAt: Date())
        let orders = TeamLibraryFixture.favorite(name: "Orders", folderID: folder.id)

        _ = try await fixture.library.publishSavedQueries(
            favorites: [orders],
            folders: [folder],
            to: fixture.library.destination(TeamLibraryFixture.team)
        )

        let sent = try #require(fixture.engine.queryPublishes.first)
        #expect(sent.folders == [TeamFolderArg(id: folder.id.uuidString.lowercased(), name: "Reports", parentId: nil, sortOrder: 2)])
        #expect(sent.queries == [TeamQueryArg(
            id: orders.id.uuidString.lowercased(), name: "Orders", query: "SELECT 1", keyword: nil,
            folderId: folder.id.uuidString.lowercased(), connectionId: nil, sortOrder: 0
        )])
    }

    @Test("A publish reads as conflicts, queued for a problem that passes, refused for one that does not, or unchanged")
    func publishResults() throws {
        #expect(try TeamLibrary.result(of: TeamPublishInfo(edits: 2, conflicts: 1, unsent: 1, problem: nil)) == .conflicts(1))
        #expect(try TeamLibrary.result(of: TeamPublishInfo(edits: 2, conflicts: 0, unsent: 2, problem: "sync.network")) == .queued(.offline))
        #expect(try TeamLibrary.result(of: TeamPublishInfo(edits: 0, conflicts: 0, unsent: 0, problem: nil)) == .unchanged)
        #expect(try TeamLibrary.result(of: TeamPublishInfo(edits: 3, conflicts: 0, unsent: 0, problem: nil)) == .published(3))
        #expect(throws: TeamLibraryPublishError.failed(.licenseExpired)) {
            try TeamLibrary.result(of: TeamPublishInfo(edits: 1, conflicts: 0, unsent: 1, problem: "sync.team_library.pull_only"))
        }
    }

    @Test("A publish the engine refuses for the role reads as not writable, and one after the sign-in ended as signed out")
    func publishRefusals() async throws {
        let fixture = try await TeamLibraryFixture()
        try await fixture.start()
        let destination = fixture.library.destination(TeamLibraryFixture.team)

        fixture.engine.answerPublishes(with: .failure(TeamConflictFixture.failure("sync.team_library.not_writable")))
        await #expect(throws: TeamLibraryPublishError.notWritable) {
            try await fixture.library.publishConnections([DatabaseConnection(name: "Prod")], to: destination)
        }

        fixture.engine.endSignIn()
        await #expect(throws: TeamLibraryPublishError.failed(.signedOut)) {
            try await fixture.library.publishConnections([DatabaseConnection(name: "Prod")], to: destination)
        }
    }

    // MARK: - Sign Out

    @Test("Upload runs a pass and lists what the team still has not taken, with why")
    func uploadListsWhatIsLeft() async throws {
        let engine = FakeTeamLibraryEngine()
        engine.hold(unsent: [
            TeamLibraryFixture.unsent("Orders"),
            TeamLibraryFixture.unsent("Huge", state: .refused(code: "too_large"))
        ])
        let fixture = try await TeamLibraryFixture(engine: engine)
        try await fixture.start()

        let answer = await fixture.library.upload()

        #expect(engine.passes == 1)
        #expect(answer.unsent == [TeamLibraryUnsentChanges.refused("Huge", because: .refused)])
        #expect(answer.failure != nil)
    }

    @Test("Sign Out lists the edits the engine holds even when a lost team_library hides the library")
    func signOutListsHiddenEdits() async throws {
        let engine = FakeTeamLibraryEngine()
        engine.hold(unsent: [TeamLibraryFixture.unsent("Orders")])
        let fixture = try await TeamLibraryFixture(engine: engine)
        try await fixture.start()
        await fixture.account.server.set { $0.features = [] }
        _ = await fixture.account.services.refreshEntitlement()
        try await waitUntil { fixture.library.writableTeams.isEmpty }

        #expect(await fixture.library.unsentChanges() == ["Orders"])

        engine.failUnsentReads(with: TeamConflictFixture.failure("sync.state.io"))
        #expect(await fixture.library.unsentChanges() == nil)
    }

    @Test("Sign Out deletes the account's Team Library data once signed out, through the service of that sign-in")
    func signOutDeletesTheData() async throws {
        let engine = FakeTeamLibraryEngine()
        let fixture = try await TeamLibraryFixture(engine: engine)
        try await fixture.start()

        let deleted = await fixture.library.signOut { [services = fixture.account.services] in
            engine.endSignIn()
            await services.signOut()
        }

        #expect(deleted)
        #expect(engine.deletes == 1)
        #expect(!fixture.account.access.state.isSignedIn)
    }

    @Test("A delete that fails after Sign Out says so")
    func failedDeleteSaysSo() async throws {
        let engine = FakeTeamLibraryEngine()
        engine.failDeletes(with: TeamConflictFixture.failure("sync.team_library.delete_failed"))
        let fixture = try await TeamLibraryFixture(engine: engine)
        try await fixture.start()

        let deleted = await fixture.library.signOut { [services = fixture.account.services] in await services.signOut() }

        #expect(!deleted)
    }

    @Test("Each unsent edit is named, with why when the team refused it or changed it since")
    func unsentNames() {
        #expect(TeamLibrary.name(of: TeamLibraryFixture.unsent("Orders")) == "Orders")
        #expect(TeamLibrary.name(of: TeamLibraryFixture.unsent("Orders", state: .conflict)) == TeamLibraryUnsentChanges.conflicted("Orders"))
        #expect(TeamLibrary.name(of: TeamLibraryFixture.unsent("Orders", state: .refused(code: "role")))
            == TeamLibraryUnsentChanges.refused("Orders", because: .writeForbidden))
        let unnamed = UnsentTeamEditInfo(
            teamId: TeamLibraryFixture.team, item: TeamLibraryItemRef(kind: .folder, id: "f1"), name: nil, deletion: true, state: .pending
        )
        #expect(TeamLibrary.name(of: unnamed) == "f1")
    }
}
