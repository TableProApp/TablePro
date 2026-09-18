import Foundation
import os

public struct ConnectTool: MCPToolImplementation {
    public static let name = "connect"
    public static let title: String? = String(localized: "Connect")
    public static let description = String(
        localized: "Open a session for a saved connection. Returns only after the driver is connected."
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsWrite]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Connect"),
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
            "status": MCPToolSchema.string(String(localized: "Always 'connected' on success")),
            "connection_id": MCPToolSchema.string(String(localized: "Connection UUID")),
            "current_database": MCPToolSchema.string(String(localized: "Database the session opened on")),
            "current_schema": MCPToolSchema.string(String(localized: "Schema the session opened on")),
            "server_version": MCPToolSchema.string(String(localized: "Server version string"))
        ],
        required: ["status", "connection_id", "current_database"]
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
        Self.logger.debug("connect invoked for \(connectionId.uuidString, privacy: .public)")
        let payload = try await services.connectionBridge.connect(connectionId: connectionId)
        return .structured(payload)
    }
}
