//
//  GeminiProvider.swift
//  TablePro
//
//  Google Gemini API provider using the Generative Language API with SSE streaming.
//

import Foundation
import os

/// AI provider for Google's Gemini models
final class GeminiProvider: AIProvider {
    private static let logger = Logger(subsystem: "com.TablePro", category: "GeminiProvider")

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
                    let request = try buildStreamRequest(
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

                        guard let data = jsonString.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        // Extract text from candidates[0].content.parts[0].text
                        if let candidates = json["candidates"] as? [[String: Any]],
                           let firstCandidate = candidates.first,
                           let content = firstCandidate["content"] as? [String: Any],
                           let parts = content["parts"] as? [[String: Any]],
                           let firstPart = parts.first,
                           let text = firstPart["text"] as? String {
                            continuation.yield(.text(text))
                        }

                        // Extract usage from usageMetadata
                        if let usageMetadata = json["usageMetadata"] as? [String: Any] {
                            if let prompt = usageMetadata["promptTokenCount"] as? Int {
                                inputTokens = prompt
                            }
                            if let candidates = usageMetadata["candidatesTokenCount"] as? Int {
                                outputTokens = candidates
                            }
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
        guard let url = URL(string: "\(endpoint)/v1beta/models?key=\(apiKey)") else {
            throw AIProviderError.invalidEndpoint(endpoint)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            throw mapHTTPError(
                statusCode: httpResponse.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else {
            return []
        }

        return models.compactMap { model -> String? in
            guard let name = model["name"] as? String,
                  let methods = model["supportedGenerationMethods"] as? [String],
                  methods.contains("generateContent")
            else { return nil }
            // Strip "models/" prefix: "models/gemini-2.0-flash" → "gemini-2.0-flash"
            if name.hasPrefix("models/") {
                return String(name.dropFirst(7))
            }
            return name
        }
    }

    func testConnection() async throws -> Bool {
        guard let url = URL(string: "\(endpoint)/v1beta/models?key=\(apiKey)") else {
            throw AIProviderError.invalidEndpoint(endpoint)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            return false
        }

        let statusCode = httpResponse.statusCode

        if statusCode == 401 || statusCode == 403 {
            throw AIProviderError.authenticationFailed("")
        }

        guard statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw mapHTTPError(statusCode: statusCode, body: body)
        }

        return true
    }

    // MARK: - Private

    private func buildStreamRequest(
        messages: [AIChatMessage],
        model: String,
        systemPrompt: String?
    ) throws -> URLRequest {
        guard let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(
            string: "\(endpoint)/v1beta/models/\(encodedModel):streamGenerateContent?alt=sse&key=\(apiKey)"
        ) else {
            throw AIProviderError.invalidEndpoint(endpoint)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "generationConfig": ["maxOutputTokens": 8_192]
        ]

        if let systemPrompt, !systemPrompt.isEmpty {
            body["systemInstruction"] = ["parts": [["text": systemPrompt]]]
        }

        // Convert messages — Gemini uses "user" and "model" roles (not "assistant")
        let contents = messages
            .filter { $0.role != .system }
            .map { message -> [String: Any] in
                let role = message.role == .assistant ? "model" : "user"
                return [
                    "role": role,
                    "parts": [["text": message.content]]
                ]
            }
        body["contents"] = contents

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

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
        case 401, 403:
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
