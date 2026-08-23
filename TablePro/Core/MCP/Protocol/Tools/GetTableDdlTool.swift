import Foundation

public struct GetTableDdlTool: MCPToolImplementation {
    public static let name = "get_table_ddl"
    public static let title: String? = String(localized: "Get Table DDL")
    public static let description = String(localized: "Return the CREATE statement for one table or view.")
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Get Table DDL"),
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
            "table": MCPToolSchema.string(String(localized: "Table the DDL describes")),
            "schema": MCPToolSchema.nullableString(String(localized: "Schema the table lives in")),
            "ddl": MCPToolSchema.string(String(localized: "CREATE statement"))
        ],
        required: ["table", "ddl"]
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
        let payload = try await services.connectionBridge.getTableDDL(scope: scope, table: table)
        return .structured(payload)
    }
}
