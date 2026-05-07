//
//  ListConnectionsChatTool.swift
//  TablePro
//

import Foundation

struct ListConnectionsChatTool: ChatTool {
    let name = "list_connections"
    let description = String(localized: "List all saved database connections with their current status.")
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([:])
    ])

    func execute(input: JSONValue, context: ChatToolContext) async throws -> ChatToolResult {
        let payload = await context.bridge.listConnections()
        return ChatToolResult(content: try ChatToolJSONFormatter.string(from: payload))
    }
}
