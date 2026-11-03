import Foundation
import os
import TableProMCP

public struct ConfirmDestructiveOperationTool: MCPToolImplementation {
    public static let name = "confirm_destructive_operation"
    public static let title: String? = String(localized: "Confirm Destructive Operation")
    public static let description = String(
        localized: """
        Run what execute_query refuses as destructive, such as DROP, TRUNCATE, ALTER...DROP or a DELETE \
        with no WHERE: one statement, or on SQL Server a whole script. Anything else is refused. The user \
        approves it before it runs: through your elicitation prompt when your client supports elicitation, \
        otherwise through TablePro's own confirmation dialog on the user's Mac. Needs tools:write and a \
        connection the user left writable for external clients.
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

    public static let outputSchema: JsonValue? = MCPToolSchema.scriptResult

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
        let allowsMultiStatement = ExternalStatementGate.acceptsScripts(on: meta.databaseType)

        try MCPStatementGate.classify(
            sql: query,
            meta: meta,
            allowsDestructive: true,
            allowsMultiStatement: allowsMultiStatement,
            context: context
        )
        try MCPStatementGate.requireDestructive(sql: query, meta: meta)

        let settings = await services.settingsProvider()
        let timeoutSeconds = try MCPLimitResolver.resolveTimeoutSeconds(arguments, settings: settings)
        let scope = try await MCPScopeArguments.resolve(
            arguments,
            connectionId: connectionId,
            services: services
        )
        let planned: DatabaseAccessBridge.PlannedText
        do {
            planned = try await services.connectionBridge.plannedScript(scope: scope, query: query, maxRows: 0)
        } catch {
            throw ToolQueryExecutor.translate(error, secrets: meta.redactionSecrets)
        }
        let operation = try await MCPStatementGate.approve(
            [planned.statement],
            kind: .destructiveQuery,
            unit: planned.unit,
            scope: scope,
            meta: meta,
            allowsDestructive: true,
            allowsMultiStatement: allowsMultiStatement,
            operationLabel: String(localized: "a destructive statement"),
            context: context,
            services: services
        )

        Self.logger.debug("confirm_destructive_operation on \(connectionId.uuidString, privacy: .public)")

        let result = try await ToolQueryExecutor.executeAndLog(
            services: services,
            operation: operation,
            maxRows: 0,
            timeoutSeconds: timeoutSeconds,
            context: context,
            secrets: meta.redactionSecrets
        )
        return .structured(result)
    }
}
