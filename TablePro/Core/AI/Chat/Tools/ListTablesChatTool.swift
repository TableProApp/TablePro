//
//  ListTablesChatTool.swift
//  TablePro
//

import Foundation

struct ListTablesChatTool: ChatTool {
    let name = "list_tables"
    let description = String(localized: "List tables and views in the active database of a connection.")
    let inputSchema: JsonValue = .object([
        "type": .string("object"),
        "properties": .object([
            "connection_id": .object([
                "type": .string("string"),
                "description": .string("UUID of the connection")
            ]),
            "database": .object([
                "type": .string("string"),
                "description": .string("Database name (uses current if omitted)")
            ]),
            "schema": .object([
                "type": .string("string"),
                "description": .string("Schema name (uses current if omitted)")
            ]),
            "include_row_counts": .object([
                "type": .string("boolean"),
                "description": .string("Include approximate row counts (default false)")
            ])
        ])
    ])

    func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
        let connectionId = try resolveConnectionId(input: input, context: context)
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
