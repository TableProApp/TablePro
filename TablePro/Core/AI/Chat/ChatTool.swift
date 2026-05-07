//
//  ChatTool.swift
//  TablePro
//

import Foundation

/// A tool the AI can call from a chat turn. Implementations are registered
/// with `ChatToolRegistry` and exposed to providers via `ChatToolSpec`.
public protocol ChatTool: Sendable {
    var name: String { get }
    var description: String { get }
    var inputSchema: JSONValue { get }

    func execute(input: JSONValue) async throws -> ChatToolResult
}

public struct ChatToolResult: Sendable, Equatable, Codable {
    /// Tool results are UTF-8 text in this version. A future expansion may
    /// widen `content` to accept multiple typed blocks (text, image,
    /// structured data); treat the current shape as a forward-compat floor.
    public let content: String
    public let isError: Bool

    public init(content: String, isError: Bool = false) {
        self.content = content
        self.isError = isError
    }
}

public extension ChatTool {
    /// Wire-format spec for `ChatTransportOptions.tools`.
    var spec: ChatToolSpec {
        ChatToolSpec(name: name, description: description, inputSchema: inputSchema)
    }
}
