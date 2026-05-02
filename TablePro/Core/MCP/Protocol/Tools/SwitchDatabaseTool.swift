import Foundation
import os

public struct SwitchDatabaseTool: MCPToolImplementation {
    public static let name = "switch_database"
    public static let description = String(localized: "Switch the active database on a connection")
    public static let inputSchema: JsonValue = .object([
        "type": .string("object"),
        "properties": .object([
            "connection_id": .object([
                "type": .string("string"),
                "description": .string(String(localized: "UUID of the connection"))
            ]),
            "database": .object([
                "type": .string("string"),
                "description": .string(String(localized: "Database name to switch to"))
            ])
        ]),
        "required": .array([.string("connection_id"), .string("database")])
    ])
    public static let requiredScopes: Set<MCPScope> = [.toolsWrite]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Switch Database"),
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Tools")

    public init() {}

    public func call(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        let database = try MCPArgumentDecoder.requireString(arguments, key: "database")
        Self.logger.debug("switch_database tool invoked for connection \(connectionId.uuidString, privacy: .public)")
        let payload = try await services.connectionBridge.switchDatabase(
            connectionId: connectionId,
            database: database
        )
        return .structured(payload)
    }
}
