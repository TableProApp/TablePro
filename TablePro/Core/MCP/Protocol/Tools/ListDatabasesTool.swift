import Foundation

public struct ListDatabasesTool: MCPToolImplementation {
    public static let name = "list_databases"
    public static let description = String(localized: "List all databases on the server")
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]

    public static let inputSchema: JsonValue = .object([
        "type": .string("object"),
        "properties": .object([
            "connection_id": .object([
                "type": .string("string"),
                "description": .string("UUID of the connection")
            ])
        ]),
        "required": .array([.string("connection_id")])
    ])

    public init() {}

    public func call(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        let payload = try await services.connectionBridge.listDatabases(connectionId: connectionId)
        return .json(payload)
    }
}
