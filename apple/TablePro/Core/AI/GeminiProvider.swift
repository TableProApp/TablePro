//
//  GeminiProvider.swift
//  TablePro
//

import Foundation
import os
import TableProMCP

final class GeminiProvider: ChatTransport {
    private static let logger = Logger(subsystem: "com.TablePro", category: "GeminiProvider")

    private let transport: AIProviderTransport
    private let maxOutputTokens: Int

    init(
        endpoint: String,
        apiKey: String,
        maxOutputTokens: Int = 8_192,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) {
        self.transport = AIProviderTransport(
            endpoint: endpoint,
            style: .gemini,
            headers: ["x-goog-api-key": apiKey.trimmingCharacters(in: .whitespacesAndNewlines)],
            forbiddenIsAuthFailure: true,
            session: session
        )
        self.maxOutputTokens = maxOutputTokens
    }

    func streamChat(
        turns: [ChatTurnWire],
        options: ChatTransportOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        transport.stream(GeminiStreamWire()) { [self] in
            try buildStreamRequest(turns: turns, options: options)
        }
    }

    private static let offlineModels: [AIModelInfo] = [
        "gemini-3.6-flash",
        "gemini-3.5-flash",
        "gemini-3.5-flash-lite",
        "gemini-3.1-pro-preview",
        "gemini-2.5-pro",
        "gemini-2.5-flash"
    ].map {
        AIModelInfo(
            id: $0,
            modalities: [.text, .image],
            reasoning: AIReasoningSupport(mode: .effortOnly, effortLevels: [.low, .medium, .high], defaultEffort: .medium)
        )
    }

    func fetchAvailableModels() async throws -> [AIModelInfo] {
        let url = try transport.url(AIEndpointStyle.gemini.modelsResource)
        switch await transport.modelList(at: url, key: "models") {
        case .unreachable(let error):
            Self.logger.warning("Gemini model fetch failed; using known models: \(error.publicLogShape, privacy: .public)")
            return Self.offlineModels
        case .notHTTP:
            Self.logger.warning("Gemini model fetch returned no HTTP response; using known models")
            return Self.offlineModels
        case .rejected(let reply):
            throw transport.httpError(reply, url: url)
        case .entries(nil):
            Self.logger.warning("Gemini model fetch returned unexpected response; using known models")
            return Self.offlineModels
        case .entries(let models?):
            let fetched = models.compactMap(Self.decodeModel(_:))
            return fetched.isEmpty ? Self.offlineModels : fetched
        }
    }

    static func decodeModel(_ json: [String: Any]) -> AIModelInfo? {
        guard let name = json["name"] as? String,
              let methods = json["supportedGenerationMethods"] as? [String],
              methods.contains("generateContent")
        else { return nil }

        let id = name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
        let supportsThinking = json["thinking"] as? Bool ?? false

        return AIModelInfo(
            id: id,
            displayName: json["displayName"] as? String,
            contextWindow: json["inputTokenLimit"] as? Int,
            maxOutputTokens: json["outputTokenLimit"] as? Int,
            modalities: [.text, .image],
            reasoning: supportsThinking
                ? AIReasoningSupport(mode: .effortOnly, effortLevels: [.low, .medium, .high], defaultEffort: .medium)
                : .unsupported
        )
    }

    func testConnection() async throws -> Bool {
        let url = try transport.url(AIEndpointStyle.gemini.modelsResource)
        guard let reply = try await transport.connectionReply(to: transport.get(url, timeout: nil)) else {
            return false
        }
        guard reply.statusCode == 200 else {
            throw transport.httpError(reply, url: url)
        }
        return true
    }

