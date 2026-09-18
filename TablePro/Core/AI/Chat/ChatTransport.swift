//
//  ChatTransport.swift
//  TablePro
//

import Foundation

protocol ChatTransport: AnyObject, Sendable {
    func streamChat(
        turns: [ChatTurnWire],
        options: ChatTransportOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error>

    func fetchAvailableModels() async throws -> [AIModelInfo]

    func testConnection() async throws -> Bool
}

struct ChatTransportOptions: Sendable {
    var model: String
    var systemPrompt: String?
    var maxOutputTokens: Int?
    var temperature: Double?
    var tools: [ChatToolSpec]
    var reasoningEffort: ReasoningEffort?
    /// Which agent session this turn belongs to.
    ///
    /// A stateful transport keeps conversation state per session rather than per provider
    /// configuration. `AIProviderFactory` caches one provider per configuration, so two sessions on
    /// one Copilot configuration appended their turns to a single server-side conversation and each
    /// was answered with the other's context, across connections included, while their local
    /// transcripts stayed correctly separate.
    var sessionId: UUID

    init(
        model: String,
        systemPrompt: String? = nil,
        maxOutputTokens: Int? = nil,
        temperature: Double? = nil,
        tools: [ChatToolSpec] = [],
        reasoningEffort: ReasoningEffort? = nil,
        sessionId: UUID = UUID()
    ) {
        self.model = model
        self.systemPrompt = systemPrompt
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.tools = tools
        self.reasoningEffort = reasoningEffort
        self.sessionId = sessionId
    }
}

struct ChatToolSpec: Codable, Equatable, Sendable {
    let name: String
    let description: String
    let inputSchema: JsonValue
    let strict: Bool

    init(name: String, description: String, inputSchema: JsonValue, strict: Bool = true) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.strict = strict
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        inputSchema = try container.decode(JsonValue.self, forKey: .inputSchema)
        strict = try container.decodeIfPresent(Bool.self, forKey: .strict) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, inputSchema, strict
    }
}

enum ChatStreamEvent: Sendable {
    case textDelta(String)
    case toolUseStart(id: String, name: String, providerMetadata: [String: String]? = nil)
    case toolUseDelta(id: String, inputJSONDelta: String)
    case toolUseEnd(id: String)
    case usage(AITokenUsage)
    case toolInvocationRequest(block: ToolUseBlock, replyToken: ToolReplyToken)
    case reasoningStart(id: String)
    case reasoningDelta(id: String, text: String)
    case reasoningEnd(id: String, opaque: ReasoningOpaque?)
}

final class ToolReplyToken: Sendable {
    private let onReply: @Sendable (ChatToolResult) async -> Void

    init(onReply: @escaping @Sendable (ChatToolResult) async -> Void) {
        self.onReply = onReply
    }

    func reply(_ result: ChatToolResult) async {
        await onReply(result)
    }
}
