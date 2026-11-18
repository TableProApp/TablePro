//
//  OpenAICompatibleProvider.swift
//  TablePro
//

import Foundation
import os
import TableProMCP

final class OpenAICompatibleProvider: ChatTransport {
    private static let logger = Logger(
        subsystem: "com.TablePro",
        category: "OpenAICompatibleProvider"
    )

    private let transport: AIProviderTransport
    private let style: AIEndpointStyle
    private let providerType: AIProviderType
    private let model: String
    private let maxOutputTokens: Int?
    private let modelIDs: AIModelIDFilter
    private let providerID: UUID?
    private let catalog: AIModelCatalog
    private var testConnectionModel: String {
        model.isEmpty ? "test" : model
    }

    init(
        endpoint: String,
        apiKey: String?,
        providerType: AIProviderType,
        model: String = "",
        maxOutputTokens: Int? = nil,
        treatsForbiddenAsAuthFailure: Bool = false,
        modelIDs: AIModelIDFilter = .all,
        providerID: UUID? = nil,
        catalog: AIModelCatalog = .shared,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) {
        let style = providerType.endpointStyle
        self.transport = AIProviderTransport(
            endpoint: endpoint,
            style: style,
            headers: AIProviderTransport.bearer(apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)),
            forbiddenIsAuthFailure: treatsForbiddenAsAuthFailure,
            session: session
        )
        self.style = style
        self.providerType = providerType
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.maxOutputTokens = maxOutputTokens
        self.modelIDs = modelIDs
        self.providerID = providerID
        self.catalog = catalog
    }

    convenience init(
        config: AIProviderConfig,
        apiKey: String?,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) {
        self.init(
            endpoint: config.endpoint,
            apiKey: apiKey,
            providerType: config.type,
            model: config.model,
            maxOutputTokens: config.maxOutputTokens,
            treatsForbiddenAsAuthFailure: config.preset?.rejectsBadKeyWithForbidden ?? false,
            modelIDs: config.preset?.modelIDFilter(forEndpoint: config.endpoint) ?? .all,
            providerID: config.id,
            session: session
        )
    }

    func streamChat(
        turns: [ChatTurnWire],
        options: ChatTransportOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        transport.stream(ChatCompletionsStreamWire(ollama: providerType == .ollama)) { [self] in
            try buildChatCompletionRequest(turns: turns, options: options)
        }
    }

    func fetchAvailableModels() async throws -> [AIModelInfo] {
        guard providerType == .ollama else { return try await fetchOpenAIModels() }
        return try await fetchOllamaModels().map { AIModelInfo(id: $0) }
    }

    func testConnection() async throws -> Bool {
        switch providerType {
        case .ollama:
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
                    String(format: String(localized: "Cannot connect to Ollama at %@. Is Ollama running?"), transport.configuredEndpoint)
                )
            } catch {
                throw AIProviderError.networkError(
                    String(format: String(localized: "Cannot connect to Ollama at %@. Is Ollama running?"), transport.configuredEndpoint)
                )
            }
        default:
            let url = try transport.url(style.chatResource(model: testConnectionModel))
            let request = try transport.post(url, body: [
                "model": testConnectionModel,
                "messages": [["role": "user", "content": "Hi"]],
                "max_tokens": 1,
                "stream": false,
            ])
            guard let reply = try await transport.connectionReply(to: request) else { return false }

            if reply.statusCode == 200 || reply.statusCode == 400 {
                return Self.looksLikeAnAPIResponse(reply)
            }

            // The placeholder model is unknown by design; that answer proves the route and the key.
            if model.isEmpty, reply.statusCode == 404, Self.isUnknownModelError(reply.data) {
                return true
            }

            throw transport.httpError(reply, url: url)
        }
    }

    private static func isUnknownModelError(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any]
        else { return false }
        return error["code"] as? String == "model_not_found"
    }

    // A wrong Base URL often lands on a login page or a single-page app's fallback route, both 200 with HTML.
    private static func looksLikeAnAPIResponse(_ reply: AIHTTPReply) -> Bool {
        let contentType = reply.response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if contentType.contains("application/json") || contentType.contains("text/event-stream") {
            return true
        }
        return (try? JSONSerialization.jsonObject(with: reply.data)) != nil
    }

    func buildChatCompletionRequest(
        turns: [ChatTurnWire],
        options: ChatTransportOptions
    ) throws -> URLRequest {
        let url = try transport.url(style.chatResource(model: options.model))

        var apiMessages: [[String: Any]] = []
        if let systemPrompt = options.systemPrompt {
            apiMessages.append(["role": "system", "content": systemPrompt])
        }
        for turn in turns where turn.role != .system {
            apiMessages.append(contentsOf: encodeTurn(turn))
        }

        var body: [String: Any] = [
            "model": options.model,
            "messages": apiMessages,
            "stream": true
        ]

        let resolvedMaxTokens = options.maxOutputTokens ?? maxOutputTokens
        if let resolvedMaxTokens {
            // Ollama's native route reads the limit from `options` and ignores a top-level `max_tokens`.
            if providerType == .ollama {
                body["options"] = ["num_predict": resolvedMaxTokens]
            } else {
                body["max_tokens"] = resolvedMaxTokens
            }
        }

        if providerType != .ollama {
            body["stream_options"] = ["include_usage": true]
        }

        if let effort = options.reasoningEffort, acceptsReasoningEffort(model: options.model) {
            body["reasoning_effort"] = effort.openAIWireValue
        }

        if !options.tools.isEmpty {
            body["tools"] = try options.tools.map { try encodeTool($0) }
        }

        return try transport.post(url, body: body)
    }

    // Withheld only from a model its own server lists as non-reasoning; silence is taken at the user's word.
    private func acceptsReasoningEffort(model: String) -> Bool {
        guard providerType != .ollama else { return false }
        guard let reasoning = catalog.fetchedInfo(providerID: providerID, modelID: model)?.reasoning else {
            return true
        }
        return reasoning.sendsEffortParameter
    }

    func encodeTurn(_ turn: ChatTurnWire) -> [[String: Any]] {
        let toolUseBlocks = turn.blocks.compactMap { block -> ToolUseBlock? in
            if case .toolUse(let useBlock) = block.kind { return useBlock }
            return nil
        }
        let toolResultBlocks = turn.blocks.compactMap { block -> ToolResultBlock? in
            if case .toolResult(let resultBlock) = block.kind { return resultBlock }
            return nil
        }
        let imageBlocks = turn.blocks.compactMap { block -> ChatImageInput? in
            if case .image(let input) = block.kind { return input }
            return nil
        }
        let walkthroughText = turn.blocks.compactMap { block -> String? in
            guard case .sqlWalkthrough(let walkthrough) = block.kind else { return nil }
            let text = walkthrough.transcriptText
            return text.isEmpty ? nil : text
        }.joined(separator: "\n")
        let textContent = [turn.plainText, walkthroughText]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        if turn.role == .assistant, !toolUseBlocks.isEmpty {
            var message: [String: Any] = ["role": "assistant"]
            if textContent.isEmpty {
                message["content"] = NSNull()
            } else {
                message["content"] = textContent
            }
            message["tool_calls"] = toolUseBlocks.map { block -> [String: Any] in
                [
                    "id": block.id,
                    "type": "function",
                    "function": [
                        "name": block.name,
                        "arguments": block.input.jsonString()
                    ]
                ]
            }
            let reasoningText = Self.plainReasoningText(from: turn)
            if !reasoningText.isEmpty {
                message["reasoning_content"] = reasoningText
            }
            return [message]
        }

        if turn.role == .user, !toolResultBlocks.isEmpty {
            var messages: [[String: Any]] = toolResultBlocks.map { block in
                [
                    "role": "tool",
                    "tool_call_id": block.toolUseId,
                    "content": block.content
                ]
            }
            if !textContent.isEmpty {
                messages.append([
                    "role": "user",
                    "content": textContent
                ])
            }
            return messages
        }

        if turn.role == .user, !imageBlocks.isEmpty, providerType == .ollama {
            return ollamaImageMessage(text: textContent, images: imageBlocks)
        }

        if turn.role == .user, !imageBlocks.isEmpty {
            var parts: [[String: Any]] = []
            if !textContent.isEmpty {
                parts.append(["type": "text", "text": textContent])
            }
            for image in imageBlocks {
                if let part = chatCompletionsImagePart(image) {
                    parts.append(part)
                }
            }
            guard !parts.isEmpty else { return [] }
            return [[
                "role": "user",
                "content": parts
            ]]
        }

        guard !textContent.isEmpty else { return [] }
        var message: [String: Any] = [
            "role": turn.role.rawValue,
            "content": textContent
        ]
        if turn.role == .assistant {
            let reasoningText = Self.plainReasoningText(from: turn)
            if !reasoningText.isEmpty {
                message["reasoning_content"] = reasoningText
            }
        }
        return [message]
    }

    private static func plainReasoningText(from turn: ChatTurnWire) -> String {
        turn.blocks.compactMap { block -> String? in
            guard case .reasoning(let rb) = block.kind,
                  rb.opaque == nil,
                  let text = rb.text else { return nil }
            return text
        }.joined()
    }

    // Ollama's native route takes a string `content` with base64 images beside it, not a content-part array.
    private func ollamaImageMessage(text: String, images: [ChatImageInput]) -> [[String: Any]] {
        let payloads = images.compactMap { $0.base64Payload() }
        guard !text.isEmpty || !payloads.isEmpty else { return [] }
        var message: [String: Any] = ["role": "user", "content": text]
        if !payloads.isEmpty {
            message["images"] = payloads
        }
        return [message]
    }

    private func chatCompletionsImagePart(_ input: ChatImageInput) -> [String: Any]? {
        guard let url = input.imageURLString() else { return nil }
        return [
            "type": "image_url",
            "image_url": [
                "url": url,
                "detail": input.detailHint.rawValue
            ] as [String: Any]
        ]
    }

    func encodeTool(_ tool: ChatToolSpec) throws -> [String: Any] {
        let parameters = try tool.inputSchema.jsonObject()
        return [
            "type": "function",
            "function": [
                "name": tool.name,
                "description": tool.description,
                "parameters": parameters
            ]
        ]
    }

    private func fetchOpenAIModels() async throws -> [AIModelInfo] {
        let url = try transport.url(style.modelsResource)
        let failed = {
            AIProviderError.networkError(
                String(format: String(localized: "Failed to fetch models from %@"), url.absoluteString)
            )
        }
        switch await transport.modelList(at: url, key: "data") {
        case .unreachable(let error):
            Self.logger.warning("OpenAI-compatible model fetch failed: \(error.publicLogShape, privacy: .public)")
            throw failed()
        case .notHTTP, .entries(nil):
            throw failed()
        case .rejected(let reply):
            throw transport.httpError(reply, url: url)
        case .entries(let modelsArray?):
            return modelsArray.compactMap(Self.decodeModel(_:))
                .filter { modelIDs.lists($0.id) }
                .sorted { $0.id < $1.id }
        }
    }

    private func fetchOllamaModels() async throws -> [String] {
        let url = try transport.url(style.modelsResource)
        let endpoint = transport.configuredEndpoint
        switch await transport.modelList(at: url, key: "models", authenticated: false) {
        case .unreachable(let error):
            Self.logger.warning("Ollama model fetch failed: \(error.publicLogShape, privacy: .public)")
            throw AIProviderError.networkError(
                String(format: String(localized: "Failed to fetch models from %@"), endpoint)
            )
        case .notHTTP:
            throw AIProviderError.networkError(
                String(format: String(localized: "Failed to fetch models from %@ (HTTP %d)"), endpoint, 0)
            )
        case .rejected(let reply):
            throw AIProviderError.networkError(
                String(format: String(localized: "Failed to fetch models from %@ (HTTP %d)"), endpoint, reply.statusCode)
            )
        case .entries(nil):
            throw AIProviderError.networkError(
                String(format: String(localized: "Failed to fetch models from %@"), url.absoluteString)
            )
        case .entries(let models?):
            return models.compactMap { $0["name"] as? String }.sorted()
        }
    }
}

