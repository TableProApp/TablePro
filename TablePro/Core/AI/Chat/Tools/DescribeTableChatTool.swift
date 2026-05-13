//
//  DescribeTableChatTool.swift
//  TablePro
//

import Foundation

struct DescribeTableChatTool: ChatTool {
    let name = "describe_table"
    let description = String(localized: "Describe the columns of a table or view.")
    let inputSchema: JsonValue = ChatToolSchemaBuilder.object(
        properties: [
            "connection_id": ChatToolSchemaBuilder.connectionId,
            "table": ChatToolSchemaBuilder.string(description: "Table or view name"),
            "schema": ChatToolSchemaBuilder.schemaName
        ],
        required: ["table"]
    )
    let mode: ChatToolMode = .readOnly

    func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
        let connectionId = try context.resolveConnectionId(input)
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
