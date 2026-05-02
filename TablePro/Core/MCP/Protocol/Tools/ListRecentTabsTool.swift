import Foundation

public struct ListRecentTabsTool: MCPToolImplementation {
    public static let name = "list_recent_tabs"
    public static let description = String(
        localized: "List currently open tabs across all TablePro windows. Returns connection, tab type, table name, and titles for each tab."
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "List Recent Tabs"),
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    public static let inputSchema: JsonValue = .object([
        "type": .string("object"),
        "properties": .object([
            "limit": .object([
                "type": .string("integer"),
                "description": .string("Maximum number of tabs to return (default 20, max 500)")
            ])
        ]),
        "required": .array([])
    ])

    public init() {}

    public func call(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        let limit = MCPArgumentDecoder.optionalInt(arguments, key: "limit", default: 20, clamp: 1...500) ?? 20

        let snapshots = await MainActor.run { MCPTabSnapshotProvider.collectTabSnapshots() }
        let blocked = await MainActor.run { MCPTabSnapshotProvider.blockedExternalConnectionIds() }
        let filtered = snapshots.filter { !blocked.contains($0.connectionId) }
        let trimmed = Array(filtered.prefix(limit))

        let payload: [JsonValue] = trimmed.map { snapshot in
            var dict: [String: JsonValue] = [
                "connection_id": .string(snapshot.connectionId.uuidString),
                "connection_name": .string(snapshot.connectionName),
                "tab_id": .string(snapshot.tabId.uuidString),
                "tab_type": .string(snapshot.tabType),
                "display_title": .string(snapshot.displayTitle),
                "is_active": .bool(snapshot.isActive)
            ]
            if let table = snapshot.tableName {
                dict["table_name"] = .string(table)
            }
            if let database = snapshot.databaseName {
                dict["database_name"] = .string(database)
            }
            if let schema = snapshot.schemaName {
                dict["schema_name"] = .string(schema)
            }
            if let windowId = snapshot.windowId {
                dict["window_id"] = .string(windowId.uuidString)
            }
            return .object(dict)
        }

        return .structured(.object(["tabs": .array(payload)]))
    }
}
