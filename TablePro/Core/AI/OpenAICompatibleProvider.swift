//
//  OpenAICompatibleProvider.swift
//  TablePro
//

import Foundation
import os

final class OpenAICompatibleProvider: ChatTransport {
    private static let logger = Logger(
        subsystem: "com.TablePro",
        category: "OpenAICompatibleProvider"
    )

    private let endpoint: String
    private let apiKey: String?
    private let providerType: AIProviderType
    private let model: String
    private let maxOutputTokens: Int?
    private let session: URLSession
    private var testConnectionModel: String {
        model.isEmpty ? "test" : model
    }

    init(
        endpoint: String,
        apiKey: String?,
        providerType: AIProviderType,
        model: String = "",
        maxOutputTokens: Int? = nil,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) {
        self.endpoint = endpoint.normalizedEndpoint()
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.providerType = providerType
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.maxOutputTokens = maxOutputTokens
        self.session = session
    }

    func streamChat(
        turns: [ChatTurnWire],
        options: ChatTransportOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try buildChatCompletionRequest(turns: turns, options: options)
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

                    var state = OpenAIStreamState()
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard let json = Self.decodeStreamLine(line, providerType: self.providerType) else {
                            if line == "data: [DONE]" { break }
                            continue
                        }
                        let result = Self.parseChunk(json, state: &state)
                        for event in result.events { continuation.yield(event) }
                        if result.shouldBreak { break }
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

    /// Decodes one streaming line. OpenAI/OpenRouter/Custom use SSE framing
    /// (`data: {...}`); Ollama emits NDJSON (one JSON object per line). The
    /// `[DONE]` sentinel returns nil; the caller should break on it.
    static func decodeStreamLine(_ line: String, providerType: AIProviderType) -> [String: Any]? {
        let jsonString: String
        if providerType == .ollama {
            guard !line.isEmpty else { return nil }
            jsonString = line
        } else {
            guard line.hasPrefix("data: ") else { return nil }
            let payload = String(line.dropFirst(6))
            guard payload != "[DONE]" else { return nil }
            jsonString = payload
        }
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    /// Translate one chunk JSON to events. Mutates state to thread tool-call
    /// index→id mapping, ordering, and token counters across chunks.
    /// Returns `(events, shouldBreak)` so the caller can stop the stream when
    /// Ollama emits `done: true`.
    static func parseChunk(
        _ json: [String: Any],
        state: inout OpenAIStreamState
    ) -> (events: [ChatStreamEvent], shouldBreak: Bool) {
        var events: [ChatStreamEvent] = []
        let choices = json["choices"] as? [[String: Any]]
        let firstChoice = choices?.first
        let delta = firstChoice?["delta"] as? [String: Any]

        if let delta, let content = delta["content"] as? String, !content.isEmpty {
            events.append(.textDelta(content))
        } else if let message = json["message"] as? [String: Any],
                  let content = message["content"] as? String,
                  !content.isEmpty {
            events.append(.textDelta(content))
        }

        if let delta, let toolCalls = delta["tool_calls"] as? [[String: Any]] {
            events.append(contentsOf: handleToolCallDeltas(toolCalls, state: &state))
        } else if let message = json["message"] as? [String: Any],
                  let toolCalls = message["tool_calls"] as? [[String: Any]] {
            events.append(contentsOf: handleOllamaToolCalls(toolCalls, state: &state))
        }

        if let finishReason = firstChoice?["finish_reason"] as? String,
           finishReason == "tool_calls" {
            events.append(contentsOf: state.flushToolUseEnds())
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

        // Ollama signals stream-end via `done: true`. We flush again here only
        // when finish_reason didn't already drain the tool-call map (which
        // typically isn't set on Ollama responses).
        let shouldBreak = (json["done"] as? Bool) == true
        if shouldBreak, !state.toolCallIndexToId.isEmpty {
            events.append(contentsOf: state.flushToolUseEnds())
        }
        return (events, shouldBreak)
    }

    private static func handleToolCallDeltas(
        _ toolCalls: [[String: Any]],
        state: inout OpenAIStreamState
    ) -> [ChatStreamEvent] {
        var events: [ChatStreamEvent] = []
        for toolCall in toolCalls {
            guard let index = toolCall["index"] as? Int else { continue }
            let function = toolCall["function"] as? [String: Any]
            if state.toolCallIndexToId[index] == nil {
                let id = (toolCall["id"] as? String)
                    ?? "call_\(index)_\(UUID().uuidString.prefix(8))"
                let name = (function?["name"] as? String) ?? ""
                state.toolCallIndexToId[index] = id
                state.toolCallOrder.append(index)
                events.append(.toolUseStart(id: id, name: name))
            }
            if let id = state.toolCallIndexToId[index],
               let arguments = function?["arguments"] as? String,
               !arguments.isEmpty {
                events.append(.toolUseDelta(id: id, inputJSONDelta: arguments))
            }
        }
        return events
    }

    private static func handleOllamaToolCalls(
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
            if state.toolCallIndexToId[index] == nil {
                state.toolCallIndexToId[index] = id
                state.toolCallOrder.append(index)
                events.append(.toolUseStart(id: id, name: name))
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
            if !argumentsString.isEmpty, let resolvedId = state.toolCallIndexToId[index] {
                events.append(.toolUseDelta(id: resolvedId, inputJSONDelta: argumentsString))
            }
        }
        return events
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
                "model": testConnectionModel,
                "messages": [["role": "user", "content": "Hi"]],
                "max_tokens": 1,
                "stream": false,
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }

            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
            let isJSON = contentType.contains("application/json")
                || (try? JSONSerialization.jsonObject(with: data)) != nil

            if httpResponse.statusCode == 401 {
                throw AIProviderError.authenticationFailed("")
            }

            if !isJSON {
                return false
            }

            return true
        }
    }

    private func buildChatCompletionRequest(
        turns: [ChatTurnWire],
        options: ChatTransportOptions
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
            body["max_tokens"] = resolvedMaxTokens
        }

        if providerType != .ollama {
            body["stream_options"] = ["include_usage": true]
        }

        if !options.tools.isEmpty {
            body["tools"] = try options.tools.map { try encodeTool($0) }
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
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
        let textContent = turn.plainText

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

        guard !textContent.isEmpty else { return [] }
        return [[
            "role": turn.role.rawValue,
            "content": textContent
        ]]
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

    private func fetchOpenAIModels() async throws -> [String] {
        guard let url = URL(string: "\(endpoint)/v1/models") else {
            throw AIProviderError.invalidEndpoint(endpoint)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = AIProvider.modelListTimeout
        if let apiKey, !apiKey.isEmpty {
            request.setValue(
                "Bearer \(apiKey)",
                forHTTPHeaderField: "Authorization"
            )
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Self.logger.warning("OpenAI-compatible model fetch failed: \(error.localizedDescription, privacy: .public)")
            throw AIProviderError.networkError("Failed to fetch models")
        }

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

        var request = URLRequest(url: url)
        request.timeoutInterval = AIProvider.modelListTimeout
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Self.logger.warning("Ollama model fetch failed: \(error.localizedDescription, privacy: .public)")
            throw AIProviderError.networkError(
                String(format: String(localized: "Failed to fetch models from %@"), endpoint)
            )
        }

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

/// Mutable state carried across `OpenAICompatibleProvider.parseChunk` calls.
struct OpenAIStreamState {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var toolCallIndexToId: [Int: String] = [:]
    var toolCallOrder: [Int] = []

    /// Yield `.toolUseEnd` for every tracked tool call and clear the map.
    /// Called when the provider signals tool-call completion (`finish_reason`
    /// or Ollama `done: true`).
    mutating func flushToolUseEnds() -> [ChatStreamEvent] {
        let events: [ChatStreamEvent] = toolCallOrder.compactMap { index in
            guard let id = toolCallIndexToId[index] else { return nil }
            return .toolUseEnd(id: id)
        }
        toolCallIndexToId.removeAll()
        toolCallOrder.removeAll()
        return events
    }

    func finalUsageEvent() -> ChatStreamEvent? {
        guard inputTokens > 0 || outputTokens > 0 else { return nil }
        return .usage(AITokenUsage(inputTokens: inputTokens, outputTokens: outputTokens))
    }
}
