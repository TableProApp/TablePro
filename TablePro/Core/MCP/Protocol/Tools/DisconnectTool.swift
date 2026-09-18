import Foundation
import os

public struct DisconnectTool: MCPToolImplementation {
    public static let name = "disconnect"
    public static let title: String? = String(localized: "Disconnect")
    public static let description = String(localized: "Close the open session for a connection.")
    public static let requiredScopes: Set<MCPScope> = [.toolsWrite]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Disconnect"),
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: ["connection_id": MCPToolSchema.connectionId],
        required: ["connection_id"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "status": MCPToolSchema.string(String(localized: "Always 'disconnected' on success")),
            "connection_id": MCPToolSchema.string(String(localized: "Connection UUID"))
        ],
        required: ["status", "connection_id"]
    )

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Tools")

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: ["connection_id"])
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        Self.logger.debug("disconnect invoked for \(connectionId.uuidString, privacy: .public)")
        let payload = try await services.connectionBridge.disconnect(connectionId: connectionId)
        return .structured(payload)
    }
}
