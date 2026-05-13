//
//  ListDatabasesChatTool.swift
//  TablePro
//

import Foundation

struct ListDatabasesChatTool: ChatTool {
    let name = "list_databases"
    let description = String(localized: "List databases available on a connection.")
    let inputSchema: JsonValue = ChatToolSchemaBuilder.object(
        properties: [
            "connection_id": ChatToolSchemaBuilder.connectionId
        ]
    )
    let mode: ChatToolMode = .readOnly

    func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
        let connectionId = try context.resolveConnectionId(input)
        let payload = try await context.bridge.listDatabases(connectionId: connectionId)
        return ChatToolResult(content: payload.jsonString(prettyPrinted: true))
    }
}
