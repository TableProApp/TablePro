//
//  ListConnectionsChatTool.swift
//  TablePro
//

import Foundation

struct ListConnectionsChatTool: ChatTool {
    let name = "list_connections"
    let description = String(localized: "List all saved database connections with their current status.")
    let inputSchema: JsonValue = ChatToolSchemaBuilder.object(properties: [:])
    let mode: ChatToolMode = .readOnly

    func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
        let payload = await context.bridge.listConnections()
        return ChatToolResult(content: payload.jsonString(prettyPrinted: true))
    }
}
