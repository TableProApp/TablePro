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
            "database": ChatToolSchemaBuilder.string(
                description: "Database name. Pass null to use current.",
                optional: true
            ),
            "schema": ChatToolSchemaBuilder.schemaName
        ]
    )
    let mode: ChatToolMode = .readOnly

    func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
        let connectionId = try context.resolveConnectionId(input)
        let table = try ChatToolArgumentDecoder.requireString(input, key: "table")
        let database = ChatToolArgumentDecoder.optionalString(input, key: "database")
        let schema = ChatToolArgumentDecoder.optionalString(input, key: "schema")

        let scope = try await context.bridge.resolveScope(
            connectionId: connectionId,
            database: database,
            schema: schema
        )
        let payload = try await context.bridge.getTableDDL(scope: scope, table: table)
        return ChatToolResult(content: payload.jsonString(prettyPrinted: true))
    }
}
