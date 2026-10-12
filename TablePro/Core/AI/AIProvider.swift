//
//  AIProvider.swift
//  TablePro
//

import Foundation
import os

enum AIProvider {
    static let modelListTimeout: TimeInterval = 5.0
    static let logger = Logger(subsystem: "com.TablePro", category: "AIProvider")
}

enum AIProviderError: Error, LocalizedError {
    case invalidEndpoint(String)
    case authenticationFailed(String)
    case rateLimited
    case notFound(url: String?, detail: String)
    case serverError(Int, String)
    case networkError(String)
    case streamingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let endpoint):
            return String(format: String(localized: "Invalid endpoint: %@"), endpoint)
        case .authenticationFailed(let detail):
            if detail.isEmpty {
                return String(localized: "Authentication failed. Check your API key.")
            }
            return String(format: String(localized: "Authentication failed: %@"), detail)
        case .rateLimited:
            return String(localized: "Rate limited. Please try again later.")
        case .notFound(let url, let detail):
            let message: String
            if let url, !url.isEmpty {
                message = String(
                    format: String(localized: "Not found (404) at %@. Check the Base URL and the model."),
                    url
                )
            } else {
                message = String(localized: "Not found (404). Check the Base URL and the model.")
            }
            return detail.isEmpty ? message : "\(message) \(detail)"
        case .serverError(let code, let message):
            return String(format: String(localized: "Server error (%d): %@"), code, message)
        case .networkError(let message):
            return String(format: String(localized: "Network error: %@"), message)
        case .streamingFailed(let message):
            return String(format: String(localized: "Streaming failed: %@"), message)
        }
    }

    static func mapHTTPError(
        statusCode: Int,
        body: String,
        treatForbiddenAsAuthFailure: Bool = false,
        requestURL: URL? = nil
    ) -> AIProviderError {
        let message = parseErrorMessage(from: body) ?? body
        switch statusCode {
        case 401:
            return .authenticationFailed(message)
        case 403 where treatForbiddenAsAuthFailure:
            return .authenticationFailed(message)
        case 429:
            return .rateLimited
        case 404:
            return .notFound(url: requestURL?.absoluteString, detail: message)
        default:
            return .serverError(statusCode, message)
        }
    }

    static func parseErrorMessage(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String
        else {
            return nil
        }
        return message
    }

    var isRetryable: Bool {
        switch self {
        case .invalidEndpoint, .authenticationFailed, .notFound:
            return false
        case .rateLimited, .serverError, .networkError, .streamingFailed:
            return true
        }
    }
}

extension AIProvider {
    static func collectErrorBody(from bytes: URLSession.AsyncBytes) async throws -> String {
        var body = ""
        var truncated = false
        for try await line in bytes.lines {
            body += line
            if (body as NSString).length > 2_000 {
                truncated = true
                break
            }
        }
        if truncated {
            AIProvider.logger.warning("Error response body truncated at 2000 bytes; full body suppressed")
        }
        return body
    }
}
