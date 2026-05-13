import Foundation

public struct ListSchemasTool: MCPToolImplementation {
    public static let name = "list_schemas"
    public static let description = String(localized: "List schemas in a database")
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "List Schemas"),
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

        if let database {
            _ = try await services.connectionBridge.switchDatabase(connectionId: connectionId, database: database)
        }

        let payload = try await services.connectionBridge.listSchemas(connectionId: connectionId)
        return .structured(payload)
    }
}
