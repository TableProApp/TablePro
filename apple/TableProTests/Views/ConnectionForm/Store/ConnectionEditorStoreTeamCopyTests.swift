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
        canWrite: Bool = true
    ) async throws -> (TeamLibraryFixture, TeamLibraryConnection) {
        let engine = FakeTeamLibraryEngine(teams: [TeamLibraryFixture.acme(role: role, canWrite: canWrite, items: [
            TeamLibraryFixture.connection("c1", name: "Prod")
        ])])
        let fixture = try await TeamLibraryFixture(engine: engine)
        fixture.library.start()
        try await waitUntil { !fixture.library.content.connections.isEmpty }
        return (fixture, try #require(fixture.library.content.connections.first))
    }

    @Test("A team's copy opens with the password its envelopes hold, and is never one the library can delete")
    func opensWithTheTeamsPassword() async throws {
        let (team, original) = try await teamCopy()
        let editor = try ConnectionEditorStoreFixture()

        let store = editor.makeStore(
            .editTeamCopy(TeamCopyTarget(original: original, secrets: [.password: "s3cret"])),
            teamLibrary: team.library
        )

        #expect(store.draft.credentials.password == "s3cret")
        #expect(store.draft.host == "db.internal")
        #expect(!store.isNew)
        #expect(!store.canDelete)
        #expect(!store.isRecordMissing)
        #expect(editor.storage.loadConnections().isEmpty)
    }

    @Test("Save publishes the edit to the team under its id with the form's secrets, writes nothing here, and closes")
    func savePublishesToTheTeam() async throws {
        let (team, original) = try await teamCopy()
        let editor = try ConnectionEditorStoreFixture()
        let store = editor.makeStore(
            .editTeamCopy(TeamCopyTarget(original: original, secrets: [.password: "s3cret"])),
            teamLibrary: team.library
        )
        var dismissed = false
        store.dismissAction = { dismissed = true }

        store.update { $0.portText = "5433" }
        let answer = store.save()

        #expect(answer == .failure(.teamPublishInFlight))
        try await waitUntil { dismissed }
        let edit = try #require(team.engine.connectionEdits.first)
        #expect(edit.connection.connection.id == "c1")
        #expect(edit.connection.connection.port == 5_433)
        #expect(edit.secrets?.map { "\($0.kind)=\($0.value)" } == ["password=s3cret"])
        #expect(editor.storage.loadConnections().isEmpty)
        #expect(editor.secretKeys(for: original.connection.id).isEmpty)
        #expect(!store.isPublishingTeamCopy)
    }

    @Test("A team edit with key passphrases set sends no passphrase: they belong to this Mac's key files")
    func keyPassphrasesStayHere() async throws {
        let (team, original) = try await teamCopy()
        let editor = try ConnectionEditorStoreFixture()
        let store = editor.makeStore(
            .editTeamCopy(TeamCopyTarget(original: original, secrets: [.password: "s3cret", .sshKeyPassphrase: "kept"])),
            teamLibrary: team.library
        )
        var dismissed = false
        store.dismissAction = { dismissed = true }

        #expect(store.draft.ssh.keyPassphrase.isEmpty)
        store.update {
            $0.portText = "5433"
            $0.ssh.keyPassphrase = "key file"
            $0.ssl.clientKeyPassphrase = "client key"
        }
        _ = store.save()

        try await waitUntil { dismissed }
        let edit = try #require(team.engine.connectionEdits.first)
        #expect(edit.secrets?.map { $0.kind } == ["password"])
    }

    @Test("With the team's secrets unread and none typed, Save leaves the team's envelopes as they are")
    func unreadSecretsAreKept() async throws {
        let (team, original) = try await teamCopy()
        let editor = try ConnectionEditorStoreFixture()
        let store = editor.makeStore(.editTeamCopy(TeamCopyTarget(original: original, secrets: nil)), teamLibrary: team.library)
        var dismissed = false
        store.dismissAction = { dismissed = true }

        store.update { $0.portText = "5433" }
        _ = store.save()

        try await waitUntil { dismissed }
        #expect(team.engine.connectionEdits.count == 1)
        #expect(team.engine.connectionEdits.first.map { $0.secrets == nil } == true)
    }

    @Test("An edit the team refuses keeps the window open and says why")
    func refusedEditStays() async throws {
        let (team, original) = try await teamCopy()
        team.engine.answerPublishes(with: .failure(TeamConflictFixture.failure("sync.team_library.not_writable")))
        let editor = try ConnectionEditorStoreFixture()
        let store = editor.makeStore(.editTeamCopy(TeamCopyTarget(original: original, secrets: nil)), teamLibrary: team.library)
        var dismissed = false
        store.dismissAction = { dismissed = true }

        store.update { $0.portText = "5433" }
        _ = store.save()

        try await waitUntil { store.saveError != nil }
        #expect(!dismissed)
        #expect(ConnectionEditorPresentations.alertsSaveError(store.saveError))
        #expect(!store.isPublishingTeamCopy)
    }

    @Test("A copy that was never staged reads as a record that is gone")
    func unstagedCopyIsMissing() throws {
        let editor = try ConnectionEditorStoreFixture()

        let store = editor.makeStore(.editTeamCopy(nil))

        #expect(store.isRecordMissing)
        #expect(!store.canSave)
    }
}
