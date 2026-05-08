//
//  ChatTool.swift
//  TablePro
//

import Foundation

/// A tool the AI can call from a chat turn. Implementations are registered
/// with `ChatToolRegistry` and exposed to providers via `ChatToolSpec`.
protocol ChatTool: Sendable {
    var name: String { get }
    var description: String { get }
    var inputSchema: JsonValue { get }

    func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult
}

struct ChatToolResult: Sendable, Equatable, Codable {
    /// Tool results are UTF-8 text in this version. A future expansion may
    /// widen `content` to accept multiple typed blocks (text, image,
    /// structured data); treat the current shape as a forward-compat floor.
    let content: String
    let isError: Bool

    init(content: String, isError: Bool = false) {
        self.content = content
        self.isError = isError
    }
}

extension ChatTool {
    /// Wire-format spec for `ChatTransportOptions.tools`.
    var spec: ChatToolSpec {
        ChatToolSpec(name: name, description: description, inputSchema: inputSchema)
    }
}
