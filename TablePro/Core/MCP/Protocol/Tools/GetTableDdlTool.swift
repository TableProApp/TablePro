import Foundation

public struct GetTableDdlTool: MCPToolImplementation {
    public static let name = "get_table_ddl"
    public static let description = String(localized: "Get the CREATE TABLE DDL statement for a table")
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Get Table DDL"),
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

        let payload = try await services.connectionBridge.getTableDDL(
            connectionId: connectionId,
            table: table,
            schema: schema
        )
        return .structured(payload)
    }
}
