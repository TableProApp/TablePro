//
//  OpenAICompatibleProvider.swift
//  TablePro
//
//  OpenAI-compatible API provider supporting OpenAI, OpenRouter, Ollama, and custom endpoints.
//

import Foundation
import os

/// AI provider for OpenAI-compatible APIs (OpenAI, OpenRouter, Ollama, custom)
final class OpenAICompatibleProvider: AIProvider {
    private static let logger = Logger(
        subsystem: "com.TablePro",
        category: "OpenAICompatibleProvider"
    )

    private let endpoint: String
    private let apiKey: String?
    private let providerType: AIProviderType
    private let session: URLSession

    init(endpoint: String, apiKey: String?, providerType: AIProviderType) {
        self.endpoint = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.providerType = providerType
        self.session = URLSession(configuration: .ephemeral)
    }

    // MARK: - AIProvider

    func streamChat(
        messages: [AIChatMessage],
        model: String,
        systemPrompt: String?
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try buildChatCompletionRequest(
                        messages: messages,
                        model: model,
                        systemPrompt: systemPrompt
                    )

                    let (bytes, response) = try await session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw AIProviderError.networkError("Invalid response")
                    }

                    guard httpResponse.statusCode == 200 else {
                        let errorBody = try await collectErrorBody(from: bytes)
                        throw mapHTTPError(
                            statusCode: httpResponse.statusCode,
                            body: errorBody
                        )
                    }

                    var inputTokens = 0
                    var outputTokens = 0

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }

                        guard line.hasPrefix("data: ") else { continue }
                        let jsonString = String(line.dropFirst(6))
                        guard jsonString != "[DONE]" else { break }

                        if let text = parseChatCompletionDelta(jsonString) {
                            continuation.yield(.text(text))
                        }
                        if let usage = parseUsageFromChunk(jsonString) {
                            inputTokens = usage.inputTokens
                            outputTokens = usage.outputTokens
                        }
                    }

                    if inputTokens > 0 || outputTokens > 0 {
                        continuation.yield(.usage(AITokenUsage(
                            inputTokens: inputTokens,
                            outputTokens: outputTokens
                        )))
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func fetchAvailableModels() async throws -> [String] {
        switch providerType {
        case .ollama:
            return try await fetchOllamaModels()
        default:
            return try await fetchOpenAIModels()
        }
    }

    func testConnection() async throws -> Bool {
        switch providerType {
        case .ollama:
            // Ollama is local — just verify reachability
            let models = try await fetchAvailableModels()
            return !models.isEmpty
        default:
            // Send a minimal non-streaming chat request to verify auth
            let chatPath = "/v1/chat/completions"
            guard let url = URL(string: "\(endpoint)\(chatPath)") else {
                throw AIProviderError.invalidEndpoint(endpoint)
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            if let apiKey, !apiKey.isEmpty {
                request.setValue(
                    "Bearer \(apiKey)",
                    forHTTPHeaderField: "Authorization"
                )
            }

            let body: [String: Any] = [
                "model": "test",
                "messages": [["role": "user", "content": "Hi"]],
                "max_tokens": 1,
                "stream": false,
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (_, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }

            // Check response is JSON (confirms we reached an API, not a random web page)
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
            let isJSON = contentType.contains("application/json")

            if httpResponse.statusCode == 401 {
                throw AIProviderError.authenticationFailed("")
            }

            // Non-JSON response means wrong endpoint (e.g., HTML 404 page)
            if !isJSON {
                return false
            }

            return true
        }
    }

    // MARK: - Request Building

    private func buildChatCompletionRequest(
        messages: [AIChatMessage],
        model: String,
        systemPrompt: String?
    ) throws -> URLRequest {
        let chatPath = providerType == .ollama
            ? "/api/chat"
            : "/v1/chat/completions"
        guard let url = URL(string: "\(endpoint)\(chatPath)") else {
            throw AIProviderError.invalidEndpoint(endpoint)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey, !apiKey.isEmpty {
            request.setValue(
                "Bearer \(apiKey)",
                forHTTPHeaderField: "Authorization"
            )
        }

        // Build messages array
        var apiMessages: [[String: String]] = []
        if let systemPrompt {
            apiMessages.append(["role": "system", "content": systemPrompt])
        }
        for message in messages where message.role != .system {
            apiMessages.append([
                "role": message.role.rawValue,
                "content": message.content
            ])
        }

        var body: [String: Any] = [
            "model": model,
            "messages": apiMessages,
            "stream": true
        ]

        // Request usage stats in stream (OpenAI/OpenRouter support this)
        if providerType != .ollama {
            body["stream_options"] = ["include_usage": true]
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Response Parsing

    private func parseChatCompletionDelta(_ jsonString: String) -> String? {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data)
                  as? [String: Any]
        else {
            return nil
        }

        // OpenAI/OpenRouter format
        if let choices = json["choices"] as? [[String: Any]],
           let delta = choices.first?["delta"] as? [String: Any],
           let content = delta["content"] as? String {
            return content
        }

        // Ollama format
        if let message = json["message"] as? [String: Any],
           let content = message["content"] as? String,
           !content.isEmpty {
            return content
        }

        return nil
    }

    private func parseUsageFromChunk(_ jsonString: String) -> AITokenUsage? {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        // OpenAI/OpenRouter format: usage object in the chunk
        if let usage = json["usage"] as? [String: Any],
           let promptTokens = usage["prompt_tokens"] as? Int,
           let completionTokens = usage["completion_tokens"] as? Int {
            return AITokenUsage(inputTokens: promptTokens, outputTokens: completionTokens)
        }

        // Ollama format: done=true with eval counts
        if let done = json["done"] as? Bool, done,
           let promptEval = json["prompt_eval_count"] as? Int,
           let evalCount = json["eval_count"] as? Int {
            return AITokenUsage(inputTokens: promptEval, outputTokens: evalCount)
        }

        return nil
    }

    // MARK: - Model Fetching

    private func fetchOpenAIModels() async throws -> [String] {
        guard let url = URL(string: "\(endpoint)/v1/models") else {
            throw AIProviderError.invalidEndpoint(endpoint)
        }

        var request = URLRequest(url: url)
        if let apiKey, !apiKey.isEmpty {
            request.setValue(
                "Bearer \(apiKey)",
                forHTTPHeaderField: "Authorization"
            )
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200
        else {
            throw AIProviderError.networkError("Failed to fetch models")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data)
                  as? [String: Any],
              let modelsArray = json["data"] as? [[String: Any]]
        else {
            return []
        }

        return modelsArray.compactMap { $0["id"] as? String }.sorted()
    }

    private func fetchOllamaModels() async throws -> [String] {
        guard let url = URL(string: "\(endpoint)/api/tags") else {
            throw AIProviderError.invalidEndpoint(endpoint)
        }

        let request = URLRequest(url: url)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200
        else {
            throw AIProviderError.networkError("Failed to fetch Ollama models")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data)
                  as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else {
            return []
        }

        return models.compactMap { $0["name"] as? String }.sorted()
    }

    // MARK: - Helpers

    private func collectErrorBody(
        from bytes: URLSession.AsyncBytes
    ) async throws -> String {
        var body = ""
        for try await line in bytes.lines {
            body += line
            if (body as NSString).length > 2_000 { break }
        }
        return body
    }

    private func mapHTTPError(statusCode: Int, body: String) -> AIProviderError {
        let message = AIProviderError.parseErrorMessage(from: body) ?? body

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
}
