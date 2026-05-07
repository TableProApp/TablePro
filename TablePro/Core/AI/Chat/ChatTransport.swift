//
//  ChatTransport.swift
//  TablePro
//

import Foundation

protocol ChatTransport: AnyObject, Sendable {
    func streamChat(
        turns: [ChatTurn],
        options: ChatTransportOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error>

    func fetchAvailableModels() async throws -> [String]

    func testConnection() async throws -> Bool
}

struct ChatTransportOptions: Sendable {
    var model: String
    var systemPrompt: String?
    var maxOutputTokens: Int?
    var temperature: Double?
    var tools: [ChatToolSpec]

    init(
        model: String,
        systemPrompt: String? = nil,
        maxOutputTokens: Int? = nil,
        temperature: Double? = nil,
        tools: [ChatToolSpec] = []
    ) {
        self.model = model
        self.systemPrompt = systemPrompt
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.tools = tools
    }
}

struct ChatToolSpec: Codable, Equatable, Sendable {
    let name: String
    let description: String
    let inputSchema: JSONValue
}

enum ChatStreamEvent: Sendable {
    case textDelta(String)
    case toolUseStart(id: String, name: String)
    case toolUseDelta(id: String, inputJSONDelta: String)
    case toolUseEnd(id: String)
    case usage(AITokenUsage)
}
