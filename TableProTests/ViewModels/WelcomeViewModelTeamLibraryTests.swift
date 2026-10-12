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
    func declinedConfirmationPublishesNothing() async {
        let mock = MockTeamLibraryAPIClient()
        var askedAbout: [String] = []

        let outcome = await WelcomeViewModel.publishConnections(
            [DatabaseConnection(name: "Prod")],
            through: makeCoordinator(mock),
            confirm: { connections in
                askedAbout = connections.map(\.name)
                return false
            }
        )

        #expect(askedAbout == ["Prod"])
        #expect(mock.publishedRequests.isEmpty)
        guard case .declined = outcome else {
            Issue.record("Expected the publish to be declined, got \(outcome)")
            return
        }
    }

    @Test("Confirming sends the connections to the team library")
    func confirmedPublishSendsConnections() async {
        let mock = MockTeamLibraryAPIClient()

        let outcome = await WelcomeViewModel.publishConnections(
            [DatabaseConnection(name: "Prod"), DatabaseConnection(name: "Staging")],
            through: makeCoordinator(mock),
            confirm: { _ in true }
        )

        #expect(mock.publishedRequests.map { $0.connections.map(\.payload.name) } == [["Prod", "Staging"]])
        guard case .published = outcome else {
            Issue.record("Expected the publish to go through, got \(outcome)")
            return
        }
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

    @Test("The confirmation says publishing replaces what was published before and shares SSH settings")
    func confirmationMessageNamesReplacementAndSSH() {
        let message = WelcomeViewModel.teamLibraryPublishConfirmationMessage

        #expect(message.contains("replaces the connections and saved queries you published before"))
        #expect(message.contains("SSH settings"))
    }

    private func makeCoordinator(_ mock: MockTeamLibraryAPIClient) -> TeamLibrarySyncCoordinator {
        TeamLibrarySyncCoordinator(
            apiClient: mock,
            store: TeamLibraryStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("team_library_\(UUID().uuidString).json")
            ),
            isFeatureAvailable: { false },
            credentialsProvider: { ("AAAAA-BBBBB-CCCCC-DDDDD-EEEEE", String(repeating: "a", count: 64)) }
        )
    }
}
