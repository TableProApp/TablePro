import Foundation

public struct ListConnectionsTool: MCPToolImplementation {
    public static let name = "list_connections"
    public static let description = String(localized: "List all saved database connections with their status")
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "List Connections"),
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    public static let inputSchema: JsonValue = .object([
        "type": .string("object"),
        "properties": .object([:]),
        "required": .array([])
    ])

    public init() {}

    public func call(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        let payload = await services.connectionBridge.listConnections()
        return .structured(payload)
    }
}
