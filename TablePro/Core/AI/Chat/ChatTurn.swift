//
//  ChatTurn.swift
//  TablePro
//

import Foundation
import Observation

enum ChatRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

enum ChatContentBlockKind: Sendable, Equatable {
    case text(String)
    case toolUse(ToolUseBlock)
    case toolResult(ToolResultBlock)
    case attachment(ContextItem)
    case reasoning(ReasoningBlock)
    case image(ChatImageInput)
}

@MainActor @Observable
final class ChatContentBlock: Identifiable {
    let id: UUID
    var kind: ChatContentBlockKind
    var isStreaming: Bool

    init(id: UUID = UUID(), kind: ChatContentBlockKind, isStreaming: Bool = false) {
        self.id = id
        self.kind = kind
        self.isStreaming = isStreaming
    }

    func appendText(_ chunk: String) {
        guard !chunk.isEmpty, case .text(let existing) = kind else { return }
        kind = .text(existing + chunk)
    }

    func appendReasoningText(_ chunk: String) {
        guard !chunk.isEmpty, case .reasoning(var block) = kind else { return }
        block.text = (block.text ?? "") + chunk
        kind = .reasoning(block)
    }

    func setReasoningOpaque(_ opaque: ReasoningOpaque?) {
        guard case .reasoning(var block) = kind else { return }
        block.opaque = opaque
        kind = .reasoning(block)
    }

    func setKind(_ newKind: ChatContentBlockKind) {
        kind = newKind
    }

    func finishStreaming() {
        isStreaming = false
    }

    var wireSnapshot: ChatContentBlockWire {
        ChatContentBlockWire(id: id, kind: kind)
    }
}

extension ChatContentBlock {
    static func text(_ text: String, isStreaming: Bool = false) -> ChatContentBlock {
        ChatContentBlock(kind: .text(text), isStreaming: isStreaming)
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

    static func reasoning(_ block: ReasoningBlock = ReasoningBlock(), isStreaming: Bool = false) -> ChatContentBlock {
        ChatContentBlock(kind: .reasoning(block), isStreaming: isStreaming)
    }

    static func image(_ input: ChatImageInput) -> ChatContentBlock {
        ChatContentBlock(kind: .image(input))
    }
}

@MainActor
struct ChatTurn: Identifiable {
    let id: UUID
    let role: ChatRole
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
        self.blocks = Self.coalesceAdjacentText(blocks)
        self.timestamp = timestamp
        self.usage = usage
        self.modelId = modelId
        self.providerId = providerId
    }

    init(wire: ChatTurnWire) {
        self.id = wire.id
        self.role = wire.role
        self.blocks = wire.blocks.map { ChatContentBlock(id: $0.id, kind: $0.kind) }
        self.timestamp = wire.timestamp
        self.usage = wire.usage
        self.modelId = wire.modelId
        self.providerId = wire.providerId
    }

    var plainText: String {
        var result = ""
        for block in blocks {
            if case .text(let text) = block.kind {
                result.append(text)
            }
        }
        return result
    }

    var wireSnapshot: ChatTurnWire {
        ChatTurnWire(
            id: id,
            role: role,
            blocks: blocks.map { $0.wireSnapshot },
            timestamp: timestamp,
            usage: usage,
            modelId: modelId,
            providerId: providerId
        )
    }

    mutating func appendStreamingToken(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        if let last = blocks.last, case .text = last.kind, last.isStreaming {
            last.appendText(chunk)
        } else {
            blocks.append(ChatContentBlock(kind: .text(chunk), isStreaming: true))
        }
    }

    mutating func finishStreamingTextBlock() {
        if let last = blocks.last, case .text = last.kind, last.isStreaming {
            last.finishStreaming()
        }
    }

    mutating func appendBlock(_ block: ChatContentBlock) {
        finishStreamingTextBlock()
        blocks.append(block)
    }

    @discardableResult
    mutating func appendReasoningDelta(providerBlockID: String, text: String, idMap: inout [String: UUID]) -> UUID {
        if let existingUUID = idMap[providerBlockID],
           let existingBlock = blocks.first(where: { $0.id == existingUUID }) {
            existingBlock.appendReasoningText(text)
            return existingUUID
        }
        finishStreamingTextBlock()
        let newUUID = UUID()
        idMap[providerBlockID] = newUUID
        let initial = ReasoningBlock(text: text.isEmpty ? nil : text)
        blocks.append(ChatContentBlock(id: newUUID, kind: .reasoning(initial), isStreaming: true))
        return newUUID
    }

    mutating func startReasoningBlock(providerBlockID: String, idMap: inout [String: UUID]) {
        if idMap[providerBlockID] != nil { return }
        finishStreamingTextBlock()
        let newUUID = UUID()
        idMap[providerBlockID] = newUUID
        blocks.append(ChatContentBlock(id: newUUID, kind: .reasoning(ReasoningBlock()), isStreaming: true))
    }

