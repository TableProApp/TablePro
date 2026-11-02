import Foundation
import TableProMCP
import TableProSQLGrammar

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
                String(localized: "Operations, sorted by name"),
                of: MCPToolSchema.object(
                    properties: [
                        "name": MCPToolSchema.string(String(localized: "Operation name to pass to run_maintenance")),
                        "applies_to": MCPToolSchema.array(
                            String(
                                localized: """
                                Object kinds this operation may name, as list_tables reports them. \
                                Empty when it acts on the whole database only.
                                """
                            ),
                            of: MCPToolSchema.stringItem
                        ),
                        "scope": MCPToolSchema.string(
                            String(localized: "Whether the statement names an object, the database, or either"),
                            enumValues: ["object", "database", "objectOrDatabase"]
                        ),
                        "options": MCPToolSchema.array(
                            String(localized: "Options this operation reads, by key"),
                            of: MCPToolSchema.object(
                                properties: [
                                    "key": MCPToolSchema.string(String(localized: "Key to send in 'options'")),
                                    "label": MCPToolSchema.string(String(localized: "What the option does")),
                                    "default": MCPToolSchema.string(String(localized: "Value used when omitted")),
                                    "choices": MCPToolSchema.array(
                                        String(localized: "Accepted values, or null for a true/false flag"),
                                        of: MCPToolSchema.stringItem
                                    )
                                ],
                                required: ["key", "label", "default"]
                            )
                        )
                    ],
                    required: ["name", "applies_to", "scope", "options"]
                )
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
    static let rowLimit = 1_000
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
        /// Resolved before the statements, because the schema it carries is what qualifies the target
        /// and its kind is what says whether the operation applies at all.
        let scope = try await MCPScopeArguments.resolve(
            arguments,
            connectionId: connectionId,
            services: services
        )
        let statements: [String]
        do {
            statements = try await services.connectionBridge.maintenanceStatements(
                scope: scope,
                operation: operation,
                table: table,
                options: options
            )
        } catch let error as DatabaseAccessError {
            throw MCPToolExecutionError.from(error, secrets: meta.redactionSecrets)
        }

        let settings = await services.settingsProvider()
        let timeoutSeconds = try MCPLimitResolver.resolveTimeoutSeconds(arguments, settings: settings)

        let classifications = try statements.map { statement in
            try MCPStatementGate.classify(sql: statement, meta: meta, allowsDestructive: true, context: context)
        }

        var results: [JsonValue] = []
        for (statement, classification) in zip(statements, classifications) {
            let planned: OperationStatement
            do {
                planned = try await services.connectionBridge.plannedStatement(
                    scope: scope,
                    query: statement,
                    maxRows: Self.rowLimit
                )
            } catch {
                throw ToolQueryExecutor.translate(error, secrets: meta.redactionSecrets)
            }
            let approved = try await MCPStatementGate.approve(
                [planned],
                kind: OperationKind.from(classification.tier),
                scope: scope,
                meta: meta,
                allowsDestructive: true,
                forcesUserConsent: true,
                operationLabel: String(
                    format: String(localized: "maintenance operation %@"),
                    operation
                ),
                context: context,
                services: services
            )
            let result = try await ToolQueryExecutor.executeAndLog(
                services: services,
                operation: approved,
                maxRows: Self.rowLimit,
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

        // No statement to grade: BEGIN means JavaScript to a MongoDB classifier, so the kind decides.
        try MCPStatementGate.classify(kind: .writeQuery, meta: meta, allowsDestructive: false, context: context)

        let scope = try await MCPScopeArguments.resolve(
            arguments,
            connectionId: connectionId,
            services: services
        )
        let operation = try await MCPStatementGate.approve(
            [],
            kind: .writeQuery,
            scope: scope,
            meta: meta,
            allowsDestructive: false,
            operationLabel: String(
                format: String(localized: "transaction %@"),
                action
            ),
            context: context,
            services: services
        )
        do {
            let payload = try await services.connectionBridge.transactionControl(operation, action: action)
            return .structured(payload)
        } catch {
            throw ToolQueryExecutor.translate(error, secrets: meta.redactionSecrets)
        }
    }
}
