import Foundation

public struct CreateDatabaseTool: MCPToolImplementation {
    public static let name = "create_database"
    public static let title: String? = String(localized: "Create Database")
    public static let description = String(
        localized: """
        Create a database using the engine's own form options. Call describe_create_database_options \
        first to see which options this engine takes. Needs tools:write and the user's approval.
        """
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsWrite]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Create Database"),
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: true
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.connectionId,
            "name": MCPToolSchema.string(String(localized: "Name for the new database")),
            "options": MCPToolSchema.object(properties: [:], required: [], allowsAdditional: true)
        ],
        required: ["connection_id", "name"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "status": MCPToolSchema.string(String(localized: "Always 'created' on success")),
            "database": MCPToolSchema.string(String(localized: "Database that was created"))
        ],
        required: ["status", "database"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: ["connection_id", "name", "options"])
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        let name = try MCPArgumentDecoder.requireNonEmptyString(arguments, key: "name")
        let options = try MCPLifecycleArguments.stringMap(arguments, key: "options")
        let meta = try await ToolConnectionMetadata.resolve(connectionId: connectionId)

        try await MCPStatementGate.authorize(
            sql: "CREATE DATABASE \(name)",
            meta: meta,
            allowsDestructive: false,
            operationLabel: String(localized: "creating a database"),
            context: context,
            services: services
        )

        do {
            let payload = try await services.connectionBridge.createDatabase(
                connectionId: connectionId,
                name: name,
                options: options
            )
            return .structured(payload)
        } catch {
            throw ToolQueryExecutor.translate(error, secrets: meta.redactionSecrets)
        }
    }
}

public struct DescribeCreateDatabaseOptionsTool: MCPToolImplementation {
    public static let name = "describe_create_database_options"
    public static let title: String? = String(localized: "Describe Create Database Options")
    public static let description = String(
        localized: "List the options create_database accepts on this engine, with their allowed values."
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Describe Create Database Options"),
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
            "is_supported": MCPToolSchema.boolean(String(localized: "Whether this engine can create databases")),
            "fields": MCPToolSchema.array(
                String(localized: "Options the engine offers"),
                of: MCPToolSchema.object(
                    properties: [
                        "key": MCPToolSchema.string(String(localized: "Option key to pass in 'options'")),
                        "label": MCPToolSchema.string(String(localized: "Human label")),
                        "default_value": MCPToolSchema.nullableString(String(localized: "Default value")),
                        "options": MCPToolSchema.array(
                            String(localized: "Allowed values"),
                            of: MCPToolSchema.stringItem
                        )
                    ],
                    required: ["key", "label", "options"]
                )
            )
        ],
        required: ["is_supported", "fields"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: ["connection_id"])
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        let payload = try await services.connectionBridge.createDatabaseFormSpec(connectionId: connectionId)
        return .structured(payload)
    }
}

public struct DropDatabaseObjectTool: MCPToolImplementation {
    public static let name = "drop_database_object"
    public static let title: String? = String(localized: "Drop Database or Schema")
    public static let description = String(
        localized: """
        Drop a whole database or a whole schema. This deletes everything inside it and cannot be undone, \
        so the user approves it first. Needs tools:write on a connection left writable for external clients.
        """
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsWrite]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Drop Database or Schema"),
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true
    )

    static let kinds = ["database", "schema"]

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.connectionId,
            "kind": MCPToolSchema.string(String(localized: "What to drop"), enumValues: kinds),
            "name": MCPToolSchema.string(String(localized: "Name of the database or schema"))
        ],
        required: ["connection_id", "kind", "name"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "status": MCPToolSchema.string(String(localized: "Always 'dropped' on success")),
            "database": MCPToolSchema.string(String(localized: "Database that was dropped")),
            "schema": MCPToolSchema.string(String(localized: "Schema that was dropped"))
        ],
        required: ["status"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: ["connection_id", "kind", "name"])
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        let kind = try MCPArgumentDecoder.requireEnum(arguments, key: "kind", allowed: Self.kinds)
        let name = try MCPArgumentDecoder.requireNonEmptyString(arguments, key: "name")
        let meta = try await ToolConnectionMetadata.resolve(connectionId: connectionId)

        try await MCPStatementGate.authorize(
            sql: "DROP \(kind.uppercased()) \(name)",
            meta: meta,
            allowsDestructive: true,
            operationLabel: String(
                format: String(localized: "dropping %@ '%@'"),
                kind,
                name
            ),
            context: context,
            services: services
        )

        do {
            let payload = kind == "database"
                ? try await services.connectionBridge.dropDatabase(connectionId: connectionId, name: name)
                : try await services.connectionBridge.dropSchema(connectionId: connectionId, name: name)
            return .structured(payload)
        } catch {
            throw ToolQueryExecutor.translate(error, secrets: meta.redactionSecrets)
        }
    }
}

enum MCPLifecycleArguments {
    static func stringMap(_ arguments: JsonValue, key: String) throws -> [String: String] {
        guard let raw = arguments[key], !raw.isNull else { return [:] }
        guard let fields = raw.objectValue else {
            throw MCPProtocolError.invalidParams(detail: "Parameter '\(key)' must be an object")
        }
        var map: [String: String] = [:]
        for (name, value) in fields {
            guard let text = value.stringValue else {
                throw MCPProtocolError.invalidParams(detail: "Every value in '\(key)' must be a string")
            }
            map[name] = text
        }
        return map
    }
}
