//
//  FeedbackAPIClient.swift
//  TablePro
//

import Foundation
import os

enum FeedbackType: String, Codable, CaseIterable {
    case bugReport = "bug_report"
    case featureRequest = "feature_request"
    case general

    var displayName: String {
        switch self {
        case .bugReport: String(localized: "Bug Report")
        case .featureRequest: String(localized: "Feature Request")
        case .general: String(localized: "General Feedback")
        }
    }

    var iconName: String {
        switch self {
        case .bugReport: "ladybug"
        case .featureRequest: "lightbulb"
        case .general: "bubble.left"
        }
    }
}

struct FeedbackSubmissionRequest: Encodable {
    let feedbackType: String
    let title: String
    let description: String
    let stepsToReproduce: String?
    let expectedBehavior: String?
    let appVersion: String
    let osVersion: String
    let architecture: String
    let databaseType: String?
    let installedPlugins: [String]
    let machineId: String
    let screenshots: [String]
}

struct FeedbackSubmissionResponse: Decodable {
    let issueUrl: String
    let issueNumber: Int
}

enum FeedbackError: LocalizedError {
    case networkError(Error)
    case serverError(Int, String)
    case rateLimited
    case submissionTooLarge
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .networkError:
            String(localized: "Network error. Check your connection and try again.")
        case .serverError(let code, let msg):
            String(format: String(localized: "Server error (%d): %@"), code, msg)
        case .rateLimited:
            String(localized: "Too many submissions. Please try again later.")
        case .submissionTooLarge:
            String(localized: "Submission too large. Try removing the screenshot.")
        case .decodingError:
            String(localized: "Unexpected server response.")
        }
    }
}

final class FeedbackAPIClient {
    static let shared = FeedbackAPIClient()

    private static let logger = Logger(subsystem: "com.TablePro", category: "FeedbackAPIClient")

    // swiftlint:disable:next force_unwrapping
    private let baseURL = URL(string: "https://api.tablepro.app/v1/feedback")!

    private let session: URLSession

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    func submitFeedback(request: FeedbackSubmissionRequest) async throws -> FeedbackSubmissionResponse {
        try await post(url: baseURL, body: request)
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
            throw FeedbackError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackError.networkError(URLError(.badServerResponse))
        }

        switch httpResponse.statusCode {
        case 200...299:
            do {
                return try decoder.decode(R.self, from: data)
            } catch {
                Self.logger.error("Failed to decode response: \(error.localizedDescription)")
                throw FeedbackError.decodingError(error)
            }

        case 413:
            throw FeedbackError.submissionTooLarge

        case 429:
            throw FeedbackError.rateLimited

        default:
            let message: String
            if let errorBody = try? JSONDecoder().decode([String: String].self, from: data),
               let msg = errorBody["message"] {
                message = msg
            } else {
                message = HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            }
            Self.logger.error("Server error \(httpResponse.statusCode): \(message)")
            throw FeedbackError.serverError(httpResponse.statusCode, message)
        }
    }
}
