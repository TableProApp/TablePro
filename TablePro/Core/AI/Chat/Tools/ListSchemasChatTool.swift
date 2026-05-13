//
//  ListSchemasChatTool.swift
//  TablePro
//

import Foundation

struct ListSchemasChatTool: ChatTool {
    let name = "list_schemas"
    let description = String(localized: "List schemas available in the active database of a connection.")
    let inputSchema: JsonValue = ChatToolSchemaBuilder.object(
        properties: [
            "connection_id": ChatToolSchemaBuilder.connectionId
        ]
    )
    let mode: ChatToolMode = .readOnly

    func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
        let connectionId = try context.resolveConnectionId(input)
        let payload = try await context.bridge.listSchemas(connectionId: connectionId)
        return ChatToolResult(content: payload.jsonString(prettyPrinted: true))
    }
}
