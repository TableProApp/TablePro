import Foundation
import os

public struct ConfirmDestructiveOperationTool: MCPToolImplementation {
    public static let name = "confirm_destructive_operation"
    public static let description = String(
        localized: "Execute a destructive DDL query (DROP, TRUNCATE, ALTER...DROP) after explicit confirmation."
    )
    public static let inputSchema: JsonValue = .object([
        "type": .string("object"),
        "properties": .object([
            "connection_id": .object([
                "type": .string("string"),
                "description": .string(String(localized: "UUID of the active connection"))
            ]),
            "query": .object([
                "type": .string("string"),
                "description": .string(String(localized: "The destructive query to execute"))
            ]),
            "confirmation_phrase": .object([
                "type": .string("string"),
                "description": .string(String(localized: "Must be exactly: I understand this is irreversible"))
            ])
        ]),
        "required": .array([
            .string("connection_id"),
            .string("query"),
            .string("confirmation_phrase")
        ])
    ])
    public static let requiredScopes: Set<MCPScope> = [.toolsWrite]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Confirm Destructive Operation"),
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true
    )

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Tools")
    private static let requiredPhrase = "I understand this is irreversible"

    public init() {}

    public func call(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        let query = try MCPArgumentDecoder.requireString(arguments, key: "query")
        let confirmationPhrase = try MCPArgumentDecoder.requireString(arguments, key: "confirmation_phrase")

        guard confirmationPhrase == Self.requiredPhrase else {
            throw MCPProtocolError.invalidParams(
                detail: "confirmation_phrase must be exactly: \(Self.requiredPhrase)"
            )
        }

        guard !QueryClassifier.isMultiStatement(query) else {
            throw MCPProtocolError.invalidParams(
                detail: "Multi-statement queries are not supported. Send one statement at a time."
            )
        }

        let meta = try await ToolConnectionMetadata.resolve(connectionId: connectionId)

        let tier = QueryClassifier.classifyTier(query, databaseType: meta.databaseType)
        guard tier == .destructive else {
            throw MCPProtocolError.invalidParams(
                detail: "This tool only accepts destructive queries (DROP, TRUNCATE, ALTER...DROP). Use execute_query for other queries."
            )
        }

        try await services.authPolicy.checkSafeModeDialog(
            sql: query,
            connectionId: connectionId,
            databaseType: meta.databaseType,
            safeModeLevel: meta.safeModeLevel
        )

        let mcpSettings = await MainActor.run { AppSettingsManager.shared.mcp }
        let timeoutSeconds = mcpSettings.queryTimeoutSeconds

        Self.logger.debug("confirm_destructive_operation invoked for connection \(connectionId.uuidString, privacy: .public)")

        let result = try await ToolQueryExecutor.executeAndLog(
            services: services,
            query: query,
            connectionId: connectionId,
            databaseName: meta.databaseName,
            maxRows: 0,
            timeoutSeconds: timeoutSeconds,
            principalLabel: context.principal.metadata.label
        )

        return .structured(result)
    }
}
