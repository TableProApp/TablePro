import Foundation

public struct ListConnectionsTool: MCPToolImplementation {
    public static let name = "list_connections"
    public static let title: String? = String(localized: "List Connections")
    public static let description = String(
        localized: """
        List the saved database connections this client may use, with their live status. \
        Connections the token cannot reach, or that the user blocked for external clients, are omitted.
        """
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "List Connections"),
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    public static let inputSchema = MCPToolSchema.empty

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "connections": MCPToolSchema.array(
                String(localized: "Connections the client may use, ordered by name"),
                of: MCPToolSchema.object(
                    properties: [
                        "id": MCPToolSchema.string(String(localized: "Connection UUID")),
                        "name": MCPToolSchema.string(String(localized: "Display name")),
                        "type": MCPToolSchema.string(String(localized: "Database engine")),
                        "host": MCPToolSchema.string(String(localized: "Server host")),
                        "port": MCPToolSchema.integer(String(localized: "Server port")),
                        "database": MCPToolSchema.string(String(localized: "Current database")),
                        "is_connected": MCPToolSchema.boolean(String(localized: "Whether a session is open")),
                        "ai_policy": MCPToolSchema.string(String(localized: "AI access policy")),
                        "external_access": MCPToolSchema.string(String(localized: "External client access level")),
                        "safe_mode": MCPToolSchema.string(String(localized: "Safe mode level"))
                    ],
                    required: ["id", "name", "type", "host", "port", "database", "is_connected"]
                )
            )
        ],
        required: ["connections"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: [])
        let payload = await services.connectionBridge.listConnections(principal: context.principal)
        return .structured(payload)
    }
}
