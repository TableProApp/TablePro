//
//  ConnectionEditorStoreTeamCopyTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProFFI
import TableProTestSupport
import Testing

@MainActor
struct ConnectionEditorStoreTeamCopyTests {
    private func teamCopy(
        role: TeamRoleTag = .editor,
        canWrite: Bool = true,
        secrets: [TeamSecretArg] = [TeamSecretArg(kind: "password", value: "s3cret")]
    ) async throws -> (TeamLibraryFixture, TeamLibraryConnection) {
        let engine = FakeTeamLibraryEngine(teams: [TeamLibraryFixture.acme(role: role, canWrite: canWrite, items: [
            TeamLibraryFixture.connection("c1", name: "Prod")
        ])])
        engine.hold(secrets: secrets, for: "c1")
        let fixture = try await TeamLibraryFixture(engine: engine)
        fixture.library.start()
        try await waitUntil { !fixture.library.content.connections.isEmpty }
        return (fixture, try #require(fixture.library.content.connections.first))
    }

    private func target(
        _ original: TeamLibraryConnection,
        secrets: [ConnectionSecretItem: String]?,
        in team: TeamLibraryFixture
    ) -> TeamCopyTarget {
        TeamCopyTarget(original: original, secrets: secrets, destination: team.library.destination(original.teamID))
    }

    private func save(_ store: ConnectionEditorStore, _ edit: (inout ConnectionDraft) -> Void) async throws {
        var dismissed = false
        store.dismissAction = { dismissed = true }
        store.update(edit)
        #expect(store.save() == .failure(.teamPublishInFlight))
        try await waitUntil { dismissed }
    }

    private func secrets(_ edit: (team: String, connection: LibraryConnectionRecord, secrets: [TeamSecretArg]?)?) -> [String]? {
        edit?.secrets?.map { "\($0.kind)=\($0.value)" }.sorted()
    }

    @Test("A team's copy opens with the password its envelopes hold, and is never one the library can delete")
    func opensWithTheTeamsPassword() async throws {
        let (team, original) = try await teamCopy()
        let editor = try ConnectionEditorStoreFixture()

        let store = editor.makeStore(.editTeamCopy(target(original, secrets: [.password: "s3cret"], in: team)), teamLibrary: team.library)

        #expect(store.draft.credentials.password == "s3cret")
        #expect(store.draft.host == "db.internal")
        #expect(!store.isNew)
        #expect(!store.canDelete)
        #expect(!store.isRecordMissing)
        #expect(editor.storage.loadConnections().isEmpty)
    }

    @Test("A port change publishes under the team's id with the team's secrets sealed again, and writes nothing here")
    func movedEditCarriesTheTeamsSecrets() async throws {
        let (team, original) = try await teamCopy()
        let editor = try ConnectionEditorStoreFixture()
        let store = editor.makeStore(.editTeamCopy(target(original, secrets: [.password: "s3cret"], in: team)), teamLibrary: team.library)

        try await save(store) { $0.portText = "5433" }

        let edit = try #require(team.engine.connectionEdits.first)
        #expect(edit.connection.connection.id == "c1")
        #expect(edit.connection.connection.port == 5_433)
        #expect(secrets(edit) == ["password=s3cret"])
        #expect(editor.storage.loadConnections().isEmpty)
        #expect(editor.secretKeys(for: original.connection.id).isEmpty)
        #expect(!store.isPublishingTeamCopy)
    }

    @Test("A password a teammate rotated after the form opened is the one sealed again, never the one the form read")
    func rotatedPasswordIsKept() async throws {
        let (team, original) = try await teamCopy()
        let editor = try ConnectionEditorStoreFixture()
        let store = editor.makeStore(.editTeamCopy(target(original, secrets: [.password: "s3cret"], in: team)), teamLibrary: team.library)
        team.engine.hold(secrets: [TeamSecretArg(kind: "password", value: "rotated")], for: "c1")

        try await save(store) { $0.portText = "5433" }

        #expect(secrets(team.engine.connectionEdits.first) == ["password=rotated"])
    }

    @Test("A typed password replaces the team's, and a cleared one removes it")
    func typedPasswordWins() async throws {
        let (team, original) = try await teamCopy(secrets: [
            TeamSecretArg(kind: "password", value: "s3cret"),
            TeamSecretArg(kind: "ssh_password", value: "tunnel")
        ])
        let editor = try ConnectionEditorStoreFixture()
        let store = editor.makeStore(
            .editTeamCopy(target(original, secrets: [.password: "s3cret", .sshPassword: "tunnel"], in: team)),
            teamLibrary: team.library
        )

        try await save(store) {
            $0.credentials.password = "typed"
            $0.ssh.password = ""
        }

        #expect(secrets(team.engine.connectionEdits.first) == ["password=typed"])
    }

    @Test("A name-only change leaves the team's envelopes as they are")
    func nameOnlyKeepsEnvelopes() async throws {
        let (team, original) = try await teamCopy()
        let editor = try ConnectionEditorStoreFixture()
        let store = editor.makeStore(.editTeamCopy(target(original, secrets: [.password: "s3cret"], in: team)), teamLibrary: team.library)

        try await save(store) { $0.name = "Production" }

        let edit = try #require(team.engine.connectionEdits.first)
        #expect(edit.connection.connection.name == "Production")
        #expect(edit.secrets == nil)
    }

    @Test("A team edit with key passphrases set sends no passphrase: they belong to this Mac's key files")
    func keyPassphrasesStayHere() async throws {
        let (team, original) = try await teamCopy()
        let editor = try ConnectionEditorStoreFixture()
        let store = editor.makeStore(
            .editTeamCopy(target(original, secrets: [.password: "s3cret", .sshKeyPassphrase: "kept"], in: team)),
            teamLibrary: team.library
        )
        #expect(store.draft.ssh.keyPassphrase.isEmpty)

        try await save(store) {
            $0.portText = "5433"
            $0.ssh.keyPassphrase = "key file"
            $0.ssl.clientKeyPassphrase = "client key"
        }

        #expect(team.engine.connectionEdits.first?.secrets?.map { $0.kind } == ["password"])
    }

    @Test("A password typed while the team's secrets cannot be read is refused, and nothing is sent")
    func unreadableSecretsRefuseATypedOne() async throws {
        let (team, original) = try await teamCopy()
        team.engine.failSecretReads(with: TeamConflictFixture.failure("sync.server"))
        let editor = try ConnectionEditorStoreFixture()
        let store = editor.makeStore(.editTeamCopy(target(original, secrets: nil, in: team)), teamLibrary: team.library)

        store.update { $0.credentials.password = "typed" }
        _ = store.save()

        try await waitUntil { store.saveError != nil }
        #expect(team.engine.connectionEdits.isEmpty)
        #expect(!store.isPublishingTeamCopy)
    }

    @Test("An edit the team refuses keeps the window open and says why")
    func refusedEditStays() async throws {
        let (team, original) = try await teamCopy()
        team.engine.answerPublishes(with: .failure(TeamConflictFixture.failure("sync.team_library.not_writable")))
        let editor = try ConnectionEditorStoreFixture()
        let store = editor.makeStore(.editTeamCopy(target(original, secrets: nil, in: team)), teamLibrary: team.library)
        var dismissed = false
        store.dismissAction = { dismissed = true }

        store.update { $0.portText = "5433" }
        _ = store.save()

        try await waitUntil { store.saveError != nil }
        #expect(!dismissed)
        #expect(ConnectionEditorPresentations.alertsSaveError(store.saveError))
        #expect(!store.isPublishingTeamCopy)
    }

    @Test("Save after the sign-in the form opened under ended publishes nothing")
    func endedSignInPublishesNothing() async throws {
        let (team, original) = try await teamCopy()
        let editor = try ConnectionEditorStoreFixture()
        let store = editor.makeStore(.editTeamCopy(target(original, secrets: [.password: "s3cret"], in: team)), teamLibrary: team.library)
        await team.account.services.signOut()
        try? await team.account.signIn()
        try await waitUntil { !team.library.writableTeams.isEmpty }

        store.update { $0.name = "Production" }
        _ = store.save()

        try await waitUntil { store.saveError != nil }
        #expect(team.engine.connectionEdits.isEmpty)
    }

    @Test("A copy that was never staged reads as a record that is gone")
    func unstagedCopyIsMissing() throws {
        let editor = try ConnectionEditorStoreFixture()

        let store = editor.makeStore(.editTeamCopy(nil))

        #expect(store.isRecordMissing)
        #expect(!store.canSave)
    }
}
