//
//  TeamLibrarySecretsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProFFI
import TableProTestSupport
import Testing

@MainActor
struct TeamLibrarySecretsTests {
    @Test("Each team connection names its team and whether the core's role for this account writes that team's library")
    func connectionsCarryTheirTeamAndRole() async throws {
        let editor = FakeTeamLibraryEngine(teams: [TeamLibraryFixture.acme(role: .editor, items: [
            TeamLibraryFixture.connection("c1", name: "Prod")
        ])])
        let member = FakeTeamLibraryEngine(teams: [TeamLibraryFixture.acme(role: .member, canWrite: false, items: [
            TeamLibraryFixture.connection("c1", name: "Prod")
        ])])

        let writes = try await TeamLibraryFixture(engine: editor)
        try await writes.start()
        try await waitUntil { !writes.library.content.connections.isEmpty }
        let reads = try await TeamLibraryFixture(engine: member)
        reads.library.start()
        try await waitUntil { !reads.library.content.connections.isEmpty }

        let written = try #require(writes.library.content.connections.first)
        #expect(written.teamID == TeamLibraryFixture.team)
        #expect(written.canWrite)
        #expect(reads.library.content.connections.first?.canWrite == false)
        #expect(writes.library.content.connection(rowID: written.connection.id) == written)
    }

    @Test("A team connection's secrets come back by the item they stand for, and a kind this Mac keeps none of is left out")
    func secretsComeBackByItem() async throws {
        let engine = FakeTeamLibraryEngine(teams: [TeamLibraryFixture.acme(items: [
            TeamLibraryFixture.connection("c1", name: "Prod")
        ])])
        engine.hold(secrets: [
            TeamSecretArg(kind: "password", value: "s3cret"),
            TeamSecretArg(kind: "ssh_password", value: "tunnel"),
            TeamSecretArg(kind: "plugin.token", value: "kept elsewhere"),
            TeamSecretArg(kind: "ssh_key_passphrase", value: "an older build's")
        ], for: "c1")
        let fixture = try await TeamLibraryFixture(engine: engine)
        try await fixture.start()
        try await waitUntil { !fixture.library.content.connections.isEmpty }
        let connection = try #require(fixture.library.content.connections.first)

        let secrets = await fixture.library.secrets(for: connection)

        #expect(secrets == [.password: "s3cret", .sshPassword: "tunnel"])
    }

    @Test("An edit goes to its team under the team's id with the whole set of secrets, or none to keep the team's")
    func editPublishesUnderTheTeamsId() async throws {
        let engine = FakeTeamLibraryEngine(teams: [TeamLibraryFixture.acme(role: .editor, items: [
            TeamLibraryFixture.connection("c1", name: "Prod")
        ])])
        let fixture = try await TeamLibraryFixture(engine: engine)
        try await fixture.start()
        try await waitUntil { !fixture.library.content.connections.isEmpty }
        let original = try #require(fixture.library.content.connections.first)
        var edited = original.connection
        edited.port = 5_433

        let result = try await fixture.library.publishConnectionEdit(
            edited, of: original, secrets: [.password: "rotated", .sshPassword: "", .sshKeyPassphrase: "key file"]
        )
        _ = try await fixture.library.publishConnectionEdit(edited, of: original, secrets: nil)

        #expect(result == .published(1))
        let first = try #require(engine.connectionEdits.first)
        #expect(first.team == TeamLibraryFixture.team)
        #expect(first.connection.connection.id == "c1")
        #expect(first.connection.connection.port == 5_433)
        #expect(first.secrets?.map { "\($0.kind)=\($0.value)" } == ["password=rotated"])
        #expect(engine.connectionEdits.last.map { $0.secrets == nil } == true)
    }

    @Test("A member's edit is refused before it reaches the engine")
    func memberCannotEdit() async throws {
        let engine = FakeTeamLibraryEngine(teams: [TeamLibraryFixture.acme(role: .member, canWrite: false, items: [
            TeamLibraryFixture.connection("c1", name: "Prod")
        ])])
        let fixture = try await TeamLibraryFixture(engine: engine)
        fixture.library.start()
        try await waitUntil { !fixture.library.content.connections.isEmpty }
        let original = try #require(fixture.library.content.connections.first)

        await #expect(throws: TeamLibraryPublishError.notWritable) {
            try await fixture.library.publishConnectionEdit(original.connection, of: original, secrets: nil)
        }
        #expect(engine.connectionEdits.isEmpty)
    }

    @Test("A sign-out forgets every team secret this Mac opened")
    func signOutForgetsSecrets() async throws {
        let fixture = try await TeamLibraryFixture()
        var forgotten = 0
        let library = TeamLibrary(
            source: fixture.source,
            account: fixture.account.services,
            legacy: fixture.legacy,
            reportDiscarded: { _ in },
            forgetSecrets: { forgotten += 1 }
        )
        library.start()
        try await waitUntil { !library.writableTeams.isEmpty }
        let before = forgotten

        await fixture.account.services.signOut()
        try await waitUntil { library.writableTeams.isEmpty }

        #expect(forgotten > before)
    }
}
