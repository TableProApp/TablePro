//
//  WelcomeViewModelTeamLibraryTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProFFI
import TableProImport
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

    @Test("Confirming hands each connection to the core under its lowercase id, settings without passwords or commands")
    func confirmedPublishSendsConnections() async throws {
        let fixture = try await TeamLibraryFixture()
        try await fixture.start()
        fixture.engine.answerPublishes(with: .success(TeamPublishInfo(edits: 2, conflicts: 0, unsent: 0, problem: nil)))
        var prod = DatabaseConnection(name: "Prod", type: .postgresql)
        prod.tunnelCommandMode = .inline(TunnelCommandConfiguration(
            method: .custom,
            command: "cloudflared access tcp --url localhost:{port} --service-token-secret S3cret"
        ))
        prod.startupCommands = "SET app.token = 'S3cret';"
        let staging = DatabaseConnection(name: "Staging")

        let outcome = await WelcomeViewModel.publishConnections(
            [prod, staging],
            to: fixture.library.destination(TeamLibraryFixture.team),
            through: fixture.library,
            confirm: { _ in true }
        )

        #expect(outcome == .finished(.published(2)))
        let sent = try #require(fixture.engine.connectionPublishes.first)
        let ids = sent.connections.map { $0.id }
        #expect(ids == [prod.id, staging.id].map { $0.uuidString.lowercased() })
        let settings = sent.connections.compactMap { TeamLibraryFixture.object($0.settingsJson) }
        let names = settings.map { $0["name"] as? String }
        #expect(names == ["Prod", "Staging"])
        #expect(settings.first?["tunnelCommand"] == nil)
        #expect(settings.first?["startupCommands"] == nil)
        let keys = settings.flatMap { $0.keys }
        #expect(!keys.contains { $0.lowercased().contains("password") })
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

    @Test("The confirmation says what the team sees and that passwords stay here")
    func confirmationMessageNamesWhatIsShared() {
        let message = WelcomeViewModel.teamLibraryPublishConfirmationMessage

        #expect(message.contains("SSH settings"))
        #expect(message.contains("Passwords are not included"))
        #expect(!message.contains("replaces"))
    }
}
