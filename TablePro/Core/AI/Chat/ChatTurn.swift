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
    private(set) var blocks: [ChatContentBlock]
    private(set) var plainText: String
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
        let normalized = Self.normalize(blocks)
        self.blocks = normalized
        self.plainText = Self.computePlainText(from: normalized)
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

        let decodedBlocks: [ChatContentBlock]
        if let blocksFromContainer = try container.decodeIfPresent([ChatContentBlock].self, forKey: .blocks) {
            decodedBlocks = blocksFromContainer
        } else {
            let legacyContainer = try decoder.container(keyedBy: LegacyKeys.self)
            if let legacyText = try legacyContainer.decodeIfPresent(String.self, forKey: .content) {
                decodedBlocks = [.text(legacyText)]
            } else {
                decodedBlocks = []
            }
        }
        let normalized = Self.normalize(decodedBlocks)
        blocks = normalized
        plainText = Self.computePlainText(from: normalized)
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
        case id, role, blocks, timestamp, usage, modelId, providerId
    }

    private enum LegacyKeys: String, CodingKey {
        case content
    }

    mutating func appendText(_ text: String) {
        guard !text.isEmpty else { return }
        if let last = blocks.last, case .text(let existing) = last.kind {
            blocks[blocks.count - 1] = ChatContentBlock(id: last.id, kind: .text(existing + text))
        } else {
            blocks.append(.text(text))
        }
        plainText.append(text)
    }

    mutating func appendBlock(_ block: ChatContentBlock) {
        if case .text(let text) = block.kind {
            if let last = blocks.last, case .text(let existing) = last.kind {
                blocks[blocks.count - 1] = ChatContentBlock(id: last.id, kind: .text(existing + text))
            } else {
                blocks.append(block)
            }
            plainText.append(text)
        } else {
            blocks.append(block)
        }
    }

    mutating func replaceBlock(at index: Int, with block: ChatContentBlock) {
        guard blocks.indices.contains(index) else { return }
        let oldKind = blocks[index].kind
        blocks[index] = block
        if case .text = oldKind {
            plainText = Self.computePlainText(from: blocks)
        } else if case .text = block.kind {
            plainText = Self.computePlainText(from: blocks)
        }
    }

    private static func normalize(_ blocks: [ChatContentBlock]) -> [ChatContentBlock] {
        var result: [ChatContentBlock] = []
        result.reserveCapacity(blocks.count)
        for block in blocks {
            if case .text(let text) = block.kind,
               let last = result.last,
               case .text(let existing) = last.kind {
                result[result.count - 1] = ChatContentBlock(id: last.id, kind: .text(existing + text))
            } else {
                result.append(block)
            }
        }
        return result
    }

    private static func computePlainText(from blocks: [ChatContentBlock]) -> String {
        var result = ""
        for block in blocks {
            if case .text(let text) = block.kind {
                result.append(text)
            }
        }
        return result
    }
}

struct ChatContentBlock: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let kind: Kind

    init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }

    static func text(_ text: String) -> ChatContentBlock {
        ChatContentBlock(kind: .text(text))
    }

    static func toolUse(_ block: ToolUseBlock) -> ChatContentBlock {
        ChatContentBlock(kind: .toolUse(block))
    }

    static func toolResult(_ block: ToolResultBlock) -> ChatContentBlock {
        ChatContentBlock(kind: .toolResult(block))
    }

    static func attachment(_ item: ContextItem) -> ChatContentBlock {
        ChatContentBlock(kind: .attachment(item))
    }

    enum Kind: Codable, Equatable, Sendable {
        case text(String)
        case toolUse(ToolUseBlock)
        case toolResult(ToolResultBlock)
        case attachment(ContextItem)
    }

    private enum CodingKeys: String, CodingKey {
        case blockId, kind, text, toolUse, toolResult, attachment
    }

    private enum KindMarker: String, Codable {
        case text, toolUse, toolResult, attachment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let resolvedID = (try container.decodeIfPresent(UUID.self, forKey: .blockId)) ?? UUID()
        let marker = try container.decode(KindMarker.self, forKey: .kind)
        let resolvedKind: Kind
        switch marker {
        case .text:
            resolvedKind = .text(try container.decode(String.self, forKey: .text))
        case .toolUse:
            resolvedKind = .toolUse(try container.decode(ToolUseBlock.self, forKey: .toolUse))
        case .toolResult:
            resolvedKind = .toolResult(try container.decode(ToolResultBlock.self, forKey: .toolResult))
        case .attachment:
            resolvedKind = .attachment(try container.decode(ContextItem.self, forKey: .attachment))
        }
        self.init(id: resolvedID, kind: resolvedKind)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .blockId)
        switch kind {
        case .text(let text):
            try container.encode(KindMarker.text, forKey: .kind)
            try container.encode(text, forKey: .text)
        case .toolUse(let block):
            try container.encode(KindMarker.toolUse, forKey: .kind)
            try container.encode(block, forKey: .toolUse)
        case .toolResult(let block):
            try container.encode(KindMarker.toolResult, forKey: .kind)
            try container.encode(block, forKey: .toolResult)
        case .attachment(let item):
            try container.encode(KindMarker.attachment, forKey: .kind)
            try container.encode(item, forKey: .attachment)
        }
    }
}

struct ToolUseBlock: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let input: JsonValue
    var approvalState: ToolApprovalState

    init(id: String, name: String, input: JsonValue, approvalState: ToolApprovalState = .approved) {
        self.id = id
        self.name = name
        self.input = input
        self.approvalState = approvalState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        input = try container.decode(JsonValue.self, forKey: .input)
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
