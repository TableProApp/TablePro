//
//  AnthropicProvider.swift
//  TablePro
//

import Foundation
import os
import TableProMCP

final class AnthropicProvider: ChatTransport {
    private static let logger = Logger(subsystem: "com.TablePro", category: "AnthropicProvider")

    private let transport: AIProviderTransport
    private let model: String
    private let maxOutputTokens: Int
    private let configuredEffort: ReasoningEffort?
    private let providerID: UUID?

    init(
        endpoint: String,
        apiKey: String,
        model: String = "",
        maxOutputTokens: Int = 4_096,
        reasoningEffort: ReasoningEffort? = nil,
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
        self.configuredEffort = reasoningEffort
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
                effort: options.reasoningEffort ?? configuredEffort
            )
        }
    }

    func fetchAvailableModels() async throws -> [AIModelInfo] {
        let url = try transport.url(AIEndpointStyle.messages.modelsResource)
        switch await transport.modelList(at: url, key: "data") {
        case .unreachable(let error):
            Self.logger.warning("Anthropic model fetch failed; using known models: \(error.publicLogShape, privacy: .public)")
            return Self.offlineModels
        case .notHTTP:
            Self.logger.warning("Anthropic model fetch returned no HTTP response; using known models")
            return Self.offlineModels
        case .rejected(let reply):
            throw transport.httpError(reply, url: url)
        case .entries(nil):
            Self.logger.warning("Anthropic model fetch returned unexpected response; using known models")
            return Self.offlineModels
        case .entries(let models?):
            let fetched = models.compactMap(Self.decodeModel(_:))
            return fetched.isEmpty ? Self.offlineModels : fetched
        }
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
        guard let reply = try await transport.connectionReply(to: request) else { return false }
        guard reply.statusCode == 200 || reply.statusCode == 400 else {
            throw transport.httpError(reply, url: request.url)
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

        let resolvedMaxTokens = options.maxOutputTokens
            ?? effort?.autoScaledMaxOutputTokens
            ?? maxOutputTokens

        let body = try Self.makeRequestBody(
            turns: turns,
            options: options,
            effort: effort,
            maxTokens: resolvedMaxTokens,
            stream: stream,
            liveReasoning: AIModelCatalog.shared.fetchedInfo(providerID: providerID, modelID: options.model)?.reasoning
        )

        return try transport.post(url, body: body)
    }

    static func makeRequestBody(
        turns: [ChatTurnWire],
        options: ChatTransportOptions,
        effort: ReasoningEffort?,
        maxTokens: Int,
        stream: Bool,
        liveReasoning: AIReasoningSupport? = nil
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
            let reasoning = liveReasoning ?? offlineReasoning(for: options.model)

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

    private static func offlineReasoning(for model: String) -> AIReasoningSupport {
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
