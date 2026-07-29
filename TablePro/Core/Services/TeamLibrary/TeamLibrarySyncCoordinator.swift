//
//  TeamLibrarySyncCoordinator.swift
//  TablePro
//
//  Owns the app-side team library lifecycle: pulls the shared set on the license revalidation cadence,
//  caches it, and publishes secret-free content through the existing export envelope. License access
//  and credentials are injected so the coordinator is unit-testable without the license singleton.
//

import Combine
import Foundation
import os
import TableProImport

@MainActor
@Observable
final class TeamLibrarySyncCoordinator {
    static let shared = TeamLibrarySyncCoordinator()

    private static let logger = Logger(subsystem: "com.TablePro", category: "TeamLibrarySyncCoordinator")

    private let apiClient: TeamLibraryAPIClient
    private let store: TeamLibraryStore
    private let isFeatureAvailable: @MainActor () -> Bool
    private let credentialsProvider: @MainActor () -> (key: String, machineId: String)?

    private(set) var library: TeamLibraryPullResponse = .empty
    private(set) var isPublishing = false

    init(
        apiClient: TeamLibraryAPIClient = LiveTeamLibraryAPIClient.shared,
        store: TeamLibraryStore = .shared,
        isFeatureAvailable: @escaping @MainActor () -> Bool = { LicenseManager.shared.isFeatureAvailable(.teamLibrary) },
        credentialsProvider: @escaping @MainActor () -> (key: String, machineId: String)? = {
            guard let key = LicenseManager.shared.license?.key else { return nil }
            return (key, LicenseStorage.shared.machineId)
        }
    ) {
        self.apiClient = apiClient
        self.store = store
        self.isFeatureAvailable = isFeatureAvailable
        self.credentialsProvider = credentialsProvider
    }

    func start() {
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

        let envelope = ConnectionExportService.buildEnvelope(for: connections)
        let connectionPayloads = zip(connections, envelope.connections).map { connection, exportable in
            TeamLibraryConnectionPayload(sourceConnectionId: connection.id.uuidString, payload: exportable)
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
