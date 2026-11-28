//
//  WelcomeViewModelTeamLibraryTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProFFI
import TableProTestSupport
import Testing

@MainActor
struct WelcomeViewModelTeamLibraryTests {
    @Test("Declining the confirmation sends nothing to the team library")
    func declinedConfirmationPublishesNothing() async throws {
        let fixture = try await TeamLibraryFixture()
        try await fixture.start()
        var askedAbout: [String] = []

        let outcome = await WelcomeViewModel.publishConnections(
            [DatabaseConnection(name: "Prod")],
            to: fixture.library.destination(TeamLibraryFixture.team),
            through: fixture.library,
            confirm: { connections in
                askedAbout = connections.map { $0.name }
                return false
            }
        )

        #expect(askedAbout == ["Prod"])
        #expect(outcome == .declined)
        #expect(fixture.engine.connectionPublishes.isEmpty)
    }

    @Test("A sign-in that ends while the confirmation is open sends nothing, though the next one has the same team")
    func switchWhileConfirmingPublishesNothing() async throws {
        let fixture = try await TeamLibraryFixture()
        try await fixture.start()

        let outcome = await WelcomeViewModel.publishConnections(
            [DatabaseConnection(name: "Prod")],
            to: fixture.library.destination(TeamLibraryFixture.team),
            through: fixture.library,
            confirm: { _ in
                await fixture.account.services.signOut()
                try? await fixture.account.signIn()
                try? await waitUntil { !fixture.library.writableTeams.isEmpty }
                return true
            }
        )

        #expect(outcome == .failed(.failed(.signedOut)))
        #expect(fixture.engine.connectionPublishes.isEmpty)
    }

    @Test("Confirming hands each connection to the core as its library record")
    func confirmedPublishSendsConnections() async throws {
        let fixture = try await TeamLibraryFixture()
        try await fixture.start()
        fixture.engine.answerPublishes(with: .success(TeamPublishInfo(edits: 2, conflicts: 0, unsent: 0, problem: nil)))
        let prod = DatabaseConnection(name: "Prod", type: .postgresql)
        let staging = DatabaseConnection(name: "Staging")

        let outcome = await WelcomeViewModel.publishConnections(
            [prod, staging],
            to: fixture.library.destination(TeamLibraryFixture.team),
            through: fixture.library,
            confirm: { _ in true }
        )

        #expect(outcome == .finished(.published(2)))
        let sent = try #require(fixture.engine.connectionPublishes.first)
        #expect(sent.connections.map { UUID(uuidString: $0.connection.id) } == [prod.id, staging.id])
        #expect(sent.connections.map { $0.connection.driverId } == ["PostgreSQL", "MySQL"])
    }

    @Test("A member who only reads the library gets told so, and nothing is sent")
    func readerCannotPublish() async throws {
        let engine = FakeTeamLibraryEngine(teams: [TeamLibraryFixture.acme(role: .member, canWrite: false)])
        let fixture = try await TeamLibraryFixture(engine: engine)
        fixture.library.start()

        let outcome = await WelcomeViewModel.publishConnections(
            [DatabaseConnection(name: "Prod")],
            to: fixture.library.destination(TeamLibraryFixture.team),
            through: fixture.library,
            confirm: { _ in true }
        )

        #expect(outcome == .failed(.notWritable))
        #expect(engine.connectionPublishes.isEmpty)
    }

    @Test("An editor publishes connections")
    func editorPublishesConnections() async throws {
        let engine = FakeTeamLibraryEngine(teams: [TeamLibraryFixture.acme(role: .editor)])
        let fixture = try await TeamLibraryFixture(engine: engine)
        try await fixture.start()

        let outcome = await WelcomeViewModel.publishConnections(
            [DatabaseConnection(name: "Prod")],
            to: fixture.library.destination(TeamLibraryFixture.team),
            through: fixture.library,
            confirm: { _ in true }
        )

        #expect(outcome == .finished(.published(1)))
        #expect(engine.connectionPublishes.count == 1)
    }

    @Test("The confirmation names one connection and counts several")
    func confirmationTitleNamesOrCounts() {
        let single = WelcomeViewModel.teamLibraryPublishConfirmationTitle(for: [DatabaseConnection(name: "Prod")])
        let several = WelcomeViewModel.teamLibraryPublishConfirmationTitle(
            for: [DatabaseConnection(name: "Prod"), DatabaseConnection(name: "Staging")]
        )

        #expect(single.contains("Prod"))
        #expect(several.contains("2"))
    }

    @Test("The confirmation says what the team sees, and that the passwords go encrypted unless the team turns that off")
    func confirmationMessageNamesWhatIsShared() {
        let syncing = WelcomeViewModel.teamLibraryPublishConfirmationMessage(syncsPasswords: true)
        let off = WelcomeViewModel.teamLibraryPublishConfirmationMessage(syncsPasswords: false)

        #expect(syncing.contains("SSH settings"))
        #expect(syncing.contains("encrypted"))
        #expect(!syncing.contains("not included"))
        #expect(off.contains("SSH settings"))
        #expect(off.contains("not included"))
        #expect(!syncing.contains("replaces"))
    }

    @Test("A publish whose passwords stayed on this Mac says why, whatever the reason")
    func passwordsLeftOutAreNamed() throws {
        let unconfirmed = TeamPublishInfo(
            edits: 1, conflicts: 0, unsent: 0, problem: nil, secretsLeftOut: "sync.team_library.not_confirmed"
        )
        let off = TeamPublishInfo(
            edits: 1, conflicts: 0, unsent: 0, problem: nil, secretsLeftOut: "sync.team_library.passwords_off"
        )

        #expect(try TeamLibrary.result(of: unconfirmed) == .publishedWithoutPasswords(1, .notConfirmed))
        #expect(try TeamLibrary.result(of: off) == .publishedWithoutPasswords(1, .off))
        #expect(try TeamLibrary.result(of: TeamPublishInfo(edits: 1, conflicts: 0, unsent: 0, problem: nil)) == .published(1))
        #expect(TeamLibraryPublishing.message(for: .publishedWithoutPasswords(1, .notConfirmed)) != nil)
        #expect(TeamLibraryPublishing.message(for: .published(1)) == nil)
    }
}
