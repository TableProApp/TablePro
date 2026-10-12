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

    @Published private(set) var library: TeamLibraryPullResponse = .empty
    @Published private(set) var isPublishing = false

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
        guard isFeatureAvailable(), let credentials = credentialsProvider() else { return }
        do {
            let response = try await apiClient.pull(licenseKey: credentials.key, machineId: credentials.machineId)
            await store.replace(response)
            library = response
            TeamLibraryMetadataStorage.recordPull()
            AppEvents.shared.teamLibraryDidUpdate.send()
        } catch {
            Self.logger.warning("Team library pull failed: \(error.localizedDescription)")
        }
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
        guard becameAvailable else { return }
        refresh()
    }

    /// Drop the team's shared set, on disk and in the copy every view reads.
    ///
    /// Clearing the store alone is not enough: `library` is what the welcome window and the
    /// Favorites sidebar render from, so a licence removed without this leaves the previous team's
    /// connections and saved queries on screen, and openable, until the next launch.
    func clear() async {
        await store.clear()
        library = .empty
        TeamLibraryMetadataStorage.reset()
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

        isPublishing = true
        defer { isPublishing = false }

        let exporter = makeExporter()
        let connectionPayloads = connections.map { connection in
            TeamLibraryConnectionPayload(
                sourceConnectionId: connection.id.uuidString,
                payload: exporter.portableSettings(for: connection)
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
        await pull()
        return response
    }
}

enum TeamLibraryPublishError: LocalizedError {
    case notLicensed

    var errorDescription: String? {
        switch self {
        case .notLicensed:
            return String(localized: "Activate a Team license to publish to the team library.")
        }
    }
}
