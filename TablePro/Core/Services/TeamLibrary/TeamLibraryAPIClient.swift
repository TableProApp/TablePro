//
//  TeamLibraryAPIClient.swift
//  TablePro
//
//  HTTP boundary for the backend-hosted team library. A protocol so the sync coordinator can be
//  unit-tested against a mock without touching the network.
//

import Foundation

protocol TeamLibraryAPIClient: Sendable {
    func pull(licenseKey: String, machineId: String) async throws -> TeamLibraryPullResponse
    func publish(_ request: TeamLibraryPublishRequest) async throws -> TeamLibraryPublishResponse
    func deleteConnection(id: String, licenseKey: String, machineId: String) async throws
    func deleteQuery(clientId: String, licenseKey: String, machineId: String) async throws
    func deleteQueryFolder(clientId: String, licenseKey: String, machineId: String) async throws
}

final class MockTeamLibraryAPIClient: TeamLibraryAPIClient, @unchecked Sendable {
    var pullResponse: TeamLibraryPullResponse = .empty
    var publishResponse = TeamLibraryPublishResponse(publishedAt: "", connectionCount: 0, queryCount: 0)
    var pullError: Error?

    private(set) var pullCallCount = 0
    private(set) var publishedRequests: [TeamLibraryPublishRequest] = []
    private(set) var deletedConnectionIds: [String] = []

    func pull(licenseKey: String, machineId: String) async throws -> TeamLibraryPullResponse {
        pullCallCount += 1
        if let pullError { throw pullError }
        return pullResponse
    }

    func publish(_ request: TeamLibraryPublishRequest) async throws -> TeamLibraryPublishResponse {
        publishedRequests.append(request)
        return publishResponse
    }

    func deleteConnection(id: String, licenseKey: String, machineId: String) async throws {
        deletedConnectionIds.append(id)
    }

    func deleteQuery(clientId: String, licenseKey: String, machineId: String) async throws {}

    func deleteQueryFolder(clientId: String, licenseKey: String, machineId: String) async throws {}
}
