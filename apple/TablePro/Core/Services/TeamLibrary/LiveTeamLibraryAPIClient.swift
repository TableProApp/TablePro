//
//  LiveTeamLibraryAPIClient.swift
//  TablePro
//

import Foundation
import os

// The /v1 library, authorized by a license key, until M16.8 moves it to /v2.
enum TeamLibraryAPIError: LocalizedError {
    case network(Error)
    case server(Int, String)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .network(let error):
            return String(format: String(localized: "Network error: %@"), error.localizedDescription)
        case .server(let code, let message):
            return String(format: String(localized: "Server error (%d): %@"), code, message)
        case .decoding(let error):
            return String(format: String(localized: "Failed to parse server response: %@"), error.localizedDescription)
        }
    }
}

private struct TeamLibraryAPIErrorResponse: Decodable {
    let message: String
}

// No key strategy: CodingKeys write snake_case while the embedded ExportableConnection keeps its own encoding.
final class LiveTeamLibraryAPIClient: TeamLibraryAPIClient, Sendable {
    static let shared = LiveTeamLibraryAPIClient()

    private static let logger = Logger(subsystem: "com.TablePro", category: "TeamLibraryAPIClient")

    private let baseURL = URL(string: "https://api.tablepro.app/v1/license/library")!
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            config.waitsForConnectivity = true
            self.session = URLSession(configuration: config)
        }
    }

    func pull(licenseKey: String, machineId: String) async throws -> TeamLibraryPullResponse {
        try await send(method: "POST", path: "pull", body: TeamLibraryPullRequest(licenseKey: licenseKey, machineId: machineId))
    }

    func publish(_ request: TeamLibraryPublishRequest) async throws -> TeamLibraryPublishResponse {
        try await send(method: "POST", path: "publish", body: request)
    }

    func deleteConnection(id: String, licenseKey: String, machineId: String) async throws {
        try await sendVoid(path: "connections/\(id)", licenseKey: licenseKey, machineId: machineId)
    }

    func deleteQuery(clientId: String, licenseKey: String, machineId: String) async throws {
        try await sendVoid(path: "queries/\(clientId)", licenseKey: licenseKey, machineId: machineId)
    }

    func deleteQueryFolder(clientId: String, licenseKey: String, machineId: String) async throws {
        try await sendVoid(path: "query-folders/\(clientId)", licenseKey: licenseKey, machineId: machineId)
    }

    private func send<T: Encodable, R: Decodable>(method: String, path: String, body: T) async throws -> R {
        let data = try await perform(method: method, path: path, body: body)
        do {
            return try decoder.decode(R.self, from: data)
        } catch {
            throw TeamLibraryAPIError.decoding(error)
        }
    }

    private func sendVoid(path: String, licenseKey: String, machineId: String) async throws {
        _ = try await perform(method: "DELETE", path: path, body: TeamLibraryPullRequest(licenseKey: licenseKey, machineId: machineId))
    }

    private func perform<T: Encodable>(method: String, path: String, body: T) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try encoder.encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TeamLibraryAPIError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TeamLibraryAPIError.network(URLError(.badServerResponse))
        }

        guard (200...299).contains(http.statusCode) else {
            let message: String
            if let errorResponse = try? decoder.decode(TeamLibraryAPIErrorResponse.self, from: data) {
                message = errorResponse.message
            } else {
                message = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            }
            Self.logger.error("Team library request failed \(http.statusCode): \(message)")
            throw TeamLibraryAPIError.server(http.statusCode, message)
        }

        return data
    }
}
