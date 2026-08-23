import Foundation

public struct SwitchDatabaseTool: MCPToolImplementation {
    public static let name = "switch_database"
    public static let title: String? = String(localized: "Switch Database")
    public static let description = String(
        localized: """
        Move the connection's browse cursor to another database. This changes what the user sees in \
        TablePro. To run one statement elsewhere, pass 'database' to that tool instead.
        """
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsWrite]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Switch Database"),
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.connectionId,
            "database": MCPToolSchema.string(String(localized: "Database name to switch to"))
        ],
        required: ["connection_id", "database"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "status": MCPToolSchema.string(String(localized: "Always 'switched' on success")),
            "connection_id": MCPToolSchema.string(String(localized: "Connection UUID")),
            "current_database": MCPToolSchema.string(String(localized: "Database now selected"))
        ],
        required: ["status", "connection_id", "current_database"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: ["connection_id", "database"])
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        let database = try MCPArgumentDecoder.requireNonEmptyString(arguments, key: "database")
        let payload = try await services.connectionBridge.switchDatabase(
            connectionId: connectionId,
            database: database
        )
        return .structured(payload)
    }
}
