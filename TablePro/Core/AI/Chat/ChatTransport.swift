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

    /// Which chat session this turn belongs to.
    ///
    /// Stateless providers ignore it: a request carries its own history and the server keeps
    /// nothing between calls. A provider that holds a conversation of its own needs it, because one
    /// provider instance is shared by every session on that configuration and the conversation has
    /// to belong to the session rather than to the instance. Nil for the callers that have no
    /// session at all, such as a connection test or an inline suggestion.
    var sessionId: UUID?

    init(
        model: String,
        systemPrompt: String? = nil,
        maxOutputTokens: Int? = nil,
        temperature: Double? = nil,
        tools: [ChatToolSpec] = [],
        reasoningEffort: ReasoningEffort? = nil,
        sessionId: UUID? = nil
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
