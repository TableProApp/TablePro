import Foundation
import os

public struct ExecuteQueryTool: MCPToolImplementation {
    public static let name = "execute_query"
    public static let description = String(
        localized: "Execute a SQL query. All queries are subject to the connection's safe mode policy. DROP/TRUNCATE/ALTER...DROP must use the confirm_destructive_operation tool."
    )
    public static let inputSchema: JsonValue = .object([
        "type": .string("object"),
        "properties": .object([
            "connection_id": .object([
                "type": .string("string"),
                "description": .string(String(localized: "UUID of the connection"))
            ]),
            "query": .object([
                "type": .string("string"),
                "description": .string(String(localized: "SQL or NoSQL query text"))
            ]),
            "max_rows": .object([
                "type": .string("integer"),
                "description": .string(String(localized: "Maximum rows to return (default 500, max 10000)"))
            ]),
            "timeout_seconds": .object([
                "type": .string("integer"),
                "description": .string(String(localized: "Query timeout in seconds (default 30, max 300)"))
            ]),
            "database": .object([
                "type": .string("string"),
                "description": .string(String(localized: "Switch to this database before executing"))
            ]),
            "schema": .object([
                "type": .string("string"),
                "description": .string(String(localized: "Switch to this schema before executing"))
            ])
        ]),
        "required": .array([.string("connection_id"), .string("query")])
    ])
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Execute Query"),
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: true
    )

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Tools")

    public init() {}

    public func call(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        let query = try MCPArgumentDecoder.requireString(arguments, key: "query")

        let mcpSettings = await MainActor.run { AppSettingsManager.shared.mcp }
        let maxRows = MCPArgumentDecoder.optionalInt(
            arguments,
            key: "max_rows",
            default: mcpSettings.defaultRowLimit,
            clamp: 1...mcpSettings.maxRowLimit
        ) ?? mcpSettings.defaultRowLimit
        let timeoutSeconds = MCPArgumentDecoder.optionalInt(
            arguments,
            key: "timeout_seconds",
            default: mcpSettings.queryTimeoutSeconds,
            clamp: 1...300
        ) ?? mcpSettings.queryTimeoutSeconds
        let database = MCPArgumentDecoder.optionalString(arguments, key: "database")
        let schema = MCPArgumentDecoder.optionalString(arguments, key: "schema")

        guard (query as NSString).length <= 102_400 else {
            throw MCPProtocolError.invalidParams(detail: "Query exceeds 100KB limit")
        }

        guard !QueryClassifier.isMultiStatement(query) else {
            throw MCPProtocolError.invalidParams(
                detail: "Multi-statement queries are not supported. Send one statement at a time."
            )
        }

        try await throwIfCancelled(context)
        await context.progress.emit(progress: 0.0, total: 1.0, message: "Connecting")

        let meta = try await ToolConnectionMetadata.resolve(connectionId: connectionId)

        if let database {
            _ = try await services.connectionBridge.switchDatabase(
                connectionId: connectionId,
                database: database
            )
        }
        if let schema {
            _ = try await services.connectionBridge.switchSchema(
                connectionId: connectionId,
                schema: schema
            )
        }

        try await throwIfCancelled(context)
        await context.progress.emit(progress: 0.2, total: 1.0, message: "Executing")

        let tier = QueryClassifier.classifyTier(query, databaseType: meta.databaseType)
        try classifyAndAuthorize(
            tier: tier,
            query: query,
            connectionId: connectionId,
            meta: meta,
            services: services,
            context: context
        )

        try await services.authPolicy.checkSafeModeDialog(
            sql: query,
            connectionId: connectionId,
            databaseType: meta.databaseType,
            safeModeLevel: meta.safeModeLevel
        )

        Self.logger.debug("execute_query invoked for connection \(connectionId.uuidString, privacy: .public)")

        let result = try await ToolQueryExecutor.executeAndLog(
            services: services,
            query: query,
            connectionId: connectionId,
            databaseName: meta.databaseName,
            maxRows: maxRows,
            timeoutSeconds: timeoutSeconds,
            principalLabel: context.principal.metadata.label
        )

        try await throwIfCancelled(context)
        await context.progress.emit(progress: 0.8, total: 1.0, message: "Formatting result")

        await context.progress.emit(progress: 1.0, total: 1.0, message: "Done")
        return .structured(result)
    }

    private func classifyAndAuthorize(
        tier: QueryTier,
        query: String,
        connectionId: UUID,
        meta: ToolConnectionMetadata,
        services: MCPToolServices,
        context: MCPRequestContext
    ) throws {
        switch tier {
        case .destructive:
            throw MCPProtocolError.forbidden(
                reason: "Destructive queries (DROP, TRUNCATE, ALTER...DROP) cannot be executed via execute_query. Use the confirm_destructive_operation tool instead."
            )
        case .write:
            guard context.principal.scopes.contains(.toolsWrite) else {
                throw MCPProtocolError.forbidden(
                    reason: "Principal lacks tools:write scope required for write queries"
                )
            }
        case .safe:
            return
        }
    }

    private func throwIfCancelled(_ context: MCPRequestContext) async throws {
        guard await context.cancellation.isCancelled() else { return }
        throw MCPProtocolError(
            code: JsonRpcErrorCode.requestCancelled,
            message: "Cancelled",
            httpStatus: .ok
        )
    }
}
