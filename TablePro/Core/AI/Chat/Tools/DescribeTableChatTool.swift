//
//  DescribeTableChatTool.swift
//  TablePro
//

import Foundation

struct DescribeTableChatTool: ChatTool {
    let name = "describe_table"
    let description = String(localized: "Describe the columns of a table or view.")
    let inputSchema: JsonValue = .object([
        "type": .string("object"),
        "properties": .object([
            "connection_id": .object([
                "type": .string("string"),
                "description": .string("UUID of the connection")
            ]),
            "table": .object([
                "type": .string("string"),
                "description": .string("Table or view name")
            ]),
            "schema": .object([
                "type": .string("string"),
                "description": .string("Schema name (uses current if omitted)")
            ])
        ]),
        "required": .array([.string("table")])
    ])

    func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
        let connectionId = try resolveConnectionId(input: input, context: context)
        let table = try ChatToolArgumentDecoder.requireString(input, key: "table")
        let schema = ChatToolArgumentDecoder.optionalString(input, key: "schema")
        let payload = try await context.bridge.describeTable(
            connectionId: connectionId,
            table: table,
            schema: schema
        )
        return ChatToolResult(content: payload.jsonString(prettyPrinted: true))
    }
}
