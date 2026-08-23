import Foundation

public struct ListTablesTool: MCPToolImplementation {
    public static let name = "list_tables"
    public static let title: String? = String(localized: "List Tables")
    public static let description = String(
        localized: """
        List the tables and views in one database and schema, sorted by schema then name. Row counts \
        are approximate and are fetched per table, so they are skipped when the schema holds more than 200 objects.
        """
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "List Tables"),
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.connectionId,
            "database": MCPToolSchema.database,
            "schema": MCPToolSchema.schema,
            "include_row_counts": MCPToolSchema.boolean(
                String(localized: "Fetch an approximate row count per table (default false)")
            )
        ],
        required: ["connection_id"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "tables": MCPToolSchema.array(
                String(localized: "Tables and views in scope"),
                of: MCPToolSchema.tableSummary
            ),
            "database": MCPToolSchema.string(String(localized: "Database the listing covers")),
            "schema": MCPToolSchema.nullableString(String(localized: "Schema the listing covers")),
            "row_counts_included": MCPToolSchema.boolean(String(localized: "Whether row counts were fetched")),
            "row_counts_are_approximate": MCPToolSchema.boolean(
                String(localized: "Row counts come from engine statistics, not COUNT(*)")
            )
        ],
        required: ["tables", "database", "row_counts_included"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(
            arguments,
            allowed: MCPScopeArguments.keys.union(["include_row_counts"])
        )
        let includeRowCounts = try MCPArgumentDecoder.optionalBool(
            arguments,
            key: "include_row_counts",
            default: false
        )
        let scope = try await MCPScopeArguments.resolve(arguments, services: services)
        let payload = try await services.connectionBridge.listTables(
            scope: scope,
            includeRowCounts: includeRowCounts
        )
        return .structured(payload)
    }
}
