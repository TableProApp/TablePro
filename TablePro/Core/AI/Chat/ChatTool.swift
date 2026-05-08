//
//  ChatTool.swift
//  TablePro
//

import Foundation

enum ChatToolMode: Sendable {
    case readOnly
    case write
    case agentOnly
}

protocol ChatTool: Sendable {
    var name: String { get }
    var description: String { get }
    var inputSchema: JsonValue { get }
    var mode: ChatToolMode { get }

    func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult
}

extension ChatToolMode {
    func isAllowed(in chatMode: AIChatMode) -> Bool {
        switch (self, chatMode) {
        case (_, .agent):
            return true
        case (.readOnly, .ask), (.readOnly, .edit):
            return true
        case (.write, .edit):
            return true
        case (.write, .ask):
            return false
        case (.agentOnly, .ask), (.agentOnly, .edit):
            return false
        }
    }

    var requiresApproval: Bool {
        switch self {
        case .readOnly: return false
        case .write, .agentOnly: return true
        }
    }
}

struct ChatToolResult: Sendable, Equatable, Codable {
    let content: String
    let isError: Bool

    init(content: String, isError: Bool = false) {
        self.content = content
        self.isError = isError
    }
}

extension ChatTool {
    var spec: ChatToolSpec {
        ChatToolSpec(name: name, description: description, inputSchema: inputSchema)
    }
}
