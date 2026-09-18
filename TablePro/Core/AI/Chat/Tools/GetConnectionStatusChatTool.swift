//
//  GetConnectionStatusChatTool.swift
//  TablePro
//

import Foundation

struct GetConnectionStatusChatTool: ChatTool {
    let name = "get_connection_status"
    let description = String(localized: "Get detailed status for a specific database connection.")
    let inputSchema: JsonValue = ChatToolSchemaBuilder.object(properties: [:])
    let mode: ChatToolMode = .readOnly

    func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
        let connectionId = try await ChatToolTarget.authorized(context: context, input: input, tool: name)
        let payload = try await context.bridge.getConnectionStatus(connectionId: connectionId)
        return ChatToolResult(content: payload.jsonString(prettyPrinted: true))
    }
}
