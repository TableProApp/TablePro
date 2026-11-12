//
//  ConfirmDestructiveOperationChatTool.swift
//  TablePro
//

import Foundation
import TableProMCP

struct ConfirmDestructiveOperationChatTool: ChatTool {
    static let requiredPhrase = "I understand this is irreversible"

    let name = "confirm_destructive_operation"
    let description = String(localized: """
        Execute what execute_query refuses as destructive, such as DROP, TRUNCATE, ALTER...DROP or a DELETE\
         with no WHERE, after explicit confirmation: one statement, or on SQL Server a whole script.\
         Pass confirmation_phrase exactly as: I understand this is irreversible
        """)
    let inputSchema: JsonValue = ChatToolSchemaBuilder.object(
        properties: [
            "query": ChatToolSchemaBuilder.string(description: "The destructive query to execute"),
            "confirmation_phrase": ChatToolSchemaBuilder.string(
                description: "Must be exactly: I understand this is irreversible"
            )
        ],
        required: ["query", "confirmation_phrase"]
    )
    let mode: ChatToolMode = .agentOnly

    func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
        let query = try ChatToolArgumentDecoder.requireString(input, key: "query")
        let confirmationPhrase = try ChatToolArgumentDecoder.requireString(input, key: "confirmation_phrase")

        guard confirmationPhrase == Self.requiredPhrase else {
            return ChatToolResult(
                content: "confirmation_phrase must be exactly: \(Self.requiredPhrase)",
                isError: true
            )
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

        // The refusals MCP makes, from the same gate, the file and server-code one first among them. AI Policy,
        // checked above, governs the assistant, so the External Clients level is not asked.
        do {
            try ExternalStatementGate.classify(
                ExternalStatementGate.Statement(
                    sql: query,
                    connectionId: connectionId,
                    databaseType: meta.databaseType,
                    externalAccess: .readWrite,
                    loadsExtensions: meta.loadsExtensions,
                    allowsDestructive: true,
                    allowsMultiStatement: capabilities.contains(.mayRunMultiStatement)
                )
            )
            try ExternalStatementGate.requireDestructive(query, databaseType: meta.databaseType)
        } catch let refusal as ExternalStatementGateError {
            return ChatToolResult(content: refusal.errorDescription ?? "", isError: true)
        }

        let mcpSettings = await MainActor.run { AppSettingsManager.shared.mcp }
        // A script holds each result set to this, as execute_query does; 0 would keep one row on SQL Server.
        let maxRows = MCPLimitResolver.resolveMaxRows(requested: nil, settings: mcpSettings)
        let scope = try await context.bridge.resolveScope(
            connectionId: connectionId,
            database: nil,
            schema: nil
        )
        let planned = try await context.bridge.plannedScript(scope: scope, query: query, maxRows: maxRows)
        let operation = try await context.authPolicy.checkSafeModeDialog(
            operation: PendingOperation(
                scope: scope,
                databaseType: meta.databaseType,
                statements: [planned.statement],
                kind: .destructiveQuery,
                unit: planned.unit,
                caller: .aiAssistant(sessionId: context.sessionId?.uuidString),
                capabilities: capabilities,
                operationDescription: MCPAuthPolicy.operationDescription(
                    for: String(localized: "a destructive statement")
                )
            )
        )

        let services = MCPToolServices(connectionBridge: context.bridge, authPolicy: context.authPolicy)
        let payload = try await ToolQueryExecutor.executeAndLog(
            services: services,
            operation: operation,
            maxRows: maxRows,
            timeoutSeconds: MCPLimitResolver.resolveTimeoutSeconds(requested: nil, settings: mcpSettings),
            principal: .inAppAssistant,
            budget: .assistantAnswer
        )
        return ChatToolResult(content: payload.jsonString(prettyPrinted: true))
    }
}
