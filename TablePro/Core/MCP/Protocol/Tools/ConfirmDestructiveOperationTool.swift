import Foundation
import os

public struct ConfirmDestructiveOperationTool: MCPToolImplementation {
    public static let name = "confirm_destructive_operation"
    public static let title: String? = String(localized: "Confirm Destructive Operation")
    public static let description = String(
        localized: """
        Run one destructive statement (DROP, TRUNCATE, ALTER...DROP). The user approves it before it \
        runs: through your elicitation prompt when your client supports elicitation, otherwise through \
        TablePro's own confirmation dialog on the user's Mac. Needs tools:write and a connection the \
        user left writable for external clients.
        """
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsWrite]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Confirm Destructive Operation"),
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.connectionId,
            "query": MCPToolSchema.string(String(localized: "The destructive statement to run")),
            "timeout_seconds": MCPToolSchema.integer(String(localized: "Statement timeout"), minimum: 1),
            "database": MCPToolSchema.database,
            "schema": MCPToolSchema.schema
        ],
        required: ["connection_id", "query"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.resultSet

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Tools")

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(
            arguments,
            allowed: MCPScopeArguments.keys.union(["query", "timeout_seconds"])
        )
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        let query = try MCPArgumentDecoder.requireNonEmptyString(arguments, key: "query")
        let meta = try await ToolConnectionMetadata.resolve(connectionId: connectionId)

        let classification = try await MCPStatementGate.authorize(
            sql: query,
            meta: meta,
            allowsDestructive: true,
            operationLabel: String(localized: "a destructive statement"),
            context: context,
            services: services
        )

        guard classification.tier == .destructive else {
            throw MCPToolExecutionError.invalidArgument(
                String(
                    localized: """
                    This tool only runs destructive statements. Use execute_query for everything else.
                    """
                )
            )
        }

        let settings = await services.settingsProvider()
        let timeoutSeconds = try MCPLimitResolver.resolveTimeoutSeconds(arguments, settings: settings)
        let scope = try await MCPScopeArguments.resolve(
            arguments,
            connectionId: connectionId,
            services: services
        )

        Self.logger.debug("confirm_destructive_operation on \(connectionId.uuidString, privacy: .public)")

        let result = try await ToolQueryExecutor.executeAndLog(
            services: services,
            query: query,
            scope: scope,
            maxRows: 0,
            timeoutSeconds: timeoutSeconds,
            context: context,
            secrets: meta.redactionSecrets
        )
        return .structured(result)
    }
}