struct ChatCompletionsStreamWire: ChatStreamWire {
    // Ollama's native route streams one JSON object per line, not server-sent events.
    let ollama: Bool

    func decodeLine(_ line: String) -> [String: Any]? {
        guard ollama else { return SSEEventStream.jsonPayload(line) }
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    func parse(_ json: [String: Any], state: inout OpenAIStreamState) -> [ChatStreamEvent] {
        var events: [ChatStreamEvent] = []
        let choices = json["choices"] as? [[String: Any]]
        let firstChoice = choices?.first
        let delta = firstChoice?["delta"] as? [String: Any]

        if let delta, let reasoningContent = delta["reasoning_content"] as? String, !reasoningContent.isEmpty {
            let reasoningID: String
            if let existing = state.reasoningBlockID {
                reasoningID = existing
            } else {
                let newID = "reasoning_\(UUID().uuidString.prefix(8))"
                state.reasoningBlockID = newID
                events.append(.reasoningStart(id: newID))
                reasoningID = newID
            }
            events.append(.reasoningDelta(id: reasoningID, text: reasoningContent))
        }

        if let delta, let content = delta["content"] as? String, !content.isEmpty {
            events.append(.textDelta(content))
        } else if let message = json["message"] as? [String: Any],
                  let content = message["content"] as? String,
                  !content.isEmpty {
            events.append(.textDelta(content))
        }

        if let delta, let toolCalls = delta["tool_calls"] as? [[String: Any]] {
            events.append(contentsOf: Self.toolCallDeltas(toolCalls, state: &state))
        } else if let message = json["message"] as? [String: Any],
                  let toolCalls = message["tool_calls"] as? [[String: Any]] {
            events.append(contentsOf: Self.ollamaToolCalls(toolCalls, state: &state))
        }

        if let finishReason = firstChoice?["finish_reason"] as? String, !finishReason.isEmpty {
            if let event = state.flushReasoningEnd() {
                events.append(event)
            }
            if finishReason == "tool_calls" {
                events.append(contentsOf: state.toolCalls.endAll())
            }
            if finishReason == "length" {
                events.append(.outputLimitReached(.outputTokens))
            }
            state.receivedOutput = true
        }
        // Ollama's own API names the cut in `done_reason`.
        if (json["done"] as? Bool) == true, (json["done_reason"] as? String) == "length" {
            events.append(.outputLimitReached(.outputTokens))
        }

        if let usage = json["usage"] as? [String: Any],
           let promptTokens = usage["prompt_tokens"] as? Int,
           let completionTokens = usage["completion_tokens"] as? Int {
            state.inputTokens = promptTokens
            state.outputTokens = completionTokens
        } else if let done = json["done"] as? Bool, done,
                  let promptEval = json["prompt_eval_count"] as? Int,
                  let evalCount = json["eval_count"] as? Int {
            state.inputTokens = promptEval
            state.outputTokens = evalCount
        }

        if (json["done"] as? Bool) == true {
            events.append(contentsOf: state.toolCalls.endAll())
            state.receivedOutput = true
        }
        return events
    }

    func closingEvents(_ state: inout OpenAIStreamState) -> [ChatStreamEvent] {
        [state.flushReasoningEnd()].compactMap { $0 }
    }

    private static func toolCallDeltas(
        _ toolCalls: [[String: Any]],
        state: inout OpenAIStreamState
    ) -> [ChatStreamEvent] {
        var events: [ChatStreamEvent] = []
        for toolCall in toolCalls {
            guard let index = toolCall["index"] as? Int else { continue }
            let function = toolCall["function"] as? [String: Any]
            if state.toolCalls.id(for: index) == nil {
                let id = (toolCall["id"] as? String)
                    ?? "call_\(index)_\(UUID().uuidString.prefix(8))"
                let name = (function?["name"] as? String) ?? ""
                if let start = state.toolCalls.start(index, id: id, name: name) {
                    events.append(start)
                }
            }
            if let id = state.toolCalls.id(for: index),
               let arguments = function?["arguments"] as? String,
               !arguments.isEmpty {
                events.append(.toolUseDelta(id: id, inputJSONDelta: arguments))
            }
        }
        return events
    }

    private static func ollamaToolCalls(
        _ toolCalls: [[String: Any]],
        state: inout OpenAIStreamState
    ) -> [ChatStreamEvent] {
        var events: [ChatStreamEvent] = []
        for (offset, toolCall) in toolCalls.enumerated() {
            guard let function = toolCall["function"] as? [String: Any],
                  let name = function["name"] as? String else { continue }
            let index = (toolCall["index"] as? Int) ?? offset
            let id = (toolCall["id"] as? String)
                ?? "call_\(index)_\(UUID().uuidString.prefix(8))"
            if let start = state.toolCalls.start(index, id: id, name: name) {
                events.append(start)
            }
            let argumentsString: String
            if let stringArgs = function["arguments"] as? String {
                argumentsString = stringArgs
            } else if let objectArgs = function["arguments"],
                      let data = try? JSONSerialization.data(withJSONObject: objectArgs),
                      let encoded = String(data: data, encoding: .utf8) {
                argumentsString = encoded
            } else {
                argumentsString = ""
            }
            if !argumentsString.isEmpty, let resolvedId = state.toolCalls.id(for: index) {
                events.append(.toolUseDelta(id: resolvedId, inputJSONDelta: argumentsString))
            }
        }
        return events
    }
}

struct OpenAIStreamState: ChatStreamState {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var receivedOutput = false
    var toolCalls = ToolCallTracker<Int>()
    var reasoningBlockID: String?

    mutating func flushReasoningEnd() -> ChatStreamEvent? {
        guard let id = reasoningBlockID else { return nil }
        reasoningBlockID = nil
        return .reasoningEnd(id: id, opaque: nil)
    }
}
