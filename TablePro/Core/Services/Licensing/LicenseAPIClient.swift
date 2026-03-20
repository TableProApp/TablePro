//
//  LicenseAPIClient.swift
//  TablePro
//
//  URLSession-based HTTP client for license activation, validation, and deactivation
//

import Foundation
import os

/// HTTP client for the TablePro license API
final class LicenseAPIClient {
    static let shared = LicenseAPIClient()

    private static let logger = Logger(subsystem: "com.TablePro", category: "LicenseAPIClient")

    // swiftlint:disable:next force_unwrapping
    private let baseURL = URL(string: "https://api.tablepro.app/v1/license")!

    private let session: URLSession

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Activate a license key on this machine
    func activate(request: LicenseActivationRequest) async throws -> SignedLicensePayload {
        let url = baseURL.appendingPathComponent("activate")
        return try await post(url: url, body: request)
    }

    /// Validate an existing activation (periodic re-validation)
    func validate(request: LicenseValidationRequest) async throws -> SignedLicensePayload {
        let url = baseURL.appendingPathComponent("validate")
        return try await post(url: url, body: request)
    }

    /// List all activations for a license key
    func listActivations(licenseKey: String, machineId: String) async throws -> ListActivationsResponse {
        let url = baseURL.appendingPathComponent("activations")
        let body = LicenseValidationRequest(licenseKey: licenseKey, machineId: machineId)
        return try await post(url: url, body: body)
    }

    /// Deactivate a license key from this machine
    func deactivate(request: LicenseDeactivationRequest) async throws {
        let url = baseURL.appendingPathComponent("deactivate")
        let _: SignedLicensePayload? = try? await post(url: url, body: request)
        // Deactivation succeeds as long as we don't get an error
    }

    // MARK: - Private

    private func post<T: Encodable, R: Decodable>(url: URL, body: T) async throws -> R {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try encoder.encode(body)

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Self.logger.error("Network request failed: \(error.localizedDescription)")
            throw LicenseError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LicenseError.networkError(
                URLError(.badServerResponse)
            )
        }

        switch httpResponse.statusCode {
        case 200...299:
            do {
                return try decoder.decode(R.self, from: data)
            } catch {
                Self.logger.error("Failed to decode response: \(error.localizedDescription)")
                throw LicenseError.decodingError(error)
            }

        case 404:
            throw LicenseError.invalidKey

        case 409:
            // Conflict — activation limit reached
            throw LicenseError.activationLimitReached

        case 403:
            // Parse error message to determine specific error
            if let errorResponse = try? decoder.decode(LicenseAPIErrorResponse.self, from: data) {
                let msg = errorResponse.message.lowercased()
                if msg.contains("suspend") {
                    throw LicenseError.licenseSuspended
                } else if msg.contains("expir") {
                    throw LicenseError.licenseExpired
                } else if msg.contains("not activated") || msg.contains("not found") {
                    throw LicenseError.notActivated
                }
                throw LicenseError.serverError(403, errorResponse.message)
            }
            throw LicenseError.serverError(403, "Forbidden")

        default:
            let message: String
            if let errorResponse = try? decoder.decode(LicenseAPIErrorResponse.self, from: data) {
                message = errorResponse.message
            } else {
                message = HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            }
            Self.logger.error("Server error \(httpResponse.statusCode): \(message)")
            throw LicenseError.serverError(httpResponse.statusCode, message)
        }
    }
}
