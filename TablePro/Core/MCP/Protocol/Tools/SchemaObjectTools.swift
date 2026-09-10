import Foundation

public struct ListIndexesTool: MCPToolImplementation {
    public static let name = "list_indexes"
    public static let title: String? = String(localized: "List Indexes")
    public static let description = String(
        localized: """
        List indexes for one table, or for every table in the schema when 'table' is omitted. \
        Use it to see what a query can actually use before proposing one.
        """
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "List Indexes"),
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.connectionId,
            "table": MCPToolSchema.string(String(localized: "Table name. Omit to cover the whole schema.")),
            "database": MCPToolSchema.database,
            "schema": MCPToolSchema.schema
        ],
        required: ["connection_id"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "database": MCPToolSchema.string(String(localized: "Database the listing covers")),
            "schema": MCPToolSchema.nullableString(String(localized: "Schema the listing covers")),
            "tables": MCPToolSchema.array(
                String(localized: "Tables that carry at least one index"),
                of: MCPToolSchema.object(
                    properties: [
                        "table": MCPToolSchema.string(String(localized: "Table name")),
                        "indexes": MCPToolSchema.array(
                            String(localized: "Indexes on the table"),
                            of: MCPToolSchema.indexDefinition
                        )
                    ],
                    required: ["table", "indexes"]
                )
            )
        ],
        required: ["database", "tables"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: MCPScopeArguments.keys.union(["table"]))
        let table = try MCPArgumentDecoder.optionalString(arguments, key: "table")
        let scope = try await MCPScopeArguments.resolve(arguments, services: services)
        let payload = try await services.connectionBridge.listIndexes(scope: scope, table: table)
        return .structured(payload)
    }
}

public struct ListForeignKeysTool: MCPToolImplementation {
    public static let name = "list_foreign_keys"
    public static let title: String? = String(localized: "List Foreign Keys")
    public static let description = String(
        localized: """
        List foreign keys for one table, or for the whole schema when 'table' is omitted, so joins can \
        be written from the real relationships rather than guessed from column names.
        """
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "List Foreign Keys"),
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.connectionId,
            "table": MCPToolSchema.string(String(localized: "Table name. Omit to cover the whole schema.")),
            "database": MCPToolSchema.database,
            "schema": MCPToolSchema.schema
        ],
        required: ["connection_id"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "database": MCPToolSchema.string(String(localized: "Database the listing covers")),
            "schema": MCPToolSchema.nullableString(String(localized: "Schema the listing covers")),
            "tables": MCPToolSchema.array(
                String(localized: "Tables that carry at least one foreign key"),
                of: MCPToolSchema.object(
                    properties: [
                        "table": MCPToolSchema.string(String(localized: "Referencing table")),
                        "foreign_keys": MCPToolSchema.array(
                            String(localized: "Foreign keys the table declares"),
                            of: MCPToolSchema.foreignKeyDefinition
                        )
                    ],
                    required: ["table", "foreign_keys"]
                )
            )
        ],
        required: ["database", "tables"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: MCPScopeArguments.keys.union(["table"]))
        let table = try MCPArgumentDecoder.optionalString(arguments, key: "table")
        let scope = try await MCPScopeArguments.resolve(arguments, services: services)
        let payload = try await services.connectionBridge.listForeignKeys(scope: scope, table: table)
        return .structured(payload)
    }
}

