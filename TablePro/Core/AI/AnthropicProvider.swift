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
        SSEEventStream.make(
            session: session,
            buildRequest: { [self] in
                try buildMessagesRequest(
                    turns: turns,
                    options: options,
                    effort: options.reasoningEffort ?? configuredEffort
                )
            },
            decodeLine: { Self.decodeStreamLine($0) },
            makeState: { AnthropicStreamState() },
            parse: { try Self.parseChunk($0, state: &$1) },
            finalEvents: { state in state.finalUsageEvent().map { [$0] } ?? [] }
        )
    }

    func fetchAvailableModels() async throws -> [AIModelInfo] {
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
            return Self.offlineModels
        }

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]]
        else {
            Self.logger.warning("Anthropic model fetch returned unexpected response; using known models")
            return Self.offlineModels
        }

        let fetched = models.compactMap(Self.decodeModel(_:))
        return fetched.isEmpty ? Self.offlineModels : fetched
    }

    static func decodeModel(_ json: [String: Any]) -> AIModelInfo? {
        guard let id = json["id"] as? String else { return nil }
        let capabilities = json["capabilities"] as? [String: Any]
        return AIModelInfo(
            id: id,
            displayName: json["display_name"] as? String,
            contextWindow: json["max_input_tokens"] as? Int,
            maxOutputTokens: json["max_tokens"] as? Int,
            modalities: [.text, .image],
            reasoning: decodeReasoning(capabilities: capabilities, modelID: id)
        )
    }

    private static func decodeReasoning(capabilities: [String: Any]?, modelID: String) -> AIReasoningSupport? {
        guard let capabilities else { return nil }

        let thinking = capabilities["thinking"] as? [String: Any]
        let types = thinking?["types"] as? [String: Any]
        let adaptiveSupported = supportFlag(types?["adaptive"])
        let enabledSupported = supportFlag(types?["enabled"])

        let effort = capabilities["effort"] as? [String: Any]
        let effortSupported = supportFlag(effort) ?? false
        let levels = effortSupported ? ReasoningEffort.allCases.filter { level in
            supportFlag(effort?[level.anthropicEffortValue]) ?? false
        } : []

        let mode: AIReasoningMode
        if adaptiveSupported == true {
            mode = .adaptive
        } else if enabledSupported == true {
            mode = .budgeted
        } else if supportFlag(thinking) == false {
            mode = .unsupported
        } else {
            return nil
        }

        return AIReasoningSupport(
            mode: mode,
            effortLevels: mode == .budgeted ? [.low, .medium, .high] : uniqueLevels(levels),
            defaultEffort: .medium
        )
    }

    private static func uniqueLevels(_ levels: [ReasoningEffort]) -> [ReasoningEffort] {
        var seen: Set<ReasoningEffort> = []
        return levels.filter { seen.insert($0).inserted }
    }

    private static func supportFlag(_ value: Any?) -> Bool? {
        (value as? [String: Any])?["supported"] as? Bool
    }

    private static let offlineModels: [AIModelInfo] = [
        "claude-opus-5",
        "claude-sonnet-5",
        "claude-fable-5",
        "claude-opus-4-8",
        "claude-opus-4-7",
        "claude-sonnet-4-6",
        "claude-haiku-4-5"
    ].map { AIModelInfo(id: $0) }

    private static let knownModels = offlineModels.map(\.id)

    func testConnection() async throws -> Bool {
        let testModel = model.isEmpty ? (Self.knownModels.first ?? "") : model
        let testTurn = ChatTurnWire(role: .user, blocks: [.text("Hi")])
        let testOptions = ChatTransportOptions(model: testModel, maxOutputTokens: 1)
        let request = try buildMessagesRequest(
            turns: [testTurn],
            options: testOptions,
            stream: false,
            effort: nil
        )

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
        stream: Bool = true,
        effort: ReasoningEffort?
    ) throws -> URLRequest {
        guard let url = URL(string: "\(endpoint)/v1/messages") else {
            throw AIProviderError.invalidEndpoint(endpoint)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let resolvedMaxTokens = options.maxOutputTokens
            ?? effort?.autoScaledMaxOutputTokens
            ?? maxOutputTokens

        let body = try Self.makeRequestBody(
            turns: turns,
            options: options,
            effort: effort,
            maxTokens: resolvedMaxTokens,
            stream: stream
        )

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func makeRequestBody(
        turns: [ChatTurnWire],
        options: ChatTransportOptions,
        effort: ReasoningEffort?,
        maxTokens: Int,
        stream: Bool
    ) throws -> [String: Any] {
        var body: [String: Any] = [
            "model": options.model,
            "max_tokens": maxTokens,
            "stream": stream
        ]

        if let systemPrompt = options.systemPrompt {
            body["system"] = systemPrompt
        }

        if let effort {
            let reasoning = resolvedReasoning(for: options.model)

            if let thinking = thinkingBody(for: effort, reasoning: reasoning, maxTokens: maxTokens) {
                body["thinking"] = thinking
            }

            if reasoning.sendsEffortParameter,
               let wireEffort = reasoning.clampedEffort(effort)?.anthropicEffortValue {
                body["output_config"] = ["effort": wireEffort]
            }
        }

        if !options.tools.isEmpty {
            body["tools"] = try options.tools.map(Self.encodeToolSpec(_:))
        }

        body["messages"] = try turns
            .filter { $0.role != .system }
            .compactMap { try Self.encodeTurn($0) }

        return body
    }

    static func resolvedReasoning(for model: String) -> AIReasoningSupport {
        if let live = AIModelCatalog.shared.reasoning(
            providerTypeID: AIProviderType.claude.rawValue,
            modelID: model
        ) {
            return live
        }
        let capabilities = AnthropicModelCapabilities.resolve(model: model)
        return AIReasoningSupport(
            mode: capabilities.thinkingMode == .adaptive ? .adaptive : .budgeted,
            effortLevels: capabilities.effortLevels,
            defaultEffort: .medium
        )
    }

    private static func thinkingBody(
        for effort: ReasoningEffort,
        reasoning: AIReasoningSupport,
        maxTokens: Int
    ) -> [String: Any]? {
        switch reasoning.mode {
        case .adaptive, .effortOnly:
            return ["type": "adaptive", "display": "summarized"]
        case .budgeted:
            let ceiling = maxTokens - 1
            guard ceiling >= AnthropicModelCapabilities.minimumThinkingBudgetTokens else { return nil }
            let budget = min(effort.anthropicBudgetTokens, ceiling)
            return ["type": "enabled", "budget_tokens": budget]
        case .unsupported:
            return nil
        }
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
            case .toolUse, .toolResult, .reasoning, .image, .sqlWalkthrough:
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
        case .sqlWalkthrough(let walkthrough):
            let text = walkthrough.transcriptText
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
