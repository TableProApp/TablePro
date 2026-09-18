import Foundation

public struct GetConnectionStatusTool: MCPToolImplementation {
    public static let name = "get_connection_status"
    public static let title: String? = String(localized: "Get Connection Status")
    public static let description = String(
        localized: "Report whether a connection is open, which database and schema it is on, and the server version."
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Get Connection Status"),
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
            "status": MCPToolSchema.string(
                String(localized: "Session status"),
                enumValues: ["connected", "connecting", "disconnected", "error"]
            ),
            "connection_id": MCPToolSchema.string(String(localized: "Connection UUID")),
            "current_database": MCPToolSchema.string(String(localized: "Database the session is on")),
            "current_schema": MCPToolSchema.string(String(localized: "Schema the session is on")),
            "server_version": MCPToolSchema.string(String(localized: "Server version string")),
            "connected_at": MCPToolSchema.string(String(localized: "ISO 8601 connect time")),
            "last_active_at": MCPToolSchema.string(String(localized: "ISO 8601 last activity time")),
            "error": MCPToolSchema.string(String(localized: "Redacted error text when the status is error"))
        ],
        required: ["status", "connection_id", "current_database"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: ["connection_id"])
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        let payload = try await services.connectionBridge.getConnectionStatus(connectionId: connectionId)
        return .structured(payload)
    }
}
