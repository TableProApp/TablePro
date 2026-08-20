import Foundation

public struct ServerDashboardTool: MCPToolImplementation {
    public static let name = "get_server_dashboard"
    public static let title: String? = String(localized: "Get Server Dashboard")
    public static let description = String(
        localized: """
        Read the live server panels TablePro shows: active sessions, server metrics, and slow queries. \
        Available on PostgreSQL, MySQL, SQL Server, ClickHouse, DuckDB, and SQLite.
        """
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Get Server Dashboard"),
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: false
    )

    static let panelNames = ["sessions", "metrics", "slow_queries"]

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.connectionId,
            "panels": MCPToolSchema.array(
                String(localized: "Panels to read. Omit for all."),
                of: .object(["type": .string("string"), "enum": .array(panelNames.map { .string($0) })])
            )
        ],
        required: ["connection_id"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "sessions": MCPToolSchema.array(
                String(localized: "Sessions the server reports"),
                of: MCPToolSchema.object(
                    properties: [
                        "id": MCPToolSchema.string(String(localized: "Process id, accepted by stop_server_session")),
                        "user": MCPToolSchema.string(String(localized: "Session user")),
                        "database": MCPToolSchema.string(String(localized: "Database the session is on")),
                        "state": MCPToolSchema.string(String(localized: "Session state")),
                        "duration_seconds": MCPToolSchema.integer(String(localized: "How long it has run")),
                        "query": MCPToolSchema.string(String(localized: "Current statement")),
                        "can_kill": MCPToolSchema.boolean(String(localized: "Whether it can be killed")),
                        "can_cancel": MCPToolSchema.boolean(String(localized: "Whether its query can be cancelled"))
                    ],
                    required: ["id", "user", "database", "state", "duration_seconds", "query"]
                )
            ),
            "metrics": MCPToolSchema.array(
                String(localized: "Server metrics"),
                of: MCPToolSchema.object(
                    properties: [
                        "id": MCPToolSchema.string(String(localized: "Metric id")),
                        "label": MCPToolSchema.string(String(localized: "Metric label")),
                        "value": MCPToolSchema.string(String(localized: "Metric value")),
                        "unit": MCPToolSchema.string(String(localized: "Metric unit"))
                    ],
                    required: ["id", "label", "value", "unit"]
                )
            ),
            "slow_queries": MCPToolSchema.array(
                String(localized: "Slow queries the server recorded"),
                of: MCPToolSchema.object(
                    properties: [
                        "duration": MCPToolSchema.string(String(localized: "Formatted duration")),
                        "query": MCPToolSchema.string(String(localized: "Statement text")),
                        "user": MCPToolSchema.string(String(localized: "User that ran it")),
                        "database": MCPToolSchema.string(String(localized: "Database it ran on"))
                    ],
                    required: ["duration", "query", "user", "database"]
                )
            )
        ]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: ["connection_id", "panels"])
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        let requested = try MCPArgumentDecoder.optionalStringArray(arguments, key: "panels")
        if let requested {
            let unknown = requested.filter { !Self.panelNames.contains($0) }.sorted()
            guard unknown.isEmpty else {
                throw MCPToolExecutionError.invalidArgument(
                    String(
                        format: String(localized: "Unknown panel(s): %@"),
                        unknown.joined(separator: ", ")
                    )
                )
            }
        }
        let panels = Set(requested ?? Self.panelNames)
        let payload = try await services.connectionBridge.serverDashboard(
            connectionId: connectionId,
            panels: panels
        )
        return .structured(payload)
    }
}

public struct StopServerSessionTool: MCPToolImplementation {
    public static let name = "stop_server_session"
    public static let title: String? = String(localized: "Stop Server Session")
    public static let description = String(
        localized: """
        Cancel the running query on a server session, or kill the session outright. Takes a process id \
        from get_server_dashboard. Needs tools:write and the user's approval.
        """
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsWrite]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Stop Server Session"),
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.connectionId,
            "process_id": MCPToolSchema.string(String(localized: "Process id from get_server_dashboard")),
            "mode": MCPToolSchema.string(
                String(localized: "cancel stops the query, kill ends the session (default cancel)"),
                enumValues: ["cancel", "kill"]
            )
        ],
        required: ["connection_id", "process_id"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.resultSet

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: ["connection_id", "process_id", "mode"])
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        let processId = try MCPArgumentDecoder.requireNonEmptyString(arguments, key: "process_id")
        let mode = try MCPArgumentDecoder.optionalEnum(
            arguments,
            key: "mode",
            allowed: ["cancel", "kill"]
        ) ?? "cancel"

        let meta = try await ToolConnectionMetadata.resolve(connectionId: connectionId)
        let statement: String
        do {
            statement = try await services.connectionBridge.sessionControlStatement(
                connectionId: connectionId,
                processId: processId,
                cancelOnly: mode == "cancel"
            )
        } catch let error as MCPDataLayerError {
            throw MCPToolExecutionError.from(error, secrets: meta.redactionSecrets)
        }

        try await MCPStatementGate.authorize(
            sql: statement,
            meta: meta,
            allowsDestructive: true,
            forcesUserConsent: true,
            operationLabel: mode == "cancel"
                ? String(localized: "cancelling a server query")
                : String(localized: "killing a server session"),
            context: context,
            services: services
        )

        let settings = await services.settingsProvider()
        let scope = try await services.connectionBridge.resolveScope(
            connectionId: connectionId,
            database: nil,
            schema: nil
        )
        let result = try await ToolQueryExecutor.executeAndLog(
            services: services,
            query: statement,
            scope: scope,
            maxRows: 1,
            timeoutSeconds: settings.validatedQueryTimeoutSeconds,
            context: context,
            secrets: meta.redactionSecrets
        )
        return .structured(result)
    }
}

