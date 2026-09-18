import Foundation

public struct ListRecentTabsTool: MCPToolImplementation {
    public static let name = "list_recent_tabs"
    public static let title: String? = String(localized: "List Open Tabs")
    public static let description = String(
        localized: """
        List the tabs open in TablePro for connections this client may reach. Each entry carries the tab \
        id that focus_query_tab takes and the window id that open_table_tab returns.
        """
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "List Open Tabs"),
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.string(
                String(localized: "Restrict to one connection. Omit for every readable connection.")
            ),
            "limit": MCPToolSchema.integer(
                String(localized: "Maximum tabs to return (1-500, default 20)"),
                minimum: 1,
                maximum: 500
            )
        ]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "tabs": MCPToolSchema.array(
                String(localized: "Open tabs, ordered by connection then title"),
                of: MCPTabSnapshotProvider.tabSchema
            )
        ],
        required: ["tabs"]
    )

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: ["connection_id", "limit"])
        let connectionId = try MCPArgumentDecoder.optionalUuid(arguments, key: "connection_id")
        let limit = try MCPArgumentDecoder.optionalInt(arguments, key: "limit", range: 1...500) ?? 20

        var snapshots = await MCPTabSnapshotProvider.readableSnapshots(
            context: context,
            services: services
        )
        if let connectionId {
            try await MCPToolAuthorization.requireReadAccess(
                connectionId,
                context: context,
                services: services
            )
            snapshots = snapshots.filter { $0.connectionId == connectionId }
        }

        let payload = snapshots.prefix(limit).map(MCPTabSnapshotProvider.encode)
        return .structured(.object(["tabs": .array(Array(payload))]))
    }
}
