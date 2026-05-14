//
//  OpenAIResponsesProvider.swift
//  TablePro
//

import Foundation
import os

final class OpenAIResponsesProvider: ChatTransport {
    private static let logger = Logger(subsystem: "com.TablePro", category: "OpenAIResponsesProvider")

    private let endpoint: String
    private let apiKey: String?
    private let model: String
    private let maxOutputTokens: Int?
    private let session: URLSession

    init(
        endpoint: String,
        apiKey: String?,
        model: String = "",
        maxOutputTokens: Int? = nil,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) {
        self.endpoint = endpoint.normalizedEndpoint()
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
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
                    let request = try buildRequest(turns: turns, options: options, stream: true)
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

                    var state = ResponsesStreamState()
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard let json = Self.decodeStreamLine(line) else { continue }
                        let events = try Self.parseEvent(json, state: &state)
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
        request.timeoutInterval = AIProvider.modelListTimeout
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Self.logger.warning("OpenAI Responses model fetch failed: \(error.localizedDescription, privacy: .public)")
            throw AIProviderError.networkError("Failed to fetch models")
        }
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelsArray = json["data"] as? [[String: Any]]
        else {
            throw AIProviderError.networkError("Failed to fetch models")
        }
        return modelsArray.compactMap { $0["id"] as? String }.sorted()
    }

    func testConnection() async throws -> Bool {
        let testModel = model.isEmpty ? "gpt-5.5" : model
        let testOptions = ChatTransportOptions(model: testModel, maxOutputTokens: 16)
        let testTurn = ChatTurnWire(role: .user, blocks: [.text("Hi")])
        let request = try buildRequest(turns: [testTurn], options: testOptions, stream: false)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return false }
        if httpResponse.statusCode == 200 || httpResponse.statusCode == 400 {
            return true
        }
        if httpResponse.statusCode == 401 {
            throw AIProviderError.authenticationFailed("")
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        throw AIProviderError.mapHTTPError(statusCode: httpResponse.statusCode, body: body)
    }

    private func buildRequest(
        turns: [ChatTurnWire],
        options: ChatTransportOptions,
        stream: Bool
    ) throws -> URLRequest {
        guard let url = URL(string: "\(endpoint)/v1/responses") else {
            throw AIProviderError.invalidEndpoint(endpoint)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var body: [String: Any] = [
            "model": options.model,
            "input": try Self.encodeInput(turns: turns),
            "store": false,
            "stream": stream
        ]

        if let systemPrompt = options.systemPrompt, !systemPrompt.isEmpty {
            body["instructions"] = systemPrompt
        }

        let resolvedMaxTokens = options.maxOutputTokens
            ?? maxOutputTokens
            ?? options.reasoningEffort?.autoScaledMaxOutputTokens
        if let resolvedMaxTokens {
            body["max_output_tokens"] = resolvedMaxTokens
        }

        if let effort = options.reasoningEffort {
            body["reasoning"] = ["effort": effort.openAIWireValue, "summary": "auto"]
            body["include"] = ["reasoning.encrypted_content"]
        }

        if !options.tools.isEmpty {
            body["tools"] = try options.tools.map(Self.encodeToolSpec(_:))
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func encodeInput(turns: [ChatTurnWire]) throws -> [[String: Any]] {
        var items: [[String: Any]] = []
        for turn in turns where turn.role != .system {
            items.append(contentsOf: try encodeTurn(turn))
        }
        return items
    }

    static func encodeTurn(_ turn: ChatTurnWire) throws -> [[String: Any]] {
        var items: [[String: Any]] = []
        var messageParts: [[String: Any]] = []

        if turn.role == .assistant {
            var hasFunctionCall = false
            for block in turn.blocks {
                switch block.kind {
                case .reasoning(let reasoning):
                    guard let opaque = reasoning.opaque,
                          opaque.kind == .openAIEncrypted else { continue }
                    if opaque.itemID.isEmpty {
                        Self.logger.warning("Dropping reasoning item without itemID; history may be inconsistent")
                        continue
                    }
                    flushAssistantMessage(parts: &messageParts, into: &items)
                    items.append([
                        "type": "reasoning",
                        "id": opaque.itemID,
                        "encrypted_content": opaque.value
                    ])
                case .text(let text):
                    guard !text.isEmpty else { continue }
                    messageParts.append(["type": "output_text", "text": text])
                case .toolUse(let useBlock):
                    flushAssistantMessage(parts: &messageParts, into: &items)
                    items.append([
                        "type": "function_call",
                        "call_id": useBlock.id,
                        "name": useBlock.name,
                        "arguments": useBlock.input.jsonString()
                    ])
                    hasFunctionCall = true
                case .toolResult, .attachment, .image:
                    continue
                }
            }
            if hasFunctionCall {
                if !messageParts.isEmpty {
                    Self.logger.warning("Dropping \(messageParts.count) text parts after function_call to keep tool-call adjacent to its output")
                    messageParts.removeAll()
                }
            } else {
                flushAssistantMessage(parts: &messageParts, into: &items)
            }
            return items
        }

        if turn.role == .user {
            for block in turn.blocks {
                if case .toolResult(let resultBlock) = block.kind {
                    items.append([
                        "type": "function_call_output",
                        "call_id": resultBlock.toolUseId,
                        "output": resultBlock.content
                    ])
                }
            }

            var userParts: [[String: Any]] = []
            for block in turn.blocks {
                switch block.kind {
                case .text(let text):
                    guard !text.isEmpty else { continue }
                    userParts.append(["type": "input_text", "text": text])
                case .image(let input):
                    if let part = inputImagePart(input) {
                        userParts.append(part)
                    }
                case .toolUse, .toolResult, .attachment, .reasoning:
                    continue
                }
            }
            if !userParts.isEmpty {
                items.append([
                    "type": "message",
                    "role": "user",
                    "content": userParts
                ])
            }
            return items
        }

        return []
    }

    static func encodeToolSpec(_ spec: ChatToolSpec) throws -> [String: Any] {
        var encoded: [String: Any] = [
            "type": "function",
            "name": spec.name,
            "description": spec.description,
            "parameters": try spec.inputSchema.jsonObject()
        ]
        encoded["strict"] = spec.strict
        return encoded
    }

    private static func inputImagePart(_ input: ChatImageInput) -> [String: Any]? {
        guard let imageURL = input.imageURLString() else { return nil }
        return [
            "type": "input_image",
            "image_url": imageURL,
            "detail": input.detailHint.rawValue
        ]
    }

    private static func flushAssistantMessage(parts: inout [[String: Any]], into items: inout [[String: Any]]) {
        guard !parts.isEmpty else { return }
        items.append([
            "type": "message",
            "role": "assistant",
            "content": parts
        ])
        parts = []
    }

    static func decodeStreamLine(_ line: String) -> [String: Any]? {
        guard line.hasPrefix("data: ") else { return nil }
        let payload = String(line.dropFirst(6))
        guard payload != "[DONE]",
              let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    static func parseEvent(
        _ json: [String: Any],
        state: inout ResponsesStreamState
    ) throws -> [ChatStreamEvent] {
        guard let type = json["type"] as? String else { return [] }
        switch type {
        case "response.output_text.delta":
            if let delta = json["delta"] as? String, !delta.isEmpty {
                return [.textDelta(delta)]
            }
            return []
        case "response.reasoning_summary_text.delta":
            guard let itemID = json["item_id"] as? String,
                  let delta = json["delta"] as? String, !delta.isEmpty else { return [] }
            return [.reasoningDelta(id: itemID, text: delta)]
        case "response.output_item.added":
            guard let item = json["item"] as? [String: Any],
                  let itemType = item["type"] as? String else { return [] }
            switch itemType {
            case "reasoning":
                guard let itemID = item["id"] as? String else { return [] }
                state.openReasoningItemIDs.insert(itemID)
                return [.reasoningStart(id: itemID)]
            case "function_call":
                guard let callID = item["call_id"] as? String,
                      let name = item["name"] as? String else { return [] }
                state.openFunctionCallIDs.insert(callID)
                return [.toolUseStart(id: callID, name: name)]
            default:
                return []
            }
        case "response.output_item.done":
            guard let item = json["item"] as? [String: Any],
                  let itemType = item["type"] as? String else { return [] }
            switch itemType {
            case "reasoning":
                guard let itemID = item["id"] as? String,
                      state.openReasoningItemIDs.remove(itemID) != nil else { return [] }
                let encrypted = item["encrypted_content"] as? String
                let opaque = encrypted.map {
                    ReasoningOpaque(
                        kind: .openAIEncrypted,
                        itemID: itemID,
                        value: $0,
                        blockType: "reasoning"
                    )
                }
                return [.reasoningEnd(id: itemID, opaque: opaque)]
            case "function_call":
                guard let callID = item["call_id"] as? String,
                      state.openFunctionCallIDs.remove(callID) != nil else { return [] }
                return [.toolUseEnd(id: callID)]
            default:
                return []
            }
        case "response.function_call_arguments.delta":
            guard let callID = json["call_id"] as? String ?? json["item_id"] as? String,
                  let delta = json["delta"] as? String, !delta.isEmpty else { return [] }
            return [.toolUseDelta(id: callID, inputJSONDelta: delta)]
        case "response.refusal.delta":
            if let delta = json["delta"] as? String, !delta.isEmpty {
                return [.textDelta(delta)]
            }
            return []
        case "response.completed":
            if let responseObj = json["response"] as? [String: Any],
               let usage = responseObj["usage"] as? [String: Any] {
                let input = usage["input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                state.inputTokens = input
                state.outputTokens = output
            }
            return []
        case "response.failed":
            if let responseObj = json["response"] as? [String: Any],
               let errorObj = responseObj["error"] as? [String: Any],
               let message = errorObj["message"] as? String {
                throw AIProviderError.streamingFailed(message)
            }
            throw AIProviderError.streamingFailed(String(localized: "Response failed"))
        case "error":
            if let message = json["message"] as? String {
                throw AIProviderError.streamingFailed(message)
            }
            return []
        default:
            return []
        }
    }
}

struct ResponsesStreamState {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var openReasoningItemIDs: Set<String> = []
    var openFunctionCallIDs: Set<String> = []

    func finalUsageEvent() -> ChatStreamEvent? {
        guard inputTokens > 0 || outputTokens > 0 else { return nil }
        return .usage(AITokenUsage(inputTokens: inputTokens, outputTokens: outputTokens))
    }
}
