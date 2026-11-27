//
//  AnthropicProvider.swift
//  TablePro
//

import Foundation
import os
import TableProMCP

final class AnthropicProvider: ChatTransport {
    private static let logger = Logger(subsystem: "com.TablePro", category: "AnthropicProvider")

    // A reply's ceiling when nothing else sets one; the model's own limit lowers it.
    static let defaultMaxTokens = 64_000

    private let transport: AIProviderTransport
    private let model: String
    private let maxOutputTokens: Int?
    private let providerID: UUID?

    init(
        endpoint: String,
        apiKey: String,
        model: String = "",
        maxOutputTokens: Int? = nil,
        providerID: UUID? = nil,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) {
        self.transport = AIProviderTransport(
            endpoint: endpoint,
            style: .messages,
            headers: [
                "x-api-key": apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                "anthropic-version": "2023-06-01"
            ],
            session: session
        )
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.maxOutputTokens = maxOutputTokens
        self.providerID = providerID
    }

    func streamChat(
        turns: [ChatTurnWire],
        options: ChatTransportOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        transport.stream(AnthropicStreamWire()) { [self] in
            try buildMessagesRequest(
                turns: turns,
                options: options,
                effort: options.reasoningEffort
            )
        }
    }

    func fetchAvailableModels() async throws -> [AIModelInfo] {
        let url = try transport.url(
            AIEndpointStyle.messages.modelsResource,
            query: [URLQueryItem(name: "limit", value: "1000")]
        )
        switch await transport.modelList(at: url, key: "data") {
        case .unreachable(let error):
            Self.logger.warning("Anthropic model fetch failed: \(error.publicLogShape, privacy: .public)")
            throw AIProviderError.networkError(String(localized: "Failed to fetch models"))
        case .notHTTP, .entries(nil):
            throw AIProviderError.networkError(String(localized: "Failed to fetch models"))
        case .rejected(let reply):
            throw transport.httpError(reply, url: url)
        case .entries(let models?):
            return models.compactMap(Self.decodeModel(_:))
        }
    }

    static func date(_ text: Any?) -> Date? {
        guard let text = text as? String else { return nil }
        return (try? Date(text, strategy: .iso8601)) ?? AIModelReferenceFile.Model.date(String(text.prefix(10)))
    }

    static func decodeModel(_ json: [String: Any]) -> AIModelInfo? {
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        let capabilities = json["capabilities"] as? [String: Any]
        let images = supportFlag(capabilities?["image_input"])
        let lifecycle = json["lifecycle"] as? String
        return AIModelInfo(
            id: id,
            displayName: json["display_name"] as? String,
            contextWindow: json["max_input_tokens"] as? Int,
            maxOutputTokens: json["max_tokens"] as? Int,
            modalities: images.map { $0 ? [.text, .image] : [.text] } ?? [],
            reasoning: decodeReasoning(capabilities: capabilities),
            isDeprecated: lifecycle.map { $0 != "active" } ?? false,
            retiresAt: date(json["retires_at"]),
            released: date(json["created_at"])
        )
    }

    // Adaptive thinking runs at `high` when no effort is sent (Messages API, effort parameter).
    private static func decodeReasoning(capabilities: [String: Any]?) -> AIReasoningSupport? {
        guard let capabilities else { return nil }

        let thinking = capabilities["thinking"] as? [String: Any]
        let types = thinking?["types"] as? [String: Any]
        let disables = supportFlag(types?["disabled"]) ?? false

        if supportFlag(types?["adaptive"]) == true {
            let effort = capabilities["effort"] as? [String: Any]
            let offered = supportFlag(effort) == true
                ? ["low", "medium", "high", "xhigh", "max"].filter { supportFlag(effort?[$0]) == true }
                : []
            return AIReasoningSupport(
                mode: .adaptive,
                effortLevels: ReasoningEffort.levels(fromWire: offered),
                defaultEffort: .high,
                isMandatory: !disables,
                canTurnOff: disables
            )
        }
        if supportFlag(types?["enabled"]) == true {
            return AIReasoningSupport(mode: .budgeted, effortLevels: [.low, .medium, .high])
        }
        return supportFlag(thinking) == false ? .unsupported : nil
    }

    private static func supportFlag(_ value: Any?) -> Bool? {
        (value as? [String: Any])?["supported"] as? Bool
    }

