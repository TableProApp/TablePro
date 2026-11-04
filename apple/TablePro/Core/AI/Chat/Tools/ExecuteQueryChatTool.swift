//
//  ExecuteQueryChatTool.swift
//  TablePro
//

import Foundation
import TableProMCP
import TableProSQLGrammar

struct ExecuteQueryChatTool: ChatTool {
    let name = "execute_query"
    let description = String(localized: """
        Execute a SQL query against a connection. The connection's safe mode policy applies.\
         Multi-statement queries are rejected, except on SQL Server, where a whole script runs batch by batch\
         at its GO lines and result_sets lists every result set when there is more than one. Destructive\
         operations (DROP, TRUNCATE, ALTER...DROP) are blocked here; use confirm_destructive_operation instead.
        """)
    let inputSchema: JsonValue = ChatToolSchemaBuilder.object(
        properties: [
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
        let query = try ChatToolArgumentDecoder.requireString(input, key: "query")
        let database = ChatToolArgumentDecoder.optionalString(input, key: "database")
        let schema = ChatToolArgumentDecoder.optionalString(input, key: "schema")

        guard (query as NSString).length <= 102_400 else {
            return ChatToolResult(content: "Query exceeds 100KB limit", isError: true)
        }

        let connectionId = try await ChatToolTarget.authorized(
            context: context,
            input: input,
            tool: name,
            sql: query
        )

        let meta = try await ToolConnectionMetadata.resolve(connectionId: connectionId)
        let capabilities = ExternalStatementGate.capabilities(
            context.writeCapabilities,
            takingScriptsOn: meta.databaseType
        )

        // The refusals MCP makes, from the same gate. AI Policy, checked above, governs the assistant, so the
        // External Clients level is not asked.
        let classification: QueryClassification
        do {
            classification = try ExternalStatementGate.classify(
                ExternalStatementGate.Statement(
                    sql: query,
                    connectionId: connectionId,
                    databaseType: meta.databaseType,
                    externalAccess: .readWrite,
                    loadsExtensions: meta.loadsExtensions,
                    allowsDestructive: false,
                    allowsMultiStatement: capabilities.contains(.mayRunMultiStatement),
                    destructiveAlternative: String(
                        localized: "Use confirm_destructive_operation with the explicit confirmation phrase."
                    )
                )
            )
        } catch let refusal as ExternalStatementGateError {
            return ChatToolResult(content: refusal.errorDescription ?? "", isError: true)
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

        let scope = try await context.bridge.resolveScope(
            connectionId: connectionId,
            database: database,
            schema: schema
        )
        let planned = try await context.bridge.plannedScript(scope: scope, query: query, maxRows: maxRows)
        let operation = try await context.authPolicy.checkSafeModeDialog(
            operation: PendingOperation(
                scope: scope,
                databaseType: meta.databaseType,
                statements: [planned.statement],
                kind: OperationKind.from(classification.tier),
                unit: planned.unit,
                caller: .aiAssistant(sessionId: context.sessionId?.uuidString),
                capabilities: capabilities,
                operationDescription: MCPAuthPolicy.operationDescription(for: String(localized: "a query"))
            )
        )

        let services = MCPToolServices(connectionBridge: context.bridge, authPolicy: context.authPolicy)
        let payload = try await ToolQueryExecutor.executeAndLog(
            services: services,
            operation: operation,
            maxRows: maxRows,
            timeoutSeconds: timeoutSeconds,
            principal: .inAppAssistant
        )
        return ChatToolResult(content: payload.jsonString(prettyPrinted: true))
    }
}
