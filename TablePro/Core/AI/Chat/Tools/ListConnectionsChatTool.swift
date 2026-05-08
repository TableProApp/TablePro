//
//  ListConnectionsChatTool.swift
//  TablePro
//

import Foundation

struct ListConnectionsChatTool: ChatTool {
    let name = "list_connections"
    let description = String(localized: "List all saved database connections with their current status.")
    let inputSchema: JsonValue = .object([
        "type": .string("object"),
        "properties": .object([:])
    ])

    func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
        let payload = await context.bridge.listConnections()
        return ChatToolResult(content: payload.jsonString(prettyPrinted: true))
    }
}
