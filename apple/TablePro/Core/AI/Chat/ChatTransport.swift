//
//  ChatTransport.swift
//  TablePro
//

import Foundation
import TableProMCP

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
    // A stateful transport keys its conversation by session: providers are cached per configuration, and two
    // sessions on one Copilot configuration once shared a single server-side conversation.
    var sessionId: UUID
    // The connection the conversation is attached to. A transport that hands the model its own
    // database tools scopes them to this one, and hands out none without it.
    var connectionId: UUID?
    // A transport that grants its own database tools narrows them by mode; a caller that leaves it out gets Ask.
    var chatMode: AIChatMode

    init(
        model: String,
        systemPrompt: String? = nil,
        maxOutputTokens: Int? = nil,
        temperature: Double? = nil,
        tools: [ChatToolSpec] = [],
        reasoningEffort: ReasoningEffort? = nil,
        sessionId: UUID = UUID(),
        connectionId: UUID? = nil,
        chatMode: AIChatMode = .ask
    ) {
        self.model = model
        self.systemPrompt = systemPrompt
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.tools = tools
        self.reasoningEffort = reasoningEffort
        self.sessionId = sessionId
        self.connectionId = connectionId
        self.chatMode = chatMode
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

// Why a provider stopped the response before the model finished it.
enum ChatOutputLimit: String, Codable, Sendable {
    case outputTokens
    case contextWindow
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
    case outputLimitReached(ChatOutputLimit)
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
