//
//  AIProvider.swift
//  TablePro
//

import Foundation

enum AIProviderError: Error, LocalizedError {
    case invalidEndpoint(String)
    case authenticationFailed(String)
    case rateLimited
    case modelNotFound(String)
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
        case .modelNotFound(let model):
            return String(format: String(localized: "Model not found: %@"), model)
        case .serverError(let code, let message):
            return String(format: String(localized: "Server error (%d): %@"), code, message)
        case .networkError(let message):
            return String(format: String(localized: "Network error: %@"), message)
        case .streamingFailed(let message):
            return String(format: String(localized: "Streaming failed: %@"), message)
        }
    }

    static func mapHTTPError(statusCode: Int, body: String) -> AIProviderError {
        let message = parseErrorMessage(from: body) ?? body
        switch statusCode {
        case 401:
            return .authenticationFailed(message)
        case 429:
            return .rateLimited
        case 404:
            return .modelNotFound(message)
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
        case .invalidEndpoint, .authenticationFailed, .modelNotFound:
            return false
        case .rateLimited, .serverError, .networkError, .streamingFailed:
            return true
        }
    }
}

extension ChatTransport {
    func collectErrorBody(from bytes: URLSession.AsyncBytes) async throws -> String {
        var body = ""
        for try await line in bytes.lines {
            body += line
            if (body as NSString).length > 2_000 { break }
        }
        return body
    }
}