    private func buildStreamRequest(
        turns: [ChatTurnWire],
        options: ChatTransportOptions
    ) throws -> URLRequest {
        let style = AIEndpointStyle.gemini
        let url = try transport.url(style.chatResource(model: options.model), query: style.chatQuery)

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
                let sanitized = Self.sanitizeSchemaForGemini(tool.inputSchema)
                entry["parameters"] = try sanitized.jsonObject()
                return entry
            }
            body["tools"] = [["functionDeclarations": declarations]]
        }

        body["contents"] = encodeContents(turns: turns)

        return try transport.post(url, body: body)
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
            case .sqlWalkthrough(let walkthrough):
                let text = walkthrough.transcriptText
                guard !text.isEmpty else { continue }
                parts.append(["text": text])
            case .attachment, .reasoning, .image:
                continue
            case .toolUse(let useBlock):
                let argsObject = (try? useBlock.input.jsonObject()) ?? [String: Any]()
                var partEntry: [String: Any] = [
                    "functionCall": [
                        "name": useBlock.name,
                        "args": argsObject
                    ]
                ]
                if let signature = useBlock.providerMetadata?["thoughtSignature"], !signature.isEmpty {
                    partEntry["thoughtSignature"] = signature
                }
                parts.append(partEntry)
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

    static func encodeArgsToJSONString(_ args: Any) -> String {
        guard JSONSerialization.isValidJSONObject(args) else {
            Self.logger.warning("Gemini functionCall args was not a valid JSON object; falling back to empty input")
            return "{}"
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: args)
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            Self.logger.warning("Gemini functionCall args serialization failed: \(error.publicLogShape, privacy: .public)")
            return "{}"
        }
    }

    // Gemini's function declarations reject `additionalProperties` and a `type` array; nullable is its own flag there.
    static func sanitizeSchemaForGemini(_ schema: JsonValue) -> JsonValue {
        switch schema {
        case .object(let fields):
            var rewritten: [String: JsonValue] = [:]
            var nullable = false

            for (key, value) in fields {
                if key == "additionalProperties" {
                    continue
                }
                if key == "type", case .array(let members) = value {
                    let nonNull = members.compactMap { member -> String? in
                        if case .string(let typeName) = member, typeName != "null" {
                            return typeName
                        }
                        if case .string("null") = member {
                            nullable = true
                            return nil
                        }
                        return nil
                    }
                    if nonNull.count == 1, let primary = nonNull.first {
                        rewritten["type"] = .string(primary)
                    } else {
                        rewritten["type"] = .array(nonNull.map(JsonValue.string))
                    }
                    continue
                }
                rewritten[key] = sanitizeSchemaForGemini(value)
            }

            if nullable {
                rewritten["nullable"] = .bool(true)
            }

            return .object(rewritten)

        case .array(let items):
            return .array(items.map(sanitizeSchemaForGemini))

        default:
            return schema
        }
    }
}

struct GeminiStreamWire: ChatStreamWire {
    // Gemini sends no tool-call ids, so each call gets one made here.
    var idGenerator: @Sendable () -> String = { UUID().uuidString }

    func parse(_ json: [String: Any], state: inout GeminiStreamState) -> [ChatStreamEvent] {
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
                    let argsString = GeminiProvider.encodeArgsToJSONString(argsObject)
                    var metadata: [String: String]?
                    if let signature = part["thoughtSignature"] as? String, !signature.isEmpty {
                        metadata = ["thoughtSignature": signature]
                    }
                    events.append(.toolUseStart(id: id, name: name, providerMetadata: metadata))
                    events.append(.toolUseDelta(id: id, inputJSONDelta: argsString))
                    events.append(.toolUseEnd(id: id))
                }
            }
        }
        if let finishReason = (json["candidates"] as? [[String: Any]])?.first?["finishReason"] as? String,
           !finishReason.isEmpty {
            state.receivedOutput = true
            if finishReason == "MAX_TOKENS" {
                events.append(.outputLimitReached(.outputTokens))
            }
        }
        // A blocked prompt is answered with its reason and no candidates, and that is the whole reply.
        if let blockReason = (json["promptFeedback"] as? [String: Any])?["blockReason"] as? String,
           !blockReason.isEmpty {
            state.receivedOutput = true
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
}

struct GeminiStreamState: ChatStreamState {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var receivedOutput = false
}
