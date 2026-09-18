import Foundation

public struct ListSchemasTool: MCPToolImplementation {
    public static let name = "list_schemas"
    public static let title: String? = String(localized: "List Schemas")
    public static let description = String(localized: "List the schemas inside one database, sorted by name.")
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "List Schemas"),
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.connectionId,
            "database": MCPToolSchema.database
        ],
        required: ["connection_id"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "schemas": MCPToolSchema.array(
                String(localized: "Schema names, sorted"),
                of: MCPToolSchema.stringItem
            ),
            "database": MCPToolSchema.string(String(localized: "Database the schemas belong to"))
        ],
        required: ["schemas", "database"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: ["connection_id", "database"])
        let scope = try await MCPScopeArguments.resolve(arguments, services: services)
        let payload = try await services.connectionBridge.listSchemas(scope: scope)
        return .structured(payload)
    }
}
