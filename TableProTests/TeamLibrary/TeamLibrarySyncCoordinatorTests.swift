//
//  TeamLibrarySyncCoordinatorTests.swift
//  TablePro
//
//  Tests the team library coordinator against a mock client: gating, pull caching, the 7-day pull
//  cadence, and that publishing sends the mapped content and refreshes.
//

import Foundation
@testable import TablePro
import Testing

@MainActor
@Suite("TeamLibrarySyncCoordinator", .serialized)
struct TeamLibrarySyncCoordinatorTests {
    private func makeCoordinator(
        mock: MockTeamLibraryAPIClient,
        available: Bool = true
    ) -> TeamLibrarySyncCoordinator {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("team_library_\(UUID().uuidString).json")
        return TeamLibrarySyncCoordinator(
            apiClient: mock,
            store: TeamLibraryStore(fileURL: url),
            isFeatureAvailable: { available },
            credentialsProvider: { ("AAAAA-BBBBB-CCCCC-DDDDD-EEEEE", String(repeating: "a", count: 64)) }
        )
    }

    @Test("pull loads the response into the observable library")
    func pullUpdatesLibrary() async {
        TeamLibraryMetadataStorage.reset()
        let mock = MockTeamLibraryAPIClient()
        mock.pullResponse = TeamLibraryPullResponse(
            connections: [],
            queryFolders: [],
            queries: [.init(clientId: UUID().uuidString, folderClientId: nil, connectionClientId: nil, name: "Q", query: "select 1", keyword: nil, sortOrder: 0, publishedBy: "a@b.com")],
            fetchedAt: "now"
        )
        let coordinator = makeCoordinator(mock: mock)

        await coordinator.pull()

        #expect(coordinator.library.queries.count == 1)
        #expect(mock.pullCallCount == 1)
    }

    @Test("pull does nothing when the feature is unavailable")
    func pullSkipsWhenUnavailable() async {
        let mock = MockTeamLibraryAPIClient()
        let coordinator = makeCoordinator(mock: mock, available: false)

        await coordinator.pull()

        #expect(mock.pullCallCount == 0)
    }

    @Test("pullIfNeeded skips when a pull is not yet due")
    func pullIfNeededRespectsInterval() async {
        TeamLibraryMetadataStorage.recordPull()
        let mock = MockTeamLibraryAPIClient()
        let coordinator = makeCoordinator(mock: mock)

        await coordinator.pullIfNeeded()

        #expect(mock.pullCallCount == 0)
        TeamLibraryMetadataStorage.reset()
    }

    @Test("publish sends the mapped saved queries and then refreshes")
    func publishSendsQueries() async throws {
        TeamLibraryMetadataStorage.reset()
        let mock = MockTeamLibraryAPIClient()
        let coordinator = makeCoordinator(mock: mock)
        let favorite = SQLFavorite(
            id: UUID(),
            name: "Recent",
            query: "select 1",
            keyword: nil,
            folderId: nil,
            connectionId: nil,
            sortOrder: 0,
            createdAt: Date(),
            updatedAt: Date()
        )

        _ = try await coordinator.publish(connections: [], favorites: [favorite], folders: [])

        #expect(mock.publishedRequests.count == 1)
        #expect(mock.publishedRequests[0].queries.count == 1)
        #expect(mock.publishedRequests[0].queries[0].name == "Recent")
        #expect(mock.pullCallCount == 1)
    }
}
