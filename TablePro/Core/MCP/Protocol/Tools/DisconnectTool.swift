import Foundation
import os

public struct DisconnectTool: MCPToolImplementation {
    public static let name = "disconnect"
    public static let description = String(localized: "Disconnect from a database")
    public static let inputSchema: JsonValue = .object([
        "type": .string("object"),
        "properties": .object([
            "connection_id": .object([
                "type": .string("string"),
                "description": .string(String(localized: "UUID of the connection to disconnect"))
            ])
        ]),
        "required": .array([.string("connection_id")])
    ])
    public static let requiredScopes: Set<MCPScope> = [.toolsWrite]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Disconnect"),
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true
    )

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Tools")

    public init() {}

    public func call(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        Self.logger.debug("disconnect tool invoked for connection \(connectionId.uuidString, privacy: .public)")
        try await services.connectionBridge.disconnect(connectionId: connectionId)
        let result: JsonValue = .object(["status": .string("disconnected")])
        return .structured(result)
    }
}