public struct ListTriggersTool: MCPToolImplementation {
    public static let name = "list_triggers"
    public static let title: String? = String(localized: "List Triggers")
    public static let description = String(
        localized: "List the triggers attached to one table, with their timing, event, and body."
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "List Triggers"),
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.connectionId,
            "table": MCPToolSchema.table,
            "database": MCPToolSchema.database,
            "schema": MCPToolSchema.schema
        ],
        required: ["connection_id"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "table": MCPToolSchema.string(String(localized: "Table the triggers belong to, when one was named")),
            "triggers": MCPToolSchema.array(
                String(localized: "Triggers, sorted by table then name"),
                of: MCPToolSchema.object(
                    properties: [
                        "name": MCPToolSchema.string(String(localized: "Trigger name")),
                        "table": MCPToolSchema.string(String(localized: "Table the trigger fires for")),
                        "schema": MCPToolSchema.string(String(localized: "Schema the trigger belongs to")),
                        "timing": MCPToolSchema.string(String(localized: "BEFORE, AFTER, or INSTEAD OF")),
                        "event": MCPToolSchema.string(String(localized: "INSERT, UPDATE, or DELETE")),
                        "orientation": MCPToolSchema.string(String(localized: "ROW or STATEMENT")),
                        "statement": MCPToolSchema.string(String(localized: "Trigger body")),
                        "definition": MCPToolSchema.string(String(localized: "Full CREATE TRIGGER statement")),
                        "is_enabled": MCPToolSchema.boolean(String(localized: "Whether the trigger is enabled"))
                    ],
                    required: ["name", "timing", "event", "statement"]
                )
            )
        ],
        required: ["triggers"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: MCPScopeArguments.keys.union(["table"]))
        let table = try MCPArgumentDecoder.optionalString(arguments, key: "table")
        let scope = try await MCPScopeArguments.resolve(arguments, services: services)
        let payload = try await services.connectionBridge.listTriggers(scope: scope, table: table)
        return .structured(payload)
    }
}

public struct GetViewDefinitionTool: MCPToolImplementation {
    public static let name = "get_view_definition"
    public static let title: String? = String(localized: "Get View Definition")
    public static let description = String(localized: "Return the SELECT statement a view is defined by.")
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Get View Definition"),
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.connectionId,
            "view": MCPToolSchema.string(String(localized: "View name")),
            "database": MCPToolSchema.database,
            "schema": MCPToolSchema.schema
        ],
        required: ["connection_id", "view"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "view": MCPToolSchema.string(String(localized: "View that was read")),
            "schema": MCPToolSchema.nullableString(String(localized: "Schema the view lives in")),
            "definition": MCPToolSchema.string(String(localized: "View body"))
        ],
        required: ["view", "definition"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: MCPScopeArguments.keys.union(["view"]))
        let view = try MCPArgumentDecoder.requireNonEmptyString(arguments, key: "view")
        let scope = try await MCPScopeArguments.resolve(arguments, services: services)
        let payload = try await services.connectionBridge.getViewDefinition(scope: scope, view: view)
        return .structured(payload)
    }
}

public struct ListRoutinesTool: MCPToolImplementation {
    public static let name = "list_routines"
    public static let title: String? = String(localized: "List Routines")
    public static let description = String(
        localized: "List stored procedures and user-defined functions in a schema."
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "List Routines"),
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.connectionId,
            "kind": MCPToolSchema.string(
                String(localized: "Restrict to one kind. Omit for both."),
                enumValues: ["procedure", "function"]
            ),
            "database": MCPToolSchema.database,
            "schema": MCPToolSchema.schema
        ],
        required: ["connection_id"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "routines": MCPToolSchema.array(
                String(localized: "Routines, sorted by qualified name"),
                of: MCPToolSchema.object(
                    properties: [
                        "name": MCPToolSchema.string(String(localized: "Routine name")),
                        "kind": MCPToolSchema.string(String(localized: "PROCEDURE or FUNCTION")),
                        "schema": MCPToolSchema.string(String(localized: "Schema the routine lives in")),
                        "qualified_name": MCPToolSchema.string(String(localized: "Schema-qualified name")),
                        "signature": MCPToolSchema.string(
                            String(localized: "Argument list the engine reports, such as (date), when it reports one")
                        ),
                        "return_type": MCPToolSchema.string(
                            String(localized: "What a function returns, absent for a procedure")
                        ),
                        "language": MCPToolSchema.string(String(localized: "Language the routine is written in"))
                    ],
                    required: ["name", "kind", "qualified_name"]
                )
            )
        ],
        required: ["routines"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: MCPScopeArguments.keys.union(["kind"]))
        let kind = try MCPArgumentDecoder.optionalEnum(
            arguments,
            key: "kind",
            allowed: ["procedure", "function"]
        )
        let scope = try await MCPScopeArguments.resolve(arguments, services: services)
        let payload = try await services.connectionBridge.listRoutines(scope: scope, kind: kind)
        return .structured(payload)
    }
}

