import Foundation

public struct DescribeTableTool: MCPToolImplementation {
    public static let name = "describe_table"
    public static let description = String(
        localized: "Get detailed table structure: columns, indexes, foreign keys, and DDL"
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Describe Table"),
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    public static let inputSchema: JsonValue = .object([
        "type": .string("object"),
        "properties": .object([
            "connection_id": .object([
                "type": .string("string"),
                "description": .string(String(localized: "UUID of the connection"))
            ]),
            "table": .object([
                "type": .string("string"),
                "description": .string(String(localized: "Table name"))
            ]),
            "schema": .object([
                "type": .string("string"),
                "description": .string(String(localized: "Schema name (uses current if omitted)"))
            ])
        ]),
        "required": .array([.string("connection_id"), .string("table")])
    ])

    public init() {}

    public func call(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        let table = try MCPArgumentDecoder.requireString(arguments, key: "table")
        let schema = MCPArgumentDecoder.optionalString(arguments, key: "schema")

        let payload = try await services.connectionBridge.describeTable(
            connectionId: connectionId,
            table: table,
            schema: schema
        )
        return .structured(payload)
    }
}
