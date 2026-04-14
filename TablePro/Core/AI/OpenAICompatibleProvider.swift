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
                        throw AIProviderError.mapHTTPError(
                            statusCode: httpResponse.statusCode,
                            body: errorBody
                        )
                    }

                    var inputTokens = 0
                    var outputTokens = 0

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }

                        let jsonString: String
                        if self.providerType == .ollama {
                            // Ollama: raw newline-delimited JSON (no SSE "data: " prefix)
                            guard !line.isEmpty else { continue }
                            jsonString = line
                        } else {
                            // OpenAI/OpenRouter/Custom: SSE with "data: " prefix
                            guard line.hasPrefix("data: ") else { continue }
                            let payload = String(line.dropFirst(6))
                            guard payload != "[DONE]" else { break }
                            jsonString = payload
                        }

                        // Single JSON parse per SSE line
                        guard let data = jsonString.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        // Text extraction
                        if let choices = json["choices"] as? [[String: Any]],
                           let delta = choices.first?["delta"] as? [String: Any],
                           let content = delta["content"] as? String {
                            continuation.yield(.text(content))
                        } else if let message = json["message"] as? [String: Any],
                                  let content = message["content"] as? String,
                                  !content.isEmpty {
                            continuation.yield(.text(content))
                        }

                        // Usage extraction
                        if let usage = json["usage"] as? [String: Any],
                           let promptTokens = usage["prompt_tokens"] as? Int,
                           let completionTokens = usage["completion_tokens"] as? Int {
                            inputTokens = promptTokens
                            outputTokens = completionTokens
                        } else if let done = json["done"] as? Bool, done,
                                  let promptEval = json["prompt_eval_count"] as? Int,
                                  let evalCount = json["eval_count"] as? Int {
                            inputTokens = promptEval
                            outputTokens = evalCount
                        }

                        // Ollama signals completion with "done":true
                        if json["done"] as? Bool == true {
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
            // Ollama is local — verify reachability and model availability
            do {
                let models = try await fetchAvailableModels()
                if models.isEmpty {
                    throw AIProviderError.networkError(
                        String(localized: "Ollama is running but has no models. Run \"ollama pull <model>\" to download one.")
                    )
                }
                return true
            } catch let error as AIProviderError {
                throw error
            } catch is URLError {
                throw AIProviderError.networkError(
                    String(format: String(localized: "Cannot connect to Ollama at %@. Is Ollama running?"), endpoint)
                )
            } catch {
                throw AIProviderError.networkError(
                    String(format: String(localized: "Cannot connect to Ollama at %@. Is Ollama running?"), endpoint)
                )
            }
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
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AIProviderError.networkError(
                String(format: String(localized: "Failed to fetch models from %@ (HTTP %d)"), endpoint, statusCode)
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data)
                  as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else {
            return []
        }

        return models.compactMap { $0["name"] as? String }.sorted()
    }
}