public struct ListUserDefinedTypesTool: MCPToolImplementation {
    public static let name = "list_types"
    public static let title: String? = String(localized: "List Types")
    public static let description = String(
        localized: "List the user-defined types in a schema: enums, composites, domains and ranges."
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "List Types"),
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    public static let kinds = UserDefinedTypeInfo.Kind.allCases.filter { $0 != .other }.map(\.rawValue)

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.connectionId,
            "kind": MCPToolSchema.string(
                String(localized: "Restrict to one kind. Omit for every kind."),
                enumValues: kinds
            ),
            "database": MCPToolSchema.database,
            "schema": MCPToolSchema.schema
        ],
        required: ["connection_id"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "types": MCPToolSchema.array(
                String(localized: "Types, sorted by qualified name"),
                of: MCPToolSchema.object(
                    properties: [
                        "name": MCPToolSchema.string(String(localized: "Type name")),
                        "kind": MCPToolSchema.string(String(localized: "enum, composite, domain or range")),
                        "schema": MCPToolSchema.string(String(localized: "Schema the type lives in")),
                        "qualified_name": MCPToolSchema.string(String(localized: "Schema-qualified name")),
                        "labels": MCPToolSchema.array(
                            String(localized: "An enum's labels in declaration order"),
                            of: MCPToolSchema.string(String(localized: "Label"))
                        ),
                        "fields": MCPToolSchema.array(
                            String(localized: "A composite's fields in declaration order"),
                            of: MCPToolSchema.object(
                                properties: [
                                    "name": MCPToolSchema.string(String(localized: "Field name")),
                                    "type": MCPToolSchema.string(String(localized: "Field type"))
                                ],
                                required: ["name", "type"]
                            )
                        ),
                        "base_type": MCPToolSchema.string(
                            String(localized: "A domain's base type, or a range's subtype")
                        ),
                        "definition": MCPToolSchema.string(String(localized: "The CREATE statement"))
                    ],
                    required: ["name", "kind", "qualified_name"]
                )
            )
        ],
        required: ["types"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: MCPScopeArguments.keys.union(["kind"]))
        let kind = try MCPArgumentDecoder.optionalEnum(arguments, key: "kind", allowed: Self.kinds)
        let scope = try await MCPScopeArguments.resolve(arguments, services: services)
        let payload = try await services.connectionBridge.listUserDefinedTypes(scope: scope, kind: kind)
        return .structured(payload)
    }
}

public struct ListPartitionsTool: MCPToolImplementation {
    public static let name = "list_partitions"
    public static let title: String? = String(localized: "List Partitions")
    public static let description = String(
        localized: "List the direct partitions of a partitioned table. Empty for engines without partitioning."
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "List Partitions"),
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.connectionId,
            "table": MCPToolSchema.table,
            "database": MCPToolSchema.database,
            "schema": MCPToolSchema.schema
        ],
        required: ["connection_id", "table"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "table": MCPToolSchema.string(String(localized: "Parent table")),
            "partitions": MCPToolSchema.array(
                String(localized: "Direct partitions"),
                of: MCPToolSchema.tableSummary
            )
        ],
        required: ["table", "partitions"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: MCPScopeArguments.keys.union(["table"]))
        let table = try MCPArgumentDecoder.requireNonEmptyString(arguments, key: "table")
        let scope = try await MCPScopeArguments.resolve(arguments, services: services)
        let payload = try await services.connectionBridge.listPartitions(scope: scope, table: table)
        return .structured(payload)
    }
}

