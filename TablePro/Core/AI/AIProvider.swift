//
//  AIProvider.swift
//  TablePro
//
//  Protocol defining AI provider interface for streaming chat and model discovery.
//

import Foundation

/// Protocol for AI provider implementations
protocol AIProvider: AnyObject {
    /// Stream chat completions as an async sequence of events (text tokens and usage)
    func streamChat(
        messages: [AIChatMessage],
        model: String,
        systemPrompt: String?
    ) -> AsyncThrowingStream<AIStreamEvent, Error>

    /// Fetch available models from the provider
    func fetchAvailableModels() async throws -> [String]

    /// Test connection to verify API key and endpoint
    func testConnection() async throws -> Bool
}

/// Errors that can occur during AI provider operations
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
            return String(localized: "Invalid endpoint: \(endpoint)")
        case .authenticationFailed(let detail):
            if detail.isEmpty {
                return String(localized: "Authentication failed. Check your API key.")
            }
            return String(localized: "Authentication failed: \(detail)")
        case .rateLimited:
            return String(localized: "Rate limited. Please try again later.")
        case .modelNotFound(let model):
            return String(localized: "Model not found: \(model)")
        case .serverError(let code, let message):
            return String(localized: "Server error (\(code)): \(message)")
        case .networkError(let message):
            return String(localized: "Network error: \(message)")
        case .streamingFailed(let message):
            return String(localized: "Streaming failed: \(message)")
        }
    }

    /// Extract human-readable message from provider JSON error responses.
    /// Supports Anthropic (`{"error":{"message":"..."}}`), OpenAI, and Gemini formats.
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
}
