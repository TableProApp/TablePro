//
//  ExecuteQueryChatTool.swift
//  TablePro
//

import Foundation

struct ExecuteQueryChatTool: ChatTool {
    let name = "execute_query"
    let description = String(localized: """
        Execute a SQL query against a connection. The connection's safe mode policy applies.\
         Multi-statement queries are rejected. Destructive operations (DROP, TRUNCATE, ALTER...DROP)\
         are blocked here; use confirm_destructive_operation instead.
        """)
    let inputSchema: JsonValue = ChatToolSchemaBuilder.object(
        properties: [
            "connection_id": ChatToolSchemaBuilder.connectionId,
            "query": ChatToolSchemaBuilder.string(description: "SQL or NoSQL query text"),
            "max_rows": ChatToolSchemaBuilder.integer(
                description: "Maximum rows to return, capped at the server's configured maximum row limit. Pass null to use the configured default row limit.",
                optional: true
            ),
            "timeout_seconds": ChatToolSchemaBuilder.integer(
                description: "Query timeout in seconds (max 300). Pass null to use the server's configured query timeout.",
                optional: true
            ),
            "database": ChatToolSchemaBuilder.string(
                description: "Run against this database. Pass null to use current.",
                optional: true
            ),
            "schema": ChatToolSchemaBuilder.string(
                description: "Run against this schema. Pass null to use current.",
                optional: true
            )
        ]
    )
    let mode: ChatToolMode = .write

    func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
        let connectionId = try context.resolveConnectionId(input)
        let query = try ChatToolArgumentDecoder.requireString(input, key: "query")
        let database = ChatToolArgumentDecoder.optionalString(input, key: "database")
        let schema = ChatToolArgumentDecoder.optionalString(input, key: "schema")

        guard (query as NSString).length <= 102_400 else {
            return ChatToolResult(content: "Query exceeds 100KB limit", isError: true)
        }

        let meta = try await ToolConnectionMetadata.resolve(connectionId: connectionId)

        guard !QueryClassifier.isMultiStatement(query, databaseType: meta.databaseType) else {
            return ChatToolResult(
                content: "Multi-statement queries are not supported. Send one statement at a time.",
                isError: true
            )
        }

        let mcpSettings = await MainActor.run { AppSettingsManager.shared.mcp }
        let maxRows = MCPLimitResolver.resolveMaxRows(
            requested: ChatToolArgumentDecoder.optionalInt(input, key: "max_rows"),
            settings: mcpSettings
        )
        let timeoutSeconds = MCPLimitResolver.resolveTimeoutSeconds(
            requested: ChatToolArgumentDecoder.optionalInt(input, key: "timeout_seconds"),
            settings: mcpSettings
        )

        let tier = QueryClassifier.classifyTier(query, databaseType: meta.databaseType)
        if tier == .destructive {
            return ChatToolResult(
                content: "Destructive queries (DROP, TRUNCATE, ALTER...DROP) are blocked here. Use confirm_destructive_operation with the explicit confirmation phrase.",
                isError: true
            )
        }

        let scope = try await context.bridge.resolveScope(
            connectionId: connectionId,
            database: database,
            schema: schema
        )

        try await context.authPolicy.checkSafeModeDialog(
            sql: query,
            connectionId: connectionId,
            databaseType: meta.databaseType,
            capabilities: [.mayWrite, .mayRunDestructive, .confirmationPreCleared]
        )

        let services = MCPToolServices(connectionBridge: context.bridge, authPolicy: context.authPolicy)
        let payload = try await ToolQueryExecutor.executeAndLog(
            services: services,
            query: query,
            scope: scope,
            maxRows: maxRows,
            timeoutSeconds: timeoutSeconds,
            principal: .inAppAssistant
        )
        return ChatToolResult(content: payload.jsonString(prettyPrinted: true))
    }
}