    mutating func finalizeReasoningBlock(providerBlockID: String, opaque: ReasoningOpaque?, idMap: inout [String: UUID]) {
        guard let blockUUID = idMap.removeValue(forKey: providerBlockID),
              let block = blocks.first(where: { $0.id == blockUUID }) else { return }
        block.setReasoningOpaque(opaque)
        block.finishStreaming()
    }

    private static func coalesceAdjacentText(_ blocks: [ChatContentBlock]) -> [ChatContentBlock] {
        var result: [ChatContentBlock] = []
        result.reserveCapacity(blocks.count)
        for block in blocks {
            if case .text(let text) = block.kind,
               let last = result.last,
               case .text(let existing) = last.kind,
               !last.isStreaming, !block.isStreaming {
                last.kind = .text(existing + text)
            } else {
                result.append(block)
            }
        }
        return result
    }
}

extension ChatTurn: Equatable {
    nonisolated static func == (lhs: ChatTurn, rhs: ChatTurn) -> Bool {
        MainActor.assumeIsolated {
            lhs.wireSnapshot == rhs.wireSnapshot
        }
    }
}

struct ChatContentBlockWire: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let kind: ChatContentBlockKind

    init(id: UUID = UUID(), kind: ChatContentBlockKind) {
        self.id = id
        self.kind = kind
    }

    static func text(_ text: String) -> ChatContentBlockWire {
        ChatContentBlockWire(kind: .text(text))
    }

    static func toolUse(_ block: ToolUseBlock) -> ChatContentBlockWire {
        ChatContentBlockWire(kind: .toolUse(block))
    }

    static func toolResult(_ block: ToolResultBlock) -> ChatContentBlockWire {
        ChatContentBlockWire(kind: .toolResult(block))
    }

    static func attachment(_ item: ContextItem) -> ChatContentBlockWire {
        ChatContentBlockWire(kind: .attachment(item))
    }

    static func reasoning(_ block: ReasoningBlock) -> ChatContentBlockWire {
        ChatContentBlockWire(kind: .reasoning(block))
    }

    static func image(_ input: ChatImageInput) -> ChatContentBlockWire {
        ChatContentBlockWire(kind: .image(input))
    }

    private enum CodingKeys: String, CodingKey {
        case blockId, kind, text, toolUse, toolResult, attachment, reasoning, image
    }

    private enum KindMarker: String, Codable {
        case text, toolUse, toolResult, attachment, reasoning, image
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let resolvedID = (try container.decodeIfPresent(UUID.self, forKey: .blockId)) ?? UUID()
        let marker = try container.decode(KindMarker.self, forKey: .kind)
        let resolvedKind: ChatContentBlockKind
        switch marker {
        case .text:
            resolvedKind = .text(try container.decode(String.self, forKey: .text))
        case .toolUse:
            resolvedKind = .toolUse(try container.decode(ToolUseBlock.self, forKey: .toolUse))
        case .toolResult:
            resolvedKind = .toolResult(try container.decode(ToolResultBlock.self, forKey: .toolResult))
        case .attachment:
            resolvedKind = .attachment(try container.decode(ContextItem.self, forKey: .attachment))
        case .reasoning:
            resolvedKind = .reasoning(try container.decode(ReasoningBlock.self, forKey: .reasoning))
        case .image:
            resolvedKind = .image(try container.decode(ChatImageInput.self, forKey: .image))
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
        case .reasoning(let block):
            try container.encode(KindMarker.reasoning, forKey: .kind)
            try container.encode(block, forKey: .reasoning)
        case .image(let input):
            try container.encode(KindMarker.image, forKey: .kind)
            try container.encode(input, forKey: .image)
        }
    }
}

struct ChatTurnWire: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let role: ChatRole
    var blocks: [ChatContentBlockWire]
    let timestamp: Date
    var usage: AITokenUsage?
    var modelId: String?
    var providerId: String?

    init(
        id: UUID = UUID(),
        role: ChatRole,
        blocks: [ChatContentBlockWire],
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

        if let decodedBlocks = try container.decodeIfPresent([ChatContentBlockWire].self, forKey: .blocks) {
            blocks = decodedBlocks
        } else {
            let legacyContainer = try decoder.container(keyedBy: LegacyKeys.self)
            if let legacyText = try legacyContainer.decodeIfPresent(String.self, forKey: .content) {
                blocks = [ChatContentBlockWire(kind: .text(legacyText))]
            } else {
                blocks = []
            }
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

    var plainText: String {
        var result = ""
        for block in blocks {
            if case .text(let text) = block.kind {
                result.append(text)
            }
        }
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, blocks, timestamp, usage, modelId, providerId
    }

    private enum LegacyKeys: String, CodingKey {
        case content
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
