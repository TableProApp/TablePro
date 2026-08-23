import Foundation

public struct DescribeTableTool: MCPToolImplementation {
    public static let name = "describe_table"
    public static let title: String? = String(localized: "Describe Table")
    public static let description = String(
        localized: """
        Describe one table: columns, indexes, foreign keys, DDL, and an approximate row count. \
        Every part is read against the same database and schema.
        """
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Describe Table"),
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
            "table": MCPToolSchema.string(String(localized: "Table that was described")),
            "database": MCPToolSchema.string(String(localized: "Database the table lives in")),
            "schema": MCPToolSchema.nullableString(String(localized: "Schema the table lives in")),
            "columns": MCPToolSchema.array(
                String(localized: "Columns in declaration order"),
                of: MCPToolSchema.columnDefinition
            ),
            "indexes": MCPToolSchema.array(
                String(localized: "Indexes on the table"),
                of: MCPToolSchema.indexDefinition
            ),
            "foreign_keys": MCPToolSchema.array(
                String(localized: "Outgoing foreign keys"),
                of: MCPToolSchema.foreignKeyDefinition
            ),
            "ddl": MCPToolSchema.string(String(localized: "CREATE statement, when the engine can produce one")),
            "approximate_row_count": MCPToolSchema.integer(String(localized: "Estimated row count"))
        ],
        required: ["table", "database", "columns", "indexes", "foreign_keys"]
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
        let payload = try await services.connectionBridge.describeTable(scope: scope, table: table)
        return .structured(payload)
    }
}
