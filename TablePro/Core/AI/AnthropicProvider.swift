//
//  AnthropicProvider.swift
//  TablePro
//

import Foundation
import os

final class AnthropicProvider: ChatTransport {
    private static let logger = Logger(subsystem: "com.TablePro", category: "AnthropicProvider")

    private let endpoint: String
    private let apiKey: String
    private let maxOutputTokens: Int
    private let session: URLSession

    init(endpoint: String, apiKey: String, maxOutputTokens: Int = 4_096) {
        self.endpoint = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.maxOutputTokens = maxOutputTokens
        self.session = URLSession(configuration: .ephemeral)
    }

    func streamChat(
        turns: [ChatTurn],
        options: ChatTransportOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try buildMessagesRequest(turns: turns, options: options)
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
                                continuation.yield(.textDelta(text))
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
        let testTurn = ChatTurn(role: .user, blocks: [.text("Hi")])
        let testOptions = ChatTransportOptions(model: "claude-haiku-4-5-20251001", maxOutputTokens: 1)
        let request = try buildMessagesRequest(turns: [testTurn], options: testOptions, stream: false)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            return false
        }

        let statusCode = httpResponse.statusCode

        if statusCode == 200 || statusCode == 400 {
            return true
        }

        if statusCode == 401 {
            throw AIProviderError.authenticationFailed("")
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        throw AIProviderError.mapHTTPError(statusCode: statusCode, body: body)
    }

    private func buildMessagesRequest(
        turns: [ChatTurn],
        options: ChatTransportOptions,
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
            "model": options.model,
            "max_tokens": options.maxOutputTokens ?? maxOutputTokens,
            "stream": stream
        ]

        if let systemPrompt = options.systemPrompt {
            body["system"] = systemPrompt
        }

        let apiMessages = turns
            .filter { $0.role != .system }
            .compactMap { turn -> [String: String]? in
                let text = turn.plainText
                guard !text.isEmpty else { return nil }
                return ["role": turn.role.rawValue, "content": text]
            }
        body["messages"] = apiMessages

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}
