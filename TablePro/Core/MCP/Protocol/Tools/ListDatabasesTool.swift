import Foundation

public struct ListDatabasesTool: MCPToolImplementation {
    public static let name = "list_databases"
    public static let title: String? = String(localized: "List Databases")
    public static let description = String(localized: "List the databases on the server, sorted by name.")
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "List Databases"),
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
            "databases": MCPToolSchema.array(
                String(localized: "Database names, sorted"),
                of: MCPToolSchema.stringItem
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
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: ["connection_id"])
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        let payload = try await services.connectionBridge.listDatabases(connectionId: connectionId)
        return .structured(payload)
    }
}
