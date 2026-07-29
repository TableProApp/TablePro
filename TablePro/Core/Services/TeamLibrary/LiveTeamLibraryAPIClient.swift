//
//  LiveTeamLibraryAPIClient.swift
//  TablePro
//
//  URLSession client for the team library endpoints. Mirrors LicenseAPIClient's request pattern and
//  reuses LicenseError. The encoder uses no key strategy so CodingKeys drive the snake_case wire
//  format while the embedded ExportableConnection payload keeps its own encoding.
//

import Foundation
import os

final class LiveTeamLibraryAPIClient: TeamLibraryAPIClient {
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
            throw LicenseError.decodingError(error)
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
            throw LicenseError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LicenseError.networkError(URLError(.badServerResponse))
        }

        guard (200...299).contains(http.statusCode) else {
            let message: String
            if let errorResponse = try? decoder.decode(LicenseAPIErrorResponse.self, from: data) {
                message = errorResponse.message
            } else {
                message = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            }
            Self.logger.error("Team library request failed \(http.statusCode): \(message)")
            throw LicenseError.serverError(http.statusCode, message)
        }

        return data
    }
}
