//
//  ListTablesChatTool.swift
//  TablePro
//

import Foundation

struct ListTablesChatTool: ChatTool {
    let name = "list_tables"
    let description = String(localized: "List tables and views in the active database of a connection.")
    let inputSchema: JsonValue = ChatToolSchemaBuilder.object(
        properties: [
            "connection_id": ChatToolSchemaBuilder.connectionId,
            "database": ChatToolSchemaBuilder.string(description: "Database name (uses current if omitted)"),
            "schema": ChatToolSchemaBuilder.schemaName,
            "include_row_counts": ChatToolSchemaBuilder.boolean(
                description: "Include approximate row counts (default false)"
            )
        ]
    )
    let mode: ChatToolMode = .readOnly

    func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
        let connectionId = try context.resolveConnectionId(input)
        let database = ChatToolArgumentDecoder.optionalString(input, key: "database")
        let schema = ChatToolArgumentDecoder.optionalString(input, key: "schema")
        let includeRowCounts = ChatToolArgumentDecoder.optionalBool(input, key: "include_row_counts", default: false)

        if let database {
            _ = try await context.bridge.switchDatabase(connectionId: connectionId, database: database)
        }
        if let schema {
            _ = try await context.bridge.switchSchema(connectionId: connectionId, schema: schema)
        }

        let payload = try await context.bridge.listTables(
            connectionId: connectionId,
            includeRowCounts: includeRowCounts
        )
        return ChatToolResult(content: payload.jsonString(prettyPrinted: true))
    }
}
