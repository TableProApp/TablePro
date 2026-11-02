//
//  ConfirmDestructiveOperationChatTool.swift
//  TablePro
//

import Foundation
import TableProMCP
import TableProSQLGrammar

struct ConfirmDestructiveOperationChatTool: ChatTool {
    static let requiredPhrase = "I understand this is irreversible"

    let name = "confirm_destructive_operation"
    let description = String(localized: """
        Execute a destructive DDL query (DROP, TRUNCATE, ALTER...DROP) after explicit confirmation.\
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

        // The refusals MCP makes, from the same gate, the file and server-code one first among them. AI Policy,
        // checked above, governs the assistant, so the External Clients level is not asked.
        let classification: QueryClassification
        do {
            classification = try ExternalStatementGate.classify(
                ExternalStatementGate.Statement(
                    sql: query,
                    connectionId: connectionId,
                    databaseType: meta.databaseType,
                    externalAccess: .readWrite,
                    loadsExtensions: meta.loadsExtensions,
                    allowsDestructive: true
                )
            )
        } catch let refusal as ExternalStatementGateError {
            return ChatToolResult(content: refusal.errorDescription ?? "", isError: true)
        }
        guard classification.tier == .destructive else {
            return ChatToolResult(
                content: "This tool only accepts destructive queries (DROP, TRUNCATE, ALTER...DROP). Use execute_query for other queries.",
                isError: true
            )
        }

        let mcpSettings = await MainActor.run { AppSettingsManager.shared.mcp }
        let scope = try await context.bridge.resolveScope(
            connectionId: connectionId,
            database: nil,
            schema: nil
        )
        let statement = try await context.bridge.plannedStatement(scope: scope, query: query, maxRows: 0)
        let operation = try await context.authPolicy.checkSafeModeDialog(
            operation: PendingOperation(
                scope: scope,
                databaseType: meta.databaseType,
                statements: [statement],
                kind: OperationKind.from(classification.tier),
                caller: .aiAssistant(sessionId: context.sessionId?.uuidString),
                capabilities: context.writeCapabilities,
                operationDescription: MCPAuthPolicy.operationDescription(
                    for: String(localized: "a destructive statement")
                )
            )
        )

        let services = MCPToolServices(connectionBridge: context.bridge, authPolicy: context.authPolicy)
        let payload = try await ToolQueryExecutor.executeAndLog(
            services: services,
            operation: operation,
            maxRows: 0,
            timeoutSeconds: MCPLimitResolver.resolveTimeoutSeconds(requested: nil, settings: mcpSettings),
            principal: .inAppAssistant
        )
        return ChatToolResult(content: payload.jsonString(prettyPrinted: true))
    }
}
