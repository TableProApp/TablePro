//
//  ExecuteQueryChatTool.swift
//  TablePro
//

import Foundation

/// Run a SQL query against the active connection. Destructive statements
/// (DROP, TRUNCATE, ALTER...DROP) are rejected here; the AI must use the
/// `confirm_destructive_operation` tool with the explicit confirmation phrase.
/// Write queries trigger the connection's safe-mode dialog flow.
struct ExecuteQueryChatTool: ChatTool {
    let name = "execute_query"
    let description = String(localized: """
        Execute a SQL query against a connection. The connection's safe mode policy applies.\
         Multi-statement queries are rejected. Destructive operations (DROP, TRUNCATE, ALTER...DROP)\
         are blocked here; use confirm_destructive_operation instead.
        """)
    let inputSchema: JsonValue = .object([
        "type": .string("object"),
        "properties": .object([
            "connection_id": .object([
                "type": .string("string"),
                "description": .string("UUID of the connection")
            ]),
            "query": .object([
                "type": .string("string"),
                "description": .string("SQL or NoSQL query text")
            ]),
            "max_rows": .object([
                "type": .string("integer"),
                "description": .string("Maximum rows to return (default 500, max 10000)")
            ]),
            "timeout_seconds": .object([
                "type": .string("integer"),
                "description": .string("Query timeout in seconds (default 30, max 300)")
            ]),
            "database": .object([
                "type": .string("string"),
                "description": .string("Switch to this database before executing")
            ]),
            "schema": .object([
                "type": .string("string"),
                "description": .string("Switch to this schema before executing")
            ])
        ]),
        "required": .array([.string("connection_id"), .string("query")])
    ])

    func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
        let connectionId = try resolveConnectionId(input: input, context: context)
        let query = try ChatToolArgumentDecoder.requireString(input, key: "query")
        let database = ChatToolArgumentDecoder.optionalString(input, key: "database")
        let schema = ChatToolArgumentDecoder.optionalString(input, key: "schema")

        guard (query as NSString).length <= 102_400 else {
            return ChatToolResult(content: "Query exceeds 100KB limit", isError: true)
        }
        guard !QueryClassifier.isMultiStatement(query) else {
            return ChatToolResult(
                content: "Multi-statement queries are not supported. Send one statement at a time.",
                isError: true
            )
        }

        let mcpSettings = await MainActor.run { AppSettingsManager.shared.mcp }
        let maxRows = ChatToolArgumentDecoder.optionalInt(
            input,
            key: "max_rows",
            default: mcpSettings.defaultRowLimit,
            clamp: 1...mcpSettings.maxRowLimit
        ) ?? mcpSettings.defaultRowLimit
        let timeoutSeconds = ChatToolArgumentDecoder.optionalInt(
            input,
            key: "timeout_seconds",
            default: mcpSettings.queryTimeoutSeconds,
            clamp: 1...300
        ) ?? mcpSettings.queryTimeoutSeconds

        let meta = try await ToolConnectionMetadata.resolve(connectionId: connectionId)

        // Classify BEFORE mutating session state. A destructive query asked for
        // a database/schema switch should not leave the user on the new context
        // when we then refuse to run it.
        let tier = QueryClassifier.classifyTier(query, databaseType: meta.databaseType)
        if tier == .destructive {
            return ChatToolResult(
                content: "Destructive queries (DROP, TRUNCATE, ALTER...DROP) are blocked here. Use confirm_destructive_operation with the explicit confirmation phrase.",
                isError: true
            )
        }

        if let database {
            _ = try await context.bridge.switchDatabase(connectionId: connectionId, database: database)
        }
        if let schema {
            _ = try await context.bridge.switchSchema(connectionId: connectionId, schema: schema)
        }

        let services = MCPToolServices(connectionBridge: context.bridge, authPolicy: context.authPolicy)
        let payload = try await ToolQueryExecutor.executeAndLog(
            services: services,
            query: query,
            connectionId: connectionId,
            databaseName: meta.databaseName,
            maxRows: maxRows,
            timeoutSeconds: timeoutSeconds,
            principalLabel: String(localized: "AI Chat")
        )
        return ChatToolResult(content: payload.jsonString(prettyPrinted: true))
    }
}
