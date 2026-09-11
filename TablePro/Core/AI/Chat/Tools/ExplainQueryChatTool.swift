//
//  ExplainQueryChatTool.swift
//  TablePro
//

import Foundation

/// The engine's own plan for a statement, so a session can say why a query is slow instead of
/// guessing from the SQL.
///
/// `analyze` is deliberately absent from the schema. The MCP tool this wraps takes it, and it runs
/// the statement for real; a `.readOnly` chat tool is auto-approved, so exposing it here would give
/// the model a way to execute an `UPDATE` with no card and no Safe Mode check. A model that wants a
/// statement run asks `execute_query`, which is gated.
struct ExplainQueryChatTool: ChatTool {
    let name = "explain_query"
    let description = String(localized: """
        Ask the engine for the query plan of a statement, without running it. Pass the statement with\
         no EXPLAIN prefix. Call this when a query is slow or when a plan would settle whether an\
         index is used.
        """)
    let inputSchema: JsonValue = ChatToolSchemaBuilder.object(
        properties: [
            "connection_id": ChatToolSchemaBuilder.connectionId,
            "query": ChatToolSchemaBuilder.string(description: "The statement to explain, without an EXPLAIN prefix"),
            "variant": ChatToolSchemaBuilder.string(
                description: "Explain variant id for this engine. Pass null for the engine's default.",
                optional: true
            ),
            "database": ChatToolSchemaBuilder.string(
                description: "Explain against this database. Pass null to use current.",
                optional: true
            ),
            "schema": ChatToolSchemaBuilder.schemaName
        ]
    )
    let mode: ChatToolMode = .readOnly

    func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
        let connectionId = try context.resolveConnectionId(input)
        let query = try ChatToolArgumentDecoder.requireString(input, key: "query")
        let variant = ChatToolArgumentDecoder.optionalString(input, key: "variant")
        let database = ChatToolArgumentDecoder.optionalString(input, key: "database")
        let schema = ChatToolArgumentDecoder.optionalString(input, key: "schema")

        let meta = try await ToolConnectionMetadata.resolve(connectionId: connectionId)
        let statement = try MCPConnectionBridge.explainStatement(
            for: query,
            databaseType: meta.databaseType,
            variantId: variant,
            analyze: false
        )

        let mcpSettings = await MainActor.run { AppSettingsManager.shared.mcp }
        let timeoutSeconds = MCPLimitResolver.resolveTimeoutSeconds(requested: nil, settings: mcpSettings)
        let scope = try await context.bridge.resolveScope(
            connectionId: connectionId,
            database: database,
            schema: schema
        )

        var payload = try await context.bridge.explainQuery(
            scope: scope,
            sql: statement,
            timeoutSeconds: timeoutSeconds,
            cancellation: nil
        )
        if case .object(var fields) = payload {
            fields["available_variants"] = MCPConnectionBridge.explainVariants(for: meta.databaseType)
            payload = .object(fields)
        }
        return ChatToolResult(content: payload.jsonString(prettyPrinted: true))
    }
}