public struct ListPrincipalsTool: MCPToolImplementation {
    public static let name = "list_principals"
    public static let title: String? = String(localized: "List Users and Roles")
    public static let description = String(
        localized: "List the users and roles defined on the server, with their attributes and role memberships."
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "List Users and Roles"),
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
            "principals": MCPToolSchema.array(
                String(localized: "Users and roles, sorted by name"),
                of: MCPToolSchema.object(
                    properties: [
                        "name": MCPToolSchema.string(String(localized: "Principal name")),
                        "host": MCPToolSchema.string(String(localized: "Host scope, where the engine has one")),
                        "is_role": MCPToolSchema.boolean(String(localized: "Whether this is a role")),
                        "can_login": MCPToolSchema.boolean(String(localized: "Whether it can log in")),
                        "member_of": MCPToolSchema.array(
                            String(localized: "Roles it belongs to"),
                            of: MCPToolSchema.stringItem
                        ),
                        "connection_limit": MCPToolSchema.integer(String(localized: "Connection limit")),
                        "comment": MCPToolSchema.string(String(localized: "Comment")),
                        "attributes": MCPToolSchema.array(
                            String(localized: "Engine-specific attribute flags"),
                            of: MCPToolSchema.object(
                                properties: [
                                    "key": MCPToolSchema.string(String(localized: "Attribute key")),
                                    "label": MCPToolSchema.string(String(localized: "Attribute label")),
                                    "is_enabled": MCPToolSchema.boolean(String(localized: "Whether it is set"))
                                ],
                                required: ["key", "label", "is_enabled"]
                            )
                        )
                    ],
                    required: ["name", "is_role", "can_login", "member_of", "attributes"]
                )
            )
        ],
        required: ["principals"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: ["connection_id"])
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        let payload = try await services.connectionBridge.listPrincipals(connectionId: connectionId)
        return .structured(payload)
    }
}

public struct ListGrantsTool: MCPToolImplementation {
    public static let name = "list_grants"
    public static let title: String? = String(localized: "List Grants")
    public static let description = String(
        localized: "List the privileges granted to one user or role, with the scope each applies to."
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "List Grants"),
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.connectionId,
            "principal": MCPToolSchema.string(String(localized: "User or role name")),
            "host": MCPToolSchema.string(String(localized: "Host scope, for engines that use one"))
        ],
        required: ["connection_id", "principal"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "principal": MCPToolSchema.string(String(localized: "Principal the grants belong to")),
            "grants": MCPToolSchema.array(
                String(localized: "Grants, sorted by privilege then scope"),
                of: MCPToolSchema.object(
                    properties: [
                        "privilege": MCPToolSchema.string(String(localized: "Privilege name")),
                        "scope": MCPToolSchema.string(String(localized: "Dotted scope path, '*' for server")),
                        "is_grantable": MCPToolSchema.boolean(String(localized: "WITH GRANT OPTION"))
                    ],
                    required: ["privilege", "scope", "is_grantable"]
                )
            )
        ],
        required: ["principal", "grants"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: ["connection_id", "principal", "host"])
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        let principal = try MCPArgumentDecoder.requireNonEmptyString(arguments, key: "principal")
        let host = try MCPArgumentDecoder.optionalString(arguments, key: "host")
        let payload = try await services.connectionBridge.listGrants(
            connectionId: connectionId,
            principal: principal,
            host: host
        )
        return .structured(payload)
    }
}

public struct ListSessionContextsTool: MCPToolImplementation {
    public static let name = "list_session_contexts"
    public static let title: String? = String(localized: "List Session Contexts")
    public static let description = String(
        localized: """
        List the session-level contexts this engine exposes, such as a warehouse or a role, with the \
        value the session currently holds.
        """
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "List Session Contexts"),
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
            "is_supported": MCPToolSchema.boolean(String(localized: "Whether this engine has session contexts")),
            "contexts": MCPToolSchema.array(
                String(localized: "Session contexts"),
                of: MCPToolSchema.object(
                    properties: [
                        "id": MCPToolSchema.string(String(localized: "Context id")),
                        "label": MCPToolSchema.string(String(localized: "Context label")),
                        "value": MCPToolSchema.string(String(localized: "Current value")),
                        "options": MCPToolSchema.array(
                            String(localized: "Values the context accepts"),
                            of: MCPToolSchema.stringItem
                        )
                    ],
                    required: ["id", "label", "value", "options"]
                )
            )
        ],
        required: ["is_supported", "contexts"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: ["connection_id"])
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        let payload = try await services.connectionBridge.sessionContexts(connectionId: connectionId)
        return .structured(payload)
    }
}
