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
    private let model: String
    private let maxOutputTokens: Int
    private let configuredEffort: ReasoningEffort?
    private let session: URLSession

    init(
        endpoint: String,
        apiKey: String,
        model: String = "",
        maxOutputTokens: Int = 4_096,
        reasoningEffort: ReasoningEffort? = nil
    ) {
        self.endpoint = endpoint.normalizedEndpoint()
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.maxOutputTokens = maxOutputTokens
        self.configuredEffort = reasoningEffort
        self.session = URLSession(configuration: .ephemeral)
    }

    func streamChat(
        turns: [ChatTurnWire],
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

                    var state = AnthropicStreamState()
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard let json = Self.decodeStreamLine(line) else { continue }
                        let events = try Self.parseChunk(json, state: &state)
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

    func fetchAvailableModels() async throws -> [String] {
        guard let url = URL(string: "\(endpoint)/v1/models") else {
            throw AIProviderError.invalidEndpoint(endpoint)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = AIProvider.modelListTimeout
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Self.logger.warning("Anthropic model fetch failed; using known models: \(error.localizedDescription, privacy: .public)")
            return Self.knownModels
        }

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]]
        else {
            Self.logger.warning("Anthropic model fetch returned unexpected response; using known models")
            return Self.knownModels
        }

        let modelIds = models.compactMap { $0["id"] as? String }
        return modelIds.isEmpty ? Self.knownModels : modelIds
    }

    private static let knownModels = [
        "claude-opus-4-7-20260101",
        "claude-sonnet-4-6-20251101",
        "claude-haiku-4-5-20251001",
        "claude-sonnet-4-5-20250929",
        "claude-opus-4-5-20250929"
    ]

    func testConnection() async throws -> Bool {
        let testModel = model.isEmpty ? (Self.knownModels.first ?? "") : model
        let testTurn = ChatTurnWire(role: .user, blocks: [.text("Hi")])
        let testOptions = ChatTransportOptions(model: testModel, maxOutputTokens: 1)
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
        turns: [ChatTurnWire],
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

        let effort = options.reasoningEffort ?? configuredEffort
        let resolvedMaxTokens = options.maxOutputTokens
            ?? effort?.autoScaledMaxOutputTokens
            ?? maxOutputTokens

        var body: [String: Any] = [
            "model": options.model,
            "max_tokens": resolvedMaxTokens,
            "stream": stream
        ]

        if let systemPrompt = options.systemPrompt {
            body["system"] = systemPrompt
        }

        if let effort {
            body["thinking"] = thinkingBody(for: effort, model: options.model, maxTokens: resolvedMaxTokens)
        }

        if !options.tools.isEmpty {
            body["tools"] = try options.tools.map(Self.encodeToolSpec(_:))
        }

        let apiMessages = try turns
            .filter { $0.role != .system }
            .compactMap { try Self.encodeTurn($0) }
        body["messages"] = apiMessages

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func thinkingBody(for effort: ReasoningEffort, model: String, maxTokens: Int) -> [String: Any] {
        if Self.modelSupportsAdaptiveThinking(model) {
            var thinking: [String: Any] = ["type": "adaptive"]
            if let adaptiveEffort = effort.anthropicAdaptiveEffort {
                thinking["effort"] = adaptiveEffort
            }
            return thinking
        }
        let budget = min(effort.anthropicBudgetTokens ?? 4_096, max(maxTokens - 1, 1_024))
        return [
            "type": "enabled",
            "budget_tokens": budget
        ]
    }

    private static func modelSupportsAdaptiveThinking(_ model: String) -> Bool {
        let lowered = model.lowercased()
        if lowered.contains("opus-4-7") || lowered.contains("opus-4.7") { return true }
        if lowered.contains("opus-4-6") || lowered.contains("opus-4.6") { return true }
        if lowered.contains("sonnet-4-6") || lowered.contains("sonnet-4.6") { return true }
        if lowered.contains("haiku-4-5") || lowered.contains("haiku-4.5") { return true }
        return false
    }

    static func decodeStreamLine(_ line: String) -> [String: Any]? {
        guard line.hasPrefix("data: ") else { return nil }
        let jsonString = String(line.dropFirst(6))
        guard jsonString != "[DONE]",
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    static func parseChunk(
        _ json: [String: Any],
        state: inout AnthropicStreamState
    ) throws -> [ChatStreamEvent] {
        guard let type = json["type"] as? String else { return [] }
        switch type {
        case "content_block_start":
            guard let index = json["index"] as? Int,
                  let block = json["content_block"] as? [String: Any] else { return [] }
            let blockType = block["type"] as? String
            switch blockType {
            case "tool_use":
                guard let blockId = block["id"] as? String,
                      let blockName = block["name"] as? String else { return [] }
                state.toolUseIdsByIndex[index] = blockId
                return [.toolUseStart(id: blockId, name: blockName)]
            case "thinking", "redacted_thinking":
                let synthID = "thinking_\(UUID().uuidString.prefix(8))"
                let resolvedType = blockType ?? "thinking"
                state.thinkingIdsByIndex[index] = synthID
                state.thinkingTypeByIndex[index] = resolvedType
                if resolvedType == "redacted_thinking", let initialData = block["data"] as? String {
                    state.thinkingRedactedDataByIndex[index] = initialData
                } else if let initialSignature = block["signature"] as? String {
                    state.thinkingSignatureByIndex[index] = initialSignature
                }
                return [.reasoningStart(id: synthID)]
            default:
                return []
            }
        case "content_block_delta":
            guard let delta = json["delta"] as? [String: Any] else { return [] }
            let deltaType = delta["type"] as? String
            if deltaType == "input_json_delta" {
                guard let index = json["index"] as? Int,
                      let id = state.toolUseIdsByIndex[index],
                      let partial = delta["partial_json"] as? String
                else { return [] }
                return [.toolUseDelta(id: id, inputJSONDelta: partial)]
            }
            if deltaType == "thinking_delta" {
                guard let index = json["index"] as? Int,
                      let id = state.thinkingIdsByIndex[index],
                      let thinking = delta["thinking"] as? String, !thinking.isEmpty
                else { return [] }
                return [.reasoningDelta(id: id, text: thinking)]
            }
            if deltaType == "signature_delta" {
                guard let index = json["index"] as? Int,
                      let signature = delta["signature"] as? String else { return [] }
                state.thinkingSignatureByIndex[index, default: ""] += signature
                return []
            }
            if let text = delta["text"] as? String {
                return [.textDelta(text)]
            }
            return []
        case "content_block_stop":
            guard let index = json["index"] as? Int else { return [] }
            if let toolID = state.toolUseIdsByIndex.removeValue(forKey: index) {
                return [.toolUseEnd(id: toolID)]
            }
            if let thinkingID = state.thinkingIdsByIndex.removeValue(forKey: index) {
                let blockType = state.thinkingTypeByIndex.removeValue(forKey: index) ?? "thinking"
                let payload = blockType == "redacted_thinking"
                    ? state.thinkingRedactedDataByIndex.removeValue(forKey: index) ?? ""
                    : state.thinkingSignatureByIndex.removeValue(forKey: index) ?? ""
                let opaque: ReasoningOpaque? = payload.isEmpty
                    ? nil
                    : ReasoningOpaque(
                        kind: .anthropicSignature,
                        itemID: thinkingID,
                        value: payload,
                        blockType: blockType
                    )
                return [.reasoningEnd(id: thinkingID, opaque: opaque)]
            }
            return []
        case "message_start":
            if let message = json["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any],
               let tokens = usage["input_tokens"] as? Int {
                state.inputTokens = tokens
            }
            return []
        case "message_delta":
            if let usage = json["usage"] as? [String: Any],
               let tokens = usage["output_tokens"] as? Int {
                state.outputTokens = tokens
            }
            return []
        case "error":
            if let errorObj = json["error"] as? [String: Any],
               let message = errorObj["message"] as? String {
                throw AIProviderError.streamingFailed(message)
            }
            return []
        default:
            return []
        }
    }

    static func encodeToolSpec(_ spec: ChatToolSpec) throws -> [String: Any] {
        [
            "name": spec.name,
            "description": spec.description,
            "input_schema": try spec.inputSchema.jsonObject()
        ]
    }

    static func encodeTurn(_ turn: ChatTurnWire) throws -> [String: Any]? {
        let blocks = turn.blocks
        let needsTypedBlocks = blocks.contains { block in
            switch block.kind {
            case .toolUse, .toolResult, .reasoning, .image:
                return true
            case .text, .attachment:
                return false
            }
        }

        if needsTypedBlocks {
            let encoded = try blocks.compactMap { try encodeBlock($0) }
            guard !encoded.isEmpty else { return nil }
            return ["role": turn.role.rawValue, "content": encoded]
        }

        let text = turn.plainText
        guard !text.isEmpty else { return nil }
        return ["role": turn.role.rawValue, "content": text]
    }

    static func encodeBlock(_ block: ChatContentBlockWire) throws -> [String: Any]? {
        switch block.kind {
        case .text(let text):
            guard !text.isEmpty else { return nil }
            return ["type": "text", "text": text]
        case .toolUse(let toolUse):
            return [
                "type": "tool_use",
                "id": toolUse.id,
                "name": toolUse.name,
                "input": try toolUse.input.jsonObject()
            ]
        case .toolResult(let result):
            var encoded: [String: Any] = [
                "type": "tool_result",
                "tool_use_id": result.toolUseId,
                "content": result.content
            ]
            if result.isError {
                encoded["is_error"] = true
            }
            return encoded
        case .attachment:
            return nil
        case .reasoning(let reasoning):
            guard let opaque = reasoning.opaque, opaque.kind == .anthropicSignature else { return nil }
            if opaque.blockType == "redacted_thinking" {
                return ["type": "redacted_thinking", "data": opaque.value]
            }
            return [
                "type": "thinking",
                "thinking": reasoning.text ?? "",
                "signature": opaque.value
            ]
        case .image(let input):
            switch input.source {
            case .cacheFile(let filename, let mediaType):
                guard let data = AIImageCache.shared.read(filename: filename) else { return nil }
                return [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": mediaType,
                        "data": data.base64EncodedString()
                    ] as [String: Any]
                ]
            case .remoteURL(let url, _):
                return [
                    "type": "image",
                    "source": [
                        "type": "url",
                        "url": url.absoluteString
                    ] as [String: Any]
                ]
            }
        }
    }
}

/// Mutable state carried across `AnthropicProvider.parseChunk` calls.
struct AnthropicStreamState {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var toolUseIdsByIndex: [Int: String] = [:]
    var thinkingIdsByIndex: [Int: String] = [:]
    var thinkingTypeByIndex: [Int: String] = [:]
    var thinkingSignatureByIndex: [Int: String] = [:]
    var thinkingRedactedDataByIndex: [Int: String] = [:]

    func finalUsageEvent() -> ChatStreamEvent? {
        guard inputTokens > 0 || outputTokens > 0 else { return nil }
        return .usage(AITokenUsage(inputTokens: inputTokens, outputTokens: outputTokens))
    }
}
