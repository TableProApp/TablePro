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
            "database": ChatToolSchemaBuilder.string(
                description: "Database name. Pass null to use current.",
                optional: true
            )
        ]
    )
    let mode: ChatToolMode = .readOnly

    func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
        let connectionId = try await ChatToolTarget.authorized(context: context, input: input, tool: name)
        let database = ChatToolArgumentDecoder.optionalString(input, key: "database")
        let scope = try await context.bridge.resolveScope(
            connectionId: connectionId,
            database: database,
            schema: nil
        )
        let payload = try await context.bridge.listSchemas(scope: scope)
        return ChatToolResult(content: payload.jsonString(prettyPrinted: true))
    }
}
