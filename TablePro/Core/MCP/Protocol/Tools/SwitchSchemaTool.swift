import Foundation

public struct SwitchSchemaTool: MCPToolImplementation {
    public static let name = "switch_schema"
    public static let title: String? = String(localized: "Switch Schema")
    public static let description = String(
        localized: "Move the connection's browse cursor to another schema. This changes what the user sees."
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsWrite]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Switch Schema"),
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.connectionId,
            "schema": MCPToolSchema.string(String(localized: "Schema name to switch to"))
        ],
        required: ["connection_id", "schema"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "status": MCPToolSchema.string(String(localized: "Always 'switched' on success")),
            "connection_id": MCPToolSchema.string(String(localized: "Connection UUID")),
            "current_schema": MCPToolSchema.string(String(localized: "Schema now selected"))
        ],
        required: ["status", "connection_id", "current_schema"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: ["connection_id", "schema"])
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        let schema = try MCPArgumentDecoder.requireNonEmptyString(arguments, key: "schema")
        let payload = try await services.connectionBridge.switchSchema(
            connectionId: connectionId,
            schema: schema
        )
        return .structured(payload)
    }
}
