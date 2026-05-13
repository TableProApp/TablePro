import Foundation
import os

public struct ConnectTool: MCPToolImplementation {
    public static let name = "connect"
    public static let description = String(localized: "Connect to a saved database")
    public static let inputSchema: JsonValue = .object([
        "type": .string("object"),
        "properties": .object([
            "connection_id": .object([
                "type": .string("string"),
                "description": .string(String(localized: "UUID of the saved connection"))
            ])
        ]),
        "required": .array([.string("connection_id")])
    ])
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Connect"),
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
        Self.logger.debug("connect tool invoked for connection \(connectionId.uuidString, privacy: .public)")
        let payload = try await services.connectionBridge.connect(connectionId: connectionId)
        return .structured(payload)
    }
}
