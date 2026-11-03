//
//  TeamLibrarySyncCoordinator.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProImport

@MainActor
final class TeamLibrarySyncCoordinator: ObservableObject {
    private struct PullCredentials: Equatable {
        let key: String
        let machineId: String
    }

    private struct InFlightPull {
        let id: UUID
        let credentials: PullCredentials
        let generation: Int
        let task: Task<Void, Never>
    }

    static let shared = TeamLibrarySyncCoordinator()

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "TeamLibrarySyncCoordinator")

    private let apiClient: TeamLibraryAPIClient
    private let store: TeamLibraryStore
    private let isFeatureAvailable: @MainActor () -> Bool
    private let credentialsProvider: @MainActor () -> (key: String, machineId: String)?
    private let licenseStatusChanges: AnyPublisher<Void, Never>
    private let makeExporter: @MainActor () -> ConnectionBundleExporter
    private var licenseCancellable: AnyCancellable?
    private var wasFeatureAvailable = false
    private var inFlightPull: InFlightPull?

    @Published private(set) var library: TeamLibraryPullResponse = .empty
    @Published private(set) var isPublishing = false
    @Published private(set) var isPulling = false
    @Published private(set) var lastRefreshedAt: Date?
    @Published private(set) var lastPullError: String?

    init(
        apiClient: TeamLibraryAPIClient = LiveTeamLibraryAPIClient.shared,
        store: TeamLibraryStore = .shared,
        isFeatureAvailable: @escaping @MainActor () -> Bool = { LicenseManager.shared.isFeatureAvailable(.teamLibrary) },
        credentialsProvider: @escaping @MainActor () -> (key: String, machineId: String)? = {
            guard let key = LicenseManager.shared.license?.key else { return nil }
            return (key, LicenseStorage.shared.machineId)
        },
        licenseStatusChanges: AnyPublisher<Void, Never> = AppEvents.shared.licenseStatusDidChange
            .receive(on: RunLoop.main)
            .eraseToAnyPublisher(),
        makeExporter: @escaping @MainActor () -> ConnectionBundleExporter = { ConnectionBundleExporter() }
    ) {
        self.apiClient = apiClient
        self.store = store
        self.isFeatureAvailable = isFeatureAvailable
        self.credentialsProvider = credentialsProvider
        self.licenseStatusChanges = licenseStatusChanges
        self.makeExporter = makeExporter
        self.lastRefreshedAt = TeamLibraryMetadataStorage.lastPullAt
    }

    func start() {
        observeLicenseChanges()
        guard isFeatureAvailable() else { return }
        Task {
            if let cached = await store.load() {
                library = cached
                AppEvents.shared.teamLibraryDidUpdate.send()
            }
            await pullIfNeeded()
        }
    }

    func pullIfNeeded() async {
        guard isFeatureAvailable(), TeamLibraryMetadataStorage.isPullDue else { return }
        await pull()
    }

    func pull() async {
        guard isFeatureAvailable(), let credentials = currentCredentials() else { return }
        let generation = store.generation
        // Joined only for the same license with nothing invalidated since, or the previous team's pull would stand in.
        if let inFlightPull, inFlightPull.credentials == credentials, inFlightPull.generation == generation {
            await inFlightPull.task.value
            return
        }
        let id = UUID()
        let task = Task { await performPull(id: id, credentials: credentials, generation: generation) }
        inFlightPull = InFlightPull(id: id, credentials: credentials, generation: generation, task: task)
        isPulling = true
        await task.value
    }

    private func performPull(id: UUID, credentials: PullCredentials, generation: Int) async {
        defer {
            if inFlightPull?.id == id {
                inFlightPull = nil
                isPulling = false
            }
        }
        do {
            let response = try await apiClient.pull(licenseKey: credentials.key, machineId: credentials.machineId)
            // Views build rows from `library`, so it gets the sanitized copy the cache holds, never the raw response.
            guard isCurrent(credentials, generation),
                  let sanitized = await store.replace(response, ifGeneration: generation),
                  isCurrent(credentials, generation) else {
                Self.logger.info("Dropped a team library pull that a clear or license change made stale")
                return
            }
            library = sanitized
            TeamLibraryMetadataStorage.recordPull()
            lastRefreshedAt = TeamLibraryMetadataStorage.lastPullAt
            lastPullError = nil
            AppEvents.shared.teamLibraryDidUpdate.send()
        } catch {
            guard isCurrent(credentials, generation) else { return }
            Self.logger.warning("Team library pull failed: \(error.publicLogShape, privacy: .public)")
            lastPullError = error.localizedDescription
        }
    }

    private func currentCredentials() -> PullCredentials? {
        credentialsProvider().map { PullCredentials(key: $0.key, machineId: $0.machineId) }
    }

    private func isCurrent(_ credentials: PullCredentials, _ generation: Int) -> Bool {
        generation == store.generation && isFeatureAvailable() && currentCredentials() == credentials
    }

    func refresh() {
        Task { await pull() }
    }

    private func observeLicenseChanges() {
        wasFeatureAvailable = isFeatureAvailable()
        licenseCancellable = licenseStatusChanges.sink { [weak self] in
            self?.licenseStatusDidChange()
        }
    }

    private func licenseStatusDidChange() {
        let isAvailable = isFeatureAvailable()
        let becameAvailable = isAvailable && !wasFeatureAvailable
        wasFeatureAvailable = isAvailable
        let wasPulling = inFlightPull != nil
        store.invalidatePendingWrites()
        guard isAvailable, becameAvailable || wasPulling else { return }
        refresh()
    }

    // `library` is what Welcome and Favorites draw, so clearing only the store would leave the old team's rows openable.
    func clear() async {
        store.invalidatePendingWrites()
        await store.clear()
        library = .empty
        TeamLibraryMetadataStorage.reset()
        lastRefreshedAt = nil
        lastPullError = nil
        AppEvents.shared.teamLibraryDidUpdate.send()
    }

    @discardableResult
    func publish(
        connections: [DatabaseConnection],
        favorites: [SQLFavorite],
        folders: [SQLFavoriteFolder]
    ) async throws -> TeamLibraryPublishResponse {
        guard let credentials = credentialsProvider() else {
            throw TeamLibraryPublishError.notLicensed
        }
        guard !isPublishing else {
            throw TeamLibraryPublishError.alreadyPublishing
        }

        isPublishing = true
        defer { isPublishing = false }

        let exporter = makeExporter()
        let connectionPayloads = connections.map { connection in
            TeamLibraryConnectionPayload(
                sourceConnectionId: connection.id.uuidString,
                payload: exporter.portableSettings(for: connection, keepingLocalCredentials: true)
            )
        }
        let folderPayloads = folders.map { folder in
            TeamLibraryQueryFolderPayload(
                clientId: folder.id.uuidString,
                parentClientId: folder.parentId?.uuidString,
                name: folder.name,
                sortOrder: folder.sortOrder
            )
        }
        let queryPayloads = favorites.map { favorite in
            TeamLibraryQueryPayload(
                clientId: favorite.id.uuidString,
                folderClientId: favorite.folderId?.uuidString,
                connectionClientId: favorite.connectionId?.uuidString,
                name: favorite.name,
                query: favorite.query,
                keyword: favorite.keyword,
                sortOrder: favorite.sortOrder
            )
        }

        let request = TeamLibraryPublishRequest(
            licenseKey: credentials.key,
            machineId: credentials.machineId,
            connections: connectionPayloads,
            queryFolders: folderPayloads,
            queries: queryPayloads
        )

        let response = try await apiClient.publish(request)
        // A pull that started before the publish cannot hold what it just added.
        await inFlightPull?.task.value
        await pull()
        return response
    }
}

enum TeamLibraryPublishError: LocalizedError {
    case notLicensed
    case alreadyPublishing

    var errorDescription: String? {
        switch self {
        case .notLicensed:
            return String(localized: "Activate a Team license to publish to the team library.")
        case .alreadyPublishing:
            return String(localized: "A publish to the team library is still running. Try again when it finishes.")
        }
    }
}
