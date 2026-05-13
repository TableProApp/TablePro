//
//  ConfirmDestructiveOperationChatTool.swift
//  TablePro
//

import Foundation

struct ConfirmDestructiveOperationChatTool: ChatTool {
    static let requiredPhrase = "I understand this is irreversible"

    let name = "confirm_destructive_operation"
    let description = String(localized: """
        Execute a destructive DDL query (DROP, TRUNCATE, ALTER...DROP) after explicit confirmation.\
         Pass confirmation_phrase exactly as: I understand this is irreversible
        """)
    let inputSchema: JsonValue = ChatToolSchemaBuilder.object(
        properties: [
            "connection_id": ChatToolSchemaBuilder.connectionId,
            "query": ChatToolSchemaBuilder.string(description: "The destructive query to execute"),
            "confirmation_phrase": ChatToolSchemaBuilder.string(
                description: "Must be exactly: I understand this is irreversible"
            )
        ],
        required: ["connection_id", "query", "confirmation_phrase"]
    )
    let mode: ChatToolMode = .agentOnly

    func execute(input: JsonValue, context: ChatToolContext) async throws -> ChatToolResult {
        let connectionId = try context.resolveConnectionId(input)
        let query = try ChatToolArgumentDecoder.requireString(input, key: "query")
        let confirmationPhrase = try ChatToolArgumentDecoder.requireString(input, key: "confirmation_phrase")

        guard confirmationPhrase == Self.requiredPhrase else {
            return ChatToolResult(
                content: "confirmation_phrase must be exactly: \(Self.requiredPhrase)",
                isError: true
            )
        }
        guard !QueryClassifier.isMultiStatement(query) else {
            return ChatToolResult(
                content: "Multi-statement queries are not supported. Send one statement at a time.",
                isError: true
            )
        }

        let meta = try await ToolConnectionMetadata.resolve(connectionId: connectionId)
        let tier = QueryClassifier.classifyTier(query, databaseType: meta.databaseType)
        guard tier == .destructive else {
            return ChatToolResult(
                content: "This tool only accepts destructive queries (DROP, TRUNCATE, ALTER...DROP). Use execute_query for other queries.",
                isError: true
            )
        }

        let mcpSettings = await MainActor.run { AppSettingsManager.shared.mcp }
        let services = MCPToolServices(connectionBridge: context.bridge, authPolicy: context.authPolicy)
        let payload = try await ToolQueryExecutor.executeAndLog(
            services: services,
            query: query,
            connectionId: connectionId,
            databaseName: meta.databaseName,
            maxRows: 0,
            timeoutSeconds: mcpSettings.queryTimeoutSeconds,
            principalLabel: String(localized: "AI Chat")
        )
        return ChatToolResult(content: payload.jsonString(prettyPrinted: true))
    }
}
