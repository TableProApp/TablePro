//
//  ChatTurn.swift
//  TablePro
//

import Foundation

enum ChatRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

struct ChatTurn: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var role: ChatRole
    var blocks: [ChatContentBlock]
    let timestamp: Date
    var usage: AITokenUsage?
    var modelId: String?
    var providerId: String?

    init(
        id: UUID = UUID(),
        role: ChatRole,
        blocks: [ChatContentBlock],
        timestamp: Date = Date(),
        usage: AITokenUsage? = nil,
        modelId: String? = nil,
        providerId: String? = nil
    ) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.timestamp = timestamp
        self.usage = usage
        self.modelId = modelId
        self.providerId = providerId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(ChatRole.self, forKey: .role)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        usage = try container.decodeIfPresent(AITokenUsage.self, forKey: .usage)
        modelId = try container.decodeIfPresent(String.self, forKey: .modelId)
        providerId = try container.decodeIfPresent(String.self, forKey: .providerId)

        if let decodedBlocks = try container.decodeIfPresent([ChatContentBlock].self, forKey: .blocks) {
            blocks = decodedBlocks
        } else if let legacyText = try container.decodeIfPresent(String.self, forKey: .content) {
            blocks = [.text(legacyText)]
        } else {
            blocks = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(blocks, forKey: .blocks)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(usage, forKey: .usage)
        try container.encodeIfPresent(modelId, forKey: .modelId)
        try container.encodeIfPresent(providerId, forKey: .providerId)
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, blocks, content, timestamp, usage, modelId, providerId
    }

    var plainText: String {
        blocks.compactMap { block in
            if case .text(let text) = block { return text }
            return nil
        }.joined()
    }

    mutating func appendText(_ text: String) {
        guard !text.isEmpty else { return }
        if case .text(let existing) = blocks.last {
            blocks[blocks.count - 1] = .text(existing + text)
        } else {
            blocks.append(.text(text))
        }
    }
}

enum ChatContentBlock: Codable, Equatable, Sendable {
    case text(String)
    case toolUse(ToolUseBlock)
    case toolResult(ToolResultBlock)
    case attachment(ContextItem)

    private enum CodingKeys: String, CodingKey {
        case kind, text, toolUse, toolResult, attachment
    }

    private enum Kind: String, Codable {
        case text, toolUse, toolResult, attachment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .toolUse:
            self = .toolUse(try container.decode(ToolUseBlock.self, forKey: .toolUse))
        case .toolResult:
            self = .toolResult(try container.decode(ToolResultBlock.self, forKey: .toolResult))
        case .attachment:
            self = .attachment(try container.decode(ContextItem.self, forKey: .attachment))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(text, forKey: .text)
        case .toolUse(let block):
            try container.encode(Kind.toolUse, forKey: .kind)
            try container.encode(block, forKey: .toolUse)
        case .toolResult(let block):
            try container.encode(Kind.toolResult, forKey: .kind)
            try container.encode(block, forKey: .toolResult)
        case .attachment(let item):
            try container.encode(Kind.attachment, forKey: .kind)
            try container.encode(item, forKey: .attachment)
        }
    }
}

struct ToolUseBlock: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let input: JSONValue
    var approvalState: ToolApprovalState

    init(id: String, name: String, input: JSONValue, approvalState: ToolApprovalState = .approved) {
        self.id = id
        self.name = name
        self.input = input
        self.approvalState = approvalState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        input = try container.decode(JSONValue.self, forKey: .input)
        approvalState = try container.decodeIfPresent(ToolApprovalState.self, forKey: .approvalState) ?? .approved
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(input, forKey: .input)
        try container.encode(approvalState, forKey: .approvalState)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, input, approvalState
    }
}

enum ToolApprovalState: Codable, Equatable, Sendable {
    case approved
    case pending
    case denied(reason: String)
    case cancelled
}

struct ToolResultBlock: Codable, Equatable, Sendable {
    let toolUseId: String
    let content: String
    let isError: Bool

    init(toolUseId: String, content: String, isError: Bool = false) {
        self.toolUseId = toolUseId
        self.content = content
        self.isError = isError
    }
}