public struct SearchSchemaTool: MCPToolImplementation {
    public static let name = "search_schema"
    public static let title: String? = String(localized: "Search Schema")
    public static let description = String(
        localized: """
        Find tables and columns whose name contains a substring, so a column can be located without \
        describing every table.
        """
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Search Schema"),
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.connectionId,
            "term": MCPToolSchema.string(String(localized: "Case-insensitive substring to look for")),
            "limit": MCPToolSchema.integer(
                String(localized: "Maximum matches to return (1-500, default 50)"),
                minimum: 1,
                maximum: 500
            ),
            "database": MCPToolSchema.database,
            "schema": MCPToolSchema.schema
        ],
        required: ["connection_id", "term"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "term": MCPToolSchema.string(String(localized: "Term that was searched")),
            "matches": MCPToolSchema.array(
                String(localized: "Matching tables first, then matching columns"),
                of: MCPToolSchema.object(
                    properties: [
                        "kind": MCPToolSchema.string(
                            String(localized: "What matched"),
                            enumValues: ["table", "column"]
                        ),
                        "name": MCPToolSchema.string(String(localized: "Matched name")),
                        "table": MCPToolSchema.string(String(localized: "Owning table, for a column match")),
                        "schema": MCPToolSchema.nullableString(String(localized: "Schema, for a table match")),
                        "object_type": MCPToolSchema.string(String(localized: "Object type, for a table match")),
                        "data_type": MCPToolSchema.string(String(localized: "Column type, for a column match"))
                    ],
                    required: ["kind", "name"]
                )
            ),
            "is_truncated": MCPToolSchema.boolean(String(localized: "Whether the limit clipped the matches"))
        ],
        required: ["term", "matches", "is_truncated"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(
            arguments,
            allowed: MCPScopeArguments.keys.union(["term", "limit"])
        )
        let term = try MCPArgumentDecoder.requireNonEmptyString(arguments, key: "term")
        let limit = try MCPArgumentDecoder.optionalInt(arguments, key: "limit", range: 1...500) ?? 50
        let scope = try await MCPScopeArguments.resolve(arguments, services: services)
        let payload = try await services.connectionBridge.searchSchema(
            scope: scope,
            term: term,
            limit: limit
        )
        return .structured(payload)
    }
}

public struct GetTableStatisticsTool: MCPToolImplementation {
    public static let name = "get_table_statistics"
    public static let title: String? = String(localized: "Get Table Statistics")
    public static let description = String(
        localized: "Return size, engine, collation, and timestamps the engine records for one table."
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Get Table Statistics"),
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.connectionId,
            "table": MCPToolSchema.table,
            "database": MCPToolSchema.database,
            "schema": MCPToolSchema.schema
        ],
        required: ["connection_id", "table"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "table": MCPToolSchema.string(String(localized: "Table the statistics describe")),
            "data_size_bytes": MCPToolSchema.integer(String(localized: "Row data size")),
            "index_size_bytes": MCPToolSchema.integer(String(localized: "Index size")),
            "total_size_bytes": MCPToolSchema.integer(String(localized: "Total size")),
            "average_row_length": MCPToolSchema.integer(String(localized: "Average row length")),
            "row_count": MCPToolSchema.integer(String(localized: "Row count the engine reports")),
            "comment": MCPToolSchema.string(String(localized: "Table comment")),
            "engine": MCPToolSchema.string(String(localized: "Storage engine")),
            "collation": MCPToolSchema.string(String(localized: "Default collation")),
            "created_at": MCPToolSchema.string(String(localized: "ISO 8601 creation time")),
            "updated_at": MCPToolSchema.string(String(localized: "ISO 8601 last change time"))
        ],
        required: ["table"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: MCPScopeArguments.keys.union(["table"]))
        let table = try MCPArgumentDecoder.requireNonEmptyString(arguments, key: "table")
        let scope = try await MCPScopeArguments.resolve(arguments, services: services)
        let payload = try await services.connectionBridge.tableMetadata(scope: scope, table: table)
        return .structured(payload)
    }
}

public struct GetDatabaseStatisticsTool: MCPToolImplementation {
    public static let name = "get_database_statistics"
    public static let title: String? = String(localized: "Get Database Statistics")
    public static let description = String(
        localized: "Return table counts and sizes for one database, or for every database when 'database' is omitted."
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Get Database Statistics"),
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.connectionId,
            "database": MCPToolSchema.string(String(localized: "Database to report on. Omit for all."))
        ],
        required: ["connection_id"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "databases": MCPToolSchema.array(
                String(localized: "Databases, sorted by name"),
                of: MCPToolSchema.object(
                    properties: [
                        "name": MCPToolSchema.string(String(localized: "Database name")),
                        "table_count": MCPToolSchema.integer(String(localized: "Number of tables")),
                        "size_bytes": MCPToolSchema.integer(String(localized: "Total size in bytes")),
                        "is_system_database": MCPToolSchema.boolean(
                            String(localized: "Whether the engine owns this database")
                        )
                    ],
                    required: ["name", "is_system_database"]
                )
            )
        ],
        required: ["databases"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: ["connection_id", "database"])
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        let database = try MCPArgumentDecoder.optionalString(arguments, key: "database")
        let payload = try await services.connectionBridge.databaseMetadata(
            connectionId: connectionId,
            database: database
        )
        return .structured(payload)
    }
}
