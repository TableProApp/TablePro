import Foundation
import os

public struct ExecuteQueryTool: MCPToolImplementation {
    public static let name = "execute_query"
    public static let title: String? = String(localized: "Execute Query")
    public static let description = String(
        localized: """
        Run one statement. Reads need tools:read; anything that writes needs tools:write and is subject \
        to the connection's Safe Mode, which asks the user to approve it. DROP and TRUNCATE go through \
        confirm_destructive_operation instead. Statements that read or write files, or run server-side \
        code, are refused. Send one statement per call.
        """
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Execute Query"),
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: true
    )

    static let maximumQueryBytes = 102_400

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.connectionId,
            "query": MCPToolSchema.string(String(localized: "One SQL or NoSQL statement")),
            "max_rows": MCPToolSchema.integer(
                String(localized: "Maximum rows to return. Defaults to the server's configured row limit."),
                minimum: 1
            ),
            "timeout_seconds": MCPToolSchema.integer(
                String(localized: "Statement timeout. Defaults to the server's configured timeout."),
                minimum: 1
            ),
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
            allowed: MCPScopeArguments.keys.union(["query", "max_rows", "timeout_seconds"])
        )
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        let query = try MCPArgumentDecoder.requireNonEmptyString(arguments, key: "query")

        guard (query as NSString).length <= Self.maximumQueryBytes else {
            throw MCPToolExecutionError.invalidArgument(
                String(localized: "The query exceeds the 100KB limit.")
            )
        }

        let settings = await services.settingsProvider()
        let maxRows = try MCPLimitResolver.resolveMaxRows(arguments, settings: settings)
        let timeoutSeconds = try MCPLimitResolver.resolveTimeoutSeconds(arguments, settings: settings)

        try await context.throwIfCancelled()
        await context.progress.emit(progress: 0.0, total: 1.0, message: "Resolving connection")

        let meta = try await ToolConnectionMetadata.resolve(connectionId: connectionId)
        try await MCPStatementGate.authorize(
            sql: query,
            meta: meta,
            allowsDestructive: false,
            operationLabel: String(localized: "a query"),
            context: context,
            services: services
        )

        let scope = try await MCPScopeArguments.resolve(
            arguments,
            connectionId: connectionId,
            services: services
        )

        try await context.throwIfCancelled()
        await context.progress.emit(progress: 0.3, total: 1.0, message: "Executing")

        Self.logger.debug("execute_query on \(connectionId.uuidString, privacy: .public)")

        let result = try await ToolQueryExecutor.executeAndLog(
            services: services,
            query: query,
            scope: scope,
            maxRows: maxRows,
            timeoutSeconds: timeoutSeconds,
            context: context,
            secrets: meta.redactionSecrets
        )

        await context.progress.emit(progress: 1.0, total: 1.0, message: "Done")
        return .structured(result)
    }
}
