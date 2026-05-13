//
//  GetTableDDLChatTool.swift
//  TablePro
//

import Foundation

struct GetTableDDLChatTool: ChatTool {
    let name = "get_table_ddl"
    let description = String(localized: "Get the DDL (CREATE statement) for a table.")
    let inputSchema: JsonValue = ChatToolSchemaBuilder.object(
        properties: [
            "connection_id": ChatToolSchemaBuilder.connectionId,
            "table": ChatToolSchemaBuilder.string(description: "Table name"),
            "schema": ChatToolSchemaBuilder.schemaName
        ],
        required: ["table"]
    )
    let mode: ChatToolMode = .readOnly

    func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
        let connectionId = try context.resolveConnectionId(input)
        let table = try ChatToolArgumentDecoder.requireString(input, key: "table")
        let schema = ChatToolArgumentDecoder.optionalString(input, key: "schema")
        let payload = try await context.bridge.getTableDDL(
            connectionId: connectionId,
            table: table,
            schema: schema
        )
        return ChatToolResult(content: payload.jsonString(prettyPrinted: true))
    }
}
