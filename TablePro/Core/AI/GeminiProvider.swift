//
//  GeminiProvider.swift
//  TablePro
//

import Foundation
import os

final class GeminiProvider: ChatTransport {
    private static let logger = Logger(subsystem: "com.TablePro", category: "GeminiProvider")

    private let endpoint: String
    private let apiKey: String
    private let maxOutputTokens: Int
    private let session: URLSession

    init(endpoint: String, apiKey: String, maxOutputTokens: Int = 8_192) {
        self.endpoint = endpoint.normalizedEndpoint()
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.maxOutputTokens = maxOutputTokens
        self.session = URLSession(configuration: .ephemeral)
    }

    func streamChat(
        turns: [ChatTurnWire],
        options: ChatTransportOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try buildStreamRequest(turns: turns, options: options)
                    let (bytes, response) = try await session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw AIProviderError.networkError("Invalid response")
                    }

                    guard httpResponse.statusCode == 200 else {
                        let errorBody = try await collectErrorBody(from: bytes)
                        throw AIProviderError.mapHTTPError(
                            statusCode: httpResponse.statusCode,
                            body: errorBody,
                            treatForbiddenAsAuthFailure: true
                        )
                    }

                    var state = GeminiStreamState()
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard let json = Self.decodeStreamLine(line) else { continue }
                        let events = Self.parseChunk(
                            json,
                            state: &state,
                            idGenerator: { UUID().uuidString }
                        )
                        for event in events { continuation.yield(event) }
                    }
                    if let usage = state.finalUsageEvent() {
                        continuation.yield(usage)
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

    private static let knownModels = [
        "gemini-2.5-flash",
        "gemini-2.5-pro",
        "gemini-2.0-flash",
        "gemini-1.5-flash",
        "gemini-1.5-pro"
    ]

    func fetchAvailableModels() async throws -> [String] {
        guard let url = URL(string: "\(endpoint)/v1beta/models") else {
            throw AIProviderError.invalidEndpoint(endpoint)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = AIProvider.modelListTimeout
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Self.logger.warning("Gemini model fetch failed; using known models: \(error.localizedDescription, privacy: .public)")
            return Self.knownModels
        }

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else {
            Self.logger.warning("Gemini model fetch returned unexpected response; using known models")
            return Self.knownModels
        }

        let fetched = models.compactMap { model -> String? in
            guard let name = model["name"] as? String,
                  let methods = model["supportedGenerationMethods"] as? [String],
                  methods.contains("generateContent")
            else { return nil }
            if name.hasPrefix("models/") {
                return String(name.dropFirst(7))
            }
            return name
        }

        return fetched.isEmpty ? Self.knownModels : fetched
    }

    func testConnection() async throws -> Bool {
        guard let url = URL(string: "\(endpoint)/v1beta/models") else {
            throw AIProviderError.invalidEndpoint(endpoint)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

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
            throw AIProviderError.mapHTTPError(
                statusCode: statusCode,
                body: body,
                treatForbiddenAsAuthFailure: true
            )
        }

        return true
    }

    private func buildStreamRequest(
        turns: [ChatTurnWire],
        options: ChatTransportOptions
    ) throws -> URLRequest {
        guard let encodedModel = options.model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(
            string: "\(endpoint)/v1beta/models/\(encodedModel):streamGenerateContent?alt=sse"
        ) else {
            throw AIProviderError.invalidEndpoint(endpoint)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        var body: [String: Any] = [
            "generationConfig": ["maxOutputTokens": options.maxOutputTokens ?? maxOutputTokens]
        ]

        if let systemPrompt = options.systemPrompt, !systemPrompt.isEmpty {
            body["systemInstruction"] = ["parts": [["text": systemPrompt]]]
        }

        if !options.tools.isEmpty {
            let declarations = try options.tools.map { tool -> [String: Any] in
                var entry: [String: Any] = [
                    "name": tool.name,
                    "description": tool.description
                ]
                entry["parameters"] = try tool.inputSchema.jsonObject()
                return entry
            }
            body["tools"] = [["functionDeclarations": declarations]]
        }

        body["contents"] = encodeContents(turns: turns)

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func encodeContents(turns: [ChatTurnWire]) -> [[String: Any]] {
        var encoded: [[String: Any]] = []
        for (index, turn) in turns.enumerated() where turn.role != .system {
            let priorTurns = Array(turns.prefix(index))
            guard let entry = encodeTurn(turn, priorTurns: priorTurns) else { continue }
            encoded.append(entry)
        }
        return encoded
    }

    func encodeTurn(_ turn: ChatTurnWire, priorTurns: [ChatTurnWire]) -> [String: Any]? {
        let role = turn.role == .assistant ? "model" : "user"
        var parts: [[String: Any]] = []

        for block in turn.blocks {
            switch block.kind {
            case .text(let text):
                guard !text.isEmpty else { continue }
                parts.append(["text": text])
            case .attachment:
                continue
            case .toolUse(let useBlock):
                let argsObject = (try? useBlock.input.jsonObject()) ?? [String: Any]()
                parts.append([
                    "functionCall": [
                        "name": useBlock.name,
                        "args": argsObject
                    ]
                ])
            case .toolResult(let resultBlock):
                let toolName = resolveToolName(
                    forToolUseId: resultBlock.toolUseId,
                    in: priorTurns
                ) ?? resultBlock.toolUseId
                parts.append([
                    "functionResponse": [
                        "name": toolName,
                        "response": ["content": resultBlock.content]
                    ]
                ])
            }
        }

        if parts.isEmpty {
            let fallback = turn.plainText
            guard !fallback.isEmpty else { return nil }
            parts.append(["text": fallback])
        }

        return ["role": role, "parts": parts]
    }

    func resolveToolName(forToolUseId id: String, in priorTurns: [ChatTurnWire]) -> String? {
        for turn in priorTurns.reversed() {
            for block in turn.blocks {
                if case .toolUse(let useBlock) = block.kind, useBlock.id == id {
                    return useBlock.name
                }
            }
        }
        return nil
    }

    /// Decodes one Gemini SSE line. Returns nil for non-data lines.
    static func decodeStreamLine(_ line: String) -> [String: Any]? {
        guard line.hasPrefix("data: ") else { return nil }
        let jsonString = String(line.dropFirst(6))
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    /// Translate a single Gemini chunk to events.
    ///
    /// Gemini does not provide tool-call ids on `functionCall` parts, so we
    /// synthesize one per call. `idGenerator` is injected so tests can pin the
    /// synthetic id to a stable value; production passes `{ UUID().uuidString }`.
    /// Each call to `idGenerator()` returns a fresh id, so multiple
    /// `functionCall` parts in one chunk get distinct ids in production.
    static func parseChunk(
        _ json: [String: Any],
        state: inout GeminiStreamState,
        idGenerator: () -> String
    ) -> [ChatStreamEvent] {
        var events: [ChatStreamEvent] = []
        if let candidates = json["candidates"] as? [[String: Any]],
           let firstCandidate = candidates.first,
           let content = firstCandidate["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]] {
            for part in parts {
                if let text = part["text"] as? String, !text.isEmpty {
                    events.append(.textDelta(text))
                }
                if let functionCall = part["functionCall"] as? [String: Any],
                   let name = functionCall["name"] as? String {
                    let id = idGenerator()
                    let argsObject = functionCall["args"] ?? [String: Any]()
                    let argsString = encodeArgsToJSONString(argsObject)
                    events.append(.toolUseStart(id: id, name: name))
                    events.append(.toolUseDelta(id: id, inputJSONDelta: argsString))
                    events.append(.toolUseEnd(id: id))
                }
            }
        }
        if let usageMetadata = json["usageMetadata"] as? [String: Any] {
            if let prompt = usageMetadata["promptTokenCount"] as? Int {
                state.inputTokens = prompt
            }
            if let candidates = usageMetadata["candidatesTokenCount"] as? Int {
                state.outputTokens = candidates
            }
        }
        return events
    }

    static func encodeArgsToJSONString(_ args: Any) -> String {
        guard JSONSerialization.isValidJSONObject(args) else {
            Self.logger.warning("Gemini functionCall args was not a valid JSON object; falling back to empty input")
            return "{}"
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: args)
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            Self.logger.warning("Gemini functionCall args serialization failed: \(error.localizedDescription, privacy: .public)")
            return "{}"
        }
    }
}

/// Mutable state carried across `GeminiProvider.parseChunk` calls.
struct GeminiStreamState {
    var inputTokens: Int = 0
    var outputTokens: Int = 0

    func finalUsageEvent() -> ChatStreamEvent? {
        guard inputTokens > 0 || outputTokens > 0 else { return nil }
        return .usage(AITokenUsage(inputTokens: inputTokens, outputTokens: outputTokens))
    }
}
