//
//  ListDatabasesChatTool.swift
//  TablePro
//

import Foundation

struct ListDatabasesChatTool: ChatTool {
    let name = "list_databases"
    let description = String(localized: "List databases available on a connection.")
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "connection_id": .object([
                "type": .string("string"),
                "description": .string("UUID of the connection")
            ])
        ])
    ])

    func execute(input: JSONValue, context: ChatToolContext) async throws -> ChatToolResult {
        let connectionId = try resolveConnectionId(input: input, context: context)
        let payload = try await context.bridge.listDatabases(connectionId: connectionId)
        return ChatToolResult(content: try ChatToolJSONFormatter.string(from: payload))
    }
}
