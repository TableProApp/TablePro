import Foundation

public struct ListMaintenanceOperationsTool: MCPToolImplementation {
    public static let name = "list_maintenance_operations"
    public static let title: String? = String(localized: "List Maintenance Operations")
    public static let description = String(
        localized: "List the maintenance operations this engine supports, such as VACUUM, ANALYZE, or OPTIMIZE."
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "List Maintenance Operations"),
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: ["connection_id": MCPToolSchema.connectionId],
        required: ["connection_id"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "operations": MCPToolSchema.array(
                String(localized: "Operation names, sorted"),
                of: MCPToolSchema.stringItem
            ),
            "is_supported": MCPToolSchema.boolean(String(localized: "Whether this engine has maintenance at all"))
        ],
        required: ["operations", "is_supported"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: ["connection_id"])
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        let payload = try await services.connectionBridge.maintenanceOperations(connectionId: connectionId)
        return .structured(payload)
    }
}

public struct RunMaintenanceTool: MCPToolImplementation {
    public static let name = "run_maintenance"
    public static let title: String? = String(localized: "Run Maintenance")
    public static let description = String(
        localized: """
        Run a maintenance operation the engine supports, on one table or on the whole database. TablePro \
        generates the statements; the user approves them. Needs tools:write.
        """
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsWrite]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Run Maintenance"),
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: true
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.connectionId,
            "operation": MCPToolSchema.string(
                String(localized: "Operation name from list_maintenance_operations")
            ),
            "table": MCPToolSchema.string(String(localized: "Table to act on. Omit for the whole database.")),
            "options": MCPToolSchema.object(
                properties: [:],
                required: [],
                allowsAdditional: true
            ),
            "database": MCPToolSchema.database,
            "schema": MCPToolSchema.schema
        ],
        required: ["connection_id", "operation"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "operation": MCPToolSchema.string(String(localized: "Operation that ran")),
            "statements": MCPToolSchema.array(
                String(localized: "Statements TablePro generated and ran"),
                of: MCPToolSchema.stringItem
            ),
            "results": MCPToolSchema.array(
                String(localized: "One result per statement"),
                of: MCPToolSchema.resultSet
            )
        ],
        required: ["operation", "statements", "results"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(
            arguments,
            allowed: MCPScopeArguments.keys.union(["operation", "table", "options"])
        )
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        let operation = try MCPArgumentDecoder.requireNonEmptyString(arguments, key: "operation")
        let table = try MCPArgumentDecoder.optionalString(arguments, key: "table")
        var options: [String: String] = [:]
        if let raw = arguments["options"]?.objectValue {
            for (key, value) in raw {
                guard let text = value.stringValue else {
                    throw MCPProtocolError.invalidParams(detail: "Every value in 'options' must be a string")
                }
                options[key] = text
            }
        }

        let meta = try await ToolConnectionMetadata.resolve(connectionId: connectionId)
        let statements: [String]
        do {
            statements = try await services.connectionBridge.maintenanceStatements(
                connectionId: connectionId,
                operation: operation,
                table: table,
                options: options
            )
        } catch let error as MCPDataLayerError {
            throw MCPToolExecutionError.from(error, secrets: meta.redactionSecrets)
        }

        let settings = await services.settingsProvider()
        let timeoutSeconds = try MCPLimitResolver.resolveTimeoutSeconds(arguments, settings: settings)
        let scope = try await MCPScopeArguments.resolve(
            arguments,
            connectionId: connectionId,
            services: services
        )

        var results: [JsonValue] = []
        for statement in statements {
            try await MCPStatementGate.authorize(
                sql: statement,
                meta: meta,
                allowsDestructive: true,
                operationLabel: String(
                    format: String(localized: "maintenance operation %@"),
                    operation
                ),
                context: context,
                services: services
            )
            let result = try await ToolQueryExecutor.executeAndLog(
                services: services,
                query: statement,
                scope: scope,
                maxRows: 1_000,
                timeoutSeconds: timeoutSeconds,
                context: context,
                secrets: meta.redactionSecrets
            )
            results.append(result)
        }

        return .structured(.object([
            "operation": .string(operation),
            "statements": .array(statements.map { .string($0) }),
            "results": .array(results)
        ]))
    }
}

public struct TransactionControlTool: MCPToolImplementation {
    public static let name = "transaction_control"
    public static let title: String? = String(localized: "Transaction Control")
    public static let description = String(
        localized: """
        Begin, commit, or roll back a transaction on the connection's shared session. The transaction \
        stays open across calls until committed or rolled back, and it is the same session the user's \
        own tabs run on, so leave nothing open. Needs tools:write.
        """
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsWrite]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Transaction Control"),
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: true
    )

    static let actions = ["begin", "commit", "rollback"]

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.connectionId,
            "action": MCPToolSchema.string(
                String(localized: "What to do with the transaction"),
                enumValues: actions
            ),
            "database": MCPToolSchema.database,
            "schema": MCPToolSchema.schema
        ],
        required: ["connection_id", "action"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "status": MCPToolSchema.string(
                String(localized: "The action that completed"),
                enumValues: actions
            ),
            "connection_id": MCPToolSchema.string(String(localized: "Connection the transaction runs on"))
        ],
        required: ["status", "connection_id"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(
            arguments,
            allowed: MCPScopeArguments.keys.union(["action"])
        )
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        let action = try MCPArgumentDecoder.requireEnum(arguments, key: "action", allowed: Self.actions)
        let meta = try await ToolConnectionMetadata.resolve(connectionId: connectionId)

        try await MCPStatementGate.authorize(
            sql: action.uppercased(),
            meta: meta,
            allowsDestructive: false,
            operationLabel: String(
                format: String(localized: "transaction %@"),
                action
            ),
            context: context,
            services: services
        )

        let scope = try await MCPScopeArguments.resolve(
            arguments,
            connectionId: connectionId,
            services: services
        )
        do {
            let payload = try await services.connectionBridge.transactionControl(
                scope: scope,
                action: action
            )
            return .structured(payload)
        } catch {
            throw ToolQueryExecutor.translate(error, secrets: meta.redactionSecrets)
        }
    }
}
