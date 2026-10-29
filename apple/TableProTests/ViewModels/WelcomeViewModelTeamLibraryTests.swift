//
//  WelcomeViewModelTeamLibraryTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProImport
import Testing

@MainActor
struct WelcomeViewModelTeamLibraryTests {
    @Test("Declining the confirmation sends nothing to the team library")
    func declinedConfirmationPublishesNothing() async throws {
        let fixture = try await TeamLibraryFixture()
        var askedAbout: [String] = []

        let outcome = await WelcomeViewModel.publishConnections(
            [DatabaseConnection(name: "Prod")],
            to: TeamLibraryFixture.team,
            through: fixture.sync,
            confirm: { connections in
                askedAbout = connections.map(\.name)
                return false
            }
        )

        #expect(askedAbout == ["Prod"])
        #expect(outcome == .declined)
        #expect(await fixture.libraryRequests().isEmpty)
    }

    @Test("Confirming pushes each connection under its lowercase ID, settings without passwords")
    func confirmedPublishSendsConnections() async throws {
        let fixture = try await TeamLibraryFixture()
        let prod = DatabaseConnection(name: "Prod")
        let staging = DatabaseConnection(name: "Staging")

        let outcome = await WelcomeViewModel.publishConnections(
            [prod, staging],
            to: TeamLibraryFixture.team,
            through: fixture.sync,
            confirm: { _ in true }
        )

        #expect(outcome == .finished(.published(2)))
        let changes = try #require(await fixture.pushes().first)
        #expect(changes.map { $0["client_id"] as? String } == [prod.id, staging.id].map { $0.uuidString.lowercased() })
        #expect(changes.map { ($0["data"] as? [String: Any])?["name"] as? String } == ["Prod", "Staging"])
        let keys = changes.flatMap { (($0["data"] as? [String: Any]) ?? [:]).keys }
        #expect(!keys.isEmpty && !keys.contains { TeamLibraryPayload.isSecretKey($0) })
        #expect(fixture.sync.content.connections.map(\.settings.name) == ["Prod", "Staging"])
    }

    @Test("A member who only reads the library gets told so, and nothing is pushed")
    func readerCannotPublish() async throws {
        let fixture = try await TeamLibraryFixture(role: "member")

        let outcome = await WelcomeViewModel.publishConnections(
            [DatabaseConnection(name: "Prod")],
            to: TeamLibraryFixture.team,
            through: fixture.sync,
            confirm: { _ in true }
        )

        #expect(outcome == .failed(.notWritable))
        #expect(await fixture.pushes().isEmpty)
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
