import Foundation
import os

public struct SwitchSchemaTool: MCPToolImplementation {
    public static let name = "switch_schema"
    public static let description = String(localized: "Switch the active schema on a connection")
    public static let inputSchema: JsonValue = .object([
        "type": .string("object"),
        "properties": .object([
            "connection_id": .object([
                "type": .string("string"),
                "description": .string(String(localized: "UUID of the connection"))
            ]),
            "schema": .object([
                "type": .string("string"),
                "description": .string(String(localized: "Schema name to switch to"))
            ])
        ]),
        "required": .array([.string("connection_id"), .string("schema")])
    ])
    public static let requiredScopes: Set<MCPScope> = [.toolsWrite]

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Tools")

    public init() {}

    public func call(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        let schema = try MCPArgumentDecoder.requireString(arguments, key: "schema")
        Self.logger.debug("switch_schema tool invoked for connection \(connectionId.uuidString, privacy: .public)")
        let payload = try await services.connectionBridge.switchSchema(
            connectionId: connectionId,
            schema: schema
        )
        return .json(payload)
    }
}
