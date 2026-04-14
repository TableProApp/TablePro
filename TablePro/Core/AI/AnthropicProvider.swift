//
//  AnthropicProvider.swift
//  TablePro
//
//  Anthropic Claude API provider using the Messages API with SSE streaming.
//

import Foundation
import os

/// AI provider for Anthropic's Claude models
final class AnthropicProvider: AIProvider {
    private static let logger = Logger(subsystem: "com.TablePro", category: "AnthropicProvider")

    private let endpoint: String
    private let apiKey: String
    private let session: URLSession

    init(endpoint: String, apiKey: String) {
        self.endpoint = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
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
                    let request = try buildMessagesRequest(
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
                        throw AIProviderError.mapHTTPError(
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
                        guard jsonString != "[DONE]",
                              let data = jsonString.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = json["type"] as? String
                        else { continue }

                        switch type {
                        case "content_block_delta":
                            if let delta = json["delta"] as? [String: Any],
                               let text = delta["text"] as? String {
                                continuation.yield(.text(text))
                            }
                        case "message_start":
                            if let message = json["message"] as? [String: Any],
                               let usage = message["usage"] as? [String: Any],
                               let tokens = usage["input_tokens"] as? Int {
                                inputTokens = tokens
                            }
                        case "message_delta":
                            if let usage = json["usage"] as? [String: Any],
                               let tokens = usage["output_tokens"] as? Int {
                                outputTokens = tokens
                            }
                        case "error":
                            if let errorObj = json["error"] as? [String: Any],
                               let message = errorObj["message"] as? String {
                                throw AIProviderError.streamingFailed(message)
                            }
                        default:
                            break
                        }
                    }

                    // Yield usage if we got any token data
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
        guard let url = URL(string: "\(endpoint)/v1/models") else {
            throw AIProviderError.invalidEndpoint(endpoint)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]]
        else {
            return Self.knownModels
        }

        let modelIds = models.compactMap { $0["id"] as? String }
        return modelIds.isEmpty ? Self.knownModels : modelIds
    }

    private static let knownModels = [
        "claude-sonnet-4-6",
        "claude-opus-4-6",
        "claude-haiku-4-5-20251001",
        "claude-sonnet-4-5-20250929",
        "claude-opus-4-5-20251101"
    ]

    func testConnection() async throws -> Bool {
        let testMessage = AIChatMessage(role: .user, content: "Hi")
        let request = try buildMessagesRequest(
            messages: [testMessage],
            model: "claude-haiku-4-5-20251001",
            systemPrompt: nil,
            maxTokens: 1,
            stream: false
        )

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            return false
        }

        let statusCode = httpResponse.statusCode

        // 200 = full success, 400 = key is valid but request was rejected (e.g. billing)
        if statusCode == 200 || statusCode == 400 {
            return true
        }

        if statusCode == 401 {
            throw AIProviderError.authenticationFailed("")
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        throw AIProviderError.mapHTTPError(statusCode: statusCode, body: body)
    }

    // MARK: - Private

    private func buildMessagesRequest(
        messages: [AIChatMessage],
        model: String,
        systemPrompt: String?,
        maxTokens: Int = 4_096,
        stream: Bool = true
    ) throws -> URLRequest {
        guard let url = URL(string: "\(endpoint)/v1/messages") else {
            throw AIProviderError.invalidEndpoint(endpoint)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": stream
        ]

        if let systemPrompt {
            body["system"] = systemPrompt
        }

        // Convert messages (skip system role — handled via system parameter)
        let apiMessages = messages
            .filter { $0.role != .system }
            .map { message -> [String: String] in
                ["role": message.role.rawValue, "content": message.content]
            }
        body["messages"] = apiMessages

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}
