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
        let legacy = try await services.connectionBridge.switchDatabase(
            connectionId: connectionId,
            database: database
        )
        return .json(JsonValue.fromLegacy(legacy))
    }
}
