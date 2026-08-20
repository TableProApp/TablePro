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

        let scope = try await services.connectionBridge.resolveScope(
            connectionId: connectionId,
            database: database,
            schema: nil
        )
        let payload = try await services.connectionBridge.listSchemas(scope: scope)
        return .structured(payload)
    }
}
