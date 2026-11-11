import Foundation
import TableProMCP

public struct ListRecentTabsTool: MCPToolImplementation {
    public static let name = "list_recent_tabs"
    public static let title: String? = String(localized: "List Open Tabs")
    public static let description = String(
        localized: """
        List the tabs open in TablePro. With connection_id, TablePro asks the user about that connection first. \
        Without it, the list covers only connections this client may already reach without asking. Each entry \
        carries the tab id that focus_query_tab takes and the window id that open_table_tab returns.
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
                String(localized: "Restrict to one connection. Omit for every connection already approved.")
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

    private let collectSnapshots: MCPTabSnapshotCollector

    public init() {
        self.init(collectSnapshots: MCPTabSnapshotProvider.liveSnapshots)
    }

    init(collectSnapshots: @escaping MCPTabSnapshotCollector) {
        self.collectSnapshots = collectSnapshots
    }

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: ["connection_id", "limit"])
        let connectionId = try MCPArgumentDecoder.optionalUuid(arguments, key: "connection_id")
        let limit = try MCPArgumentDecoder.optionalInt(arguments, key: "limit", range: 1...500) ?? 20

        let snapshots: [MCPTabSnapshot]
        if let connectionId {
            // ToolsCallHandler already asked about the named connection.
            try await MCPToolAuthorization.requireReadAccess(
                connectionId,
                context: context,
                services: services
            )
            snapshots = await MCPTabSnapshotProvider.readableSnapshots(
                context: context,
                services: services,
                collect: collectSnapshots
            ).filter { $0.connectionId == connectionId }
        } else {
            snapshots = await MCPTabSnapshotProvider.snapshotsReadableWithoutPrompt(
                context: context,
                services: services,
                collect: collectSnapshots
            )
        }

        let payload = snapshots.prefix(limit).map(MCPTabSnapshotProvider.encode)
        return .structured(.object(["tabs": .array(Array(payload))]))
    }
}