    // A key and Base URL are proven by listing the models, which needs no model id and costs nothing.
    func testConnection() async throws -> Bool {
        let url = try transport.url(
            AIEndpointStyle.messages.modelsResource,
            query: [URLQueryItem(name: "limit", value: "1")]
        )
        guard let reply = try await transport.connectionReply(to: transport.get(url, timeout: nil)) else {
            return false
        }
        guard reply.statusCode == 200 else {
            throw transport.httpError(reply, url: url)
        }
        return true
    }

    func buildMessagesRequest(
        turns: [ChatTurnWire],
        options: ChatTransportOptions,
        stream: Bool = true,
        effort: ReasoningEffort?
    ) throws -> URLRequest {
        let url = try transport.url(AIEndpointStyle.messages.chatResource(model: options.model))
        let info = AIModelCatalog.shared.info(
            providerID: providerID,
            source: AIModelSource(key: AIModelSource.anthropicKey, api: nil, hidesUnknown: false, liveOrdered: true),
            modelID: options.model
        )
        let body = try Self.makeRequestBody(
            turns: turns,
            options: options,
            effort: effort,
            maxTokens: Self.maxTokens(
                requested: options.maxOutputTokens ?? maxOutputTokens,
                effort: effort,
                modelLimit: info?.maxOutputTokens
            ),
            stream: stream,
            reasoning: info?.reasoning
        )
        return try transport.post(url, body: body)
    }

    // The user's own limit first, then one sized for the effort, then the default, never above the model's limit.
    static func maxTokens(requested: Int?, effort: ReasoningEffort?, modelLimit: Int?) -> Int {
        let wanted = requested ?? effort?.autoScaledMaxOutputTokens ?? defaultMaxTokens
        guard let modelLimit, modelLimit > 0 else { return wanted }
        return min(wanted, modelLimit)
    }

    static func makeRequestBody(
        turns: [ChatTurnWire],
        options: ChatTransportOptions,
        effort: ReasoningEffort?,
        maxTokens: Int,
        stream: Bool,
        reasoning: AIReasoningSupport? = nil
    ) throws -> [String: Any] {
        var body: [String: Any] = [
            "model": options.model,
            "max_tokens": maxTokens,
            "stream": stream
        ]

        if let systemPrompt = options.systemPrompt {
            body["system"] = systemPrompt
        }

        if let effort, let reasoning, let effective = reasoning.clampedEffort(effort) {
            if effective == .off {
                body["thinking"] = ["type": "disabled"]
            } else {
                if let thinking = thinkingBody(for: effective, reasoning: reasoning, maxTokens: maxTokens) {
                    body["thinking"] = thinking
                }
                if reasoning.sendsEffortParameter {
                    body["output_config"] = ["effort": effective.wireValue]
                }
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

    // The API refuses a thinking budget under 1,024 tokens.
    private static let minimumThinkingBudgetTokens = 1_024

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
            guard ceiling >= minimumThinkingBudgetTokens else { return nil }
            let budget = min(effort.anthropicBudgetTokens, ceiling)
            return ["type": "enabled", "budget_tokens": budget]
        case .unsupported:
            return nil
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

struct AnthropicStreamWire: ChatStreamWire {
    func parse(_ json: [String: Any], state: inout AnthropicStreamState) -> [ChatStreamEvent] {
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
                return [state.toolCalls.start(index, id: blockId, name: blockName)].compactMap { $0 }
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
                      let id = state.toolCalls.id(for: index),
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
            if let toolEnd = state.toolCalls.end(index) {
                return [toolEnd]
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
            let stopReason = (json["delta"] as? [String: Any])?["stop_reason"] as? String
            if let stopReason, !stopReason.isEmpty {
                state.receivedOutput = true
            }
            switch stopReason {
            case "max_tokens":
                return [.outputLimitReached(.outputTokens)]
            case "model_context_window_exceeded":
                return [.outputLimitReached(.contextWindow)]
            default:
                return []
            }
        case "message_stop":
            state.receivedOutput = true
            return []
        default:
            return []
        }
    }
}

struct AnthropicStreamState: ChatStreamState {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var receivedOutput = false
    var toolCalls = ToolCallTracker<Int>()
    var thinkingIdsByIndex: [Int: String] = [:]
    var thinkingTypeByIndex: [Int: String] = [:]
    var thinkingSignatureByIndex: [Int: String] = [:]
    var thinkingRedactedDataByIndex: [Int: String] = [:]
}
