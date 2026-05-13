import Foundation

public struct ListTablesTool: MCPToolImplementation {
    public static let name = "list_tables"
    public static let description = String(localized: "List tables and views in a database")
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "List Tables"),
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    public static let inputSchema: JsonValue = .object([
        "type": .string("object"),
        "properties": .object([
            "connection_id": .object([
                "type": .string("string"),
                "description": .string(String(localized: "UUID of the connection"))
            ]),
            "database": .object([
                "type": .string("string"),
                "description": .string(String(localized: "Database name (uses current if omitted)"))
            ]),
            "schema": .object([
                "type": .string("string"),
                "description": .string(String(localized: "Schema name (uses current if omitted)"))
            ]),
            "include_row_counts": .object([
                "type": .string("boolean"),
                "description": .string(String(localized: "Include approximate row counts (default false)"))
            ])
        ]),
        "required": .array([.string("connection_id")])
    ])

    public init() {}

    public func call(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        let database = MCPArgumentDecoder.optionalString(arguments, key: "database")
        let schema = MCPArgumentDecoder.optionalString(arguments, key: "schema")
        let includeRowCounts = MCPArgumentDecoder.optionalBool(arguments, key: "include_row_counts", default: false)

        if let database {
            _ = try await services.connectionBridge.switchDatabase(connectionId: connectionId, database: database)
        }
        if let schema {
            _ = try await services.connectionBridge.switchSchema(connectionId: connectionId, schema: schema)
        }

        let payload = try await services.connectionBridge.listTables(
            connectionId: connectionId,
            includeRowCounts: includeRowCounts
        )
        return .structured(payload)
    }
}
