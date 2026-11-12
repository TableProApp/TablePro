//
//  ListConnectionsChatTool.swift
//  TablePro
//

import Foundation
import TableProMCP

struct ListConnectionsChatTool: ChatTool {
    let name = "list_connections"
    let description = String(localized: "Show the connection this conversation works on, with its status.")
    let inputSchema: JsonValue = ChatToolSchemaBuilder.object(properties: [:])
    let mode: ChatToolMode = .readOnly

    func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
        let connectionId = try await ChatToolTarget.authorized(context: context, input: input, tool: name)
        let payload = await context.bridge.listConnection(id: connectionId)
        return ChatToolResult(content: payload.jsonString(prettyPrinted: true))
    }
}
