import AppKit
import Foundation
import os

public struct OpenTableTabTool: MCPToolImplementation {
    public static let name = "open_table_tab"
    public static let title: String? = String(localized: "Open Table Tab")
    public static let description = String(
        localized: """
        Open a table in TablePro and bring it forward. Returns once the tab exists, with the same tab id \
        and window id that list_recent_tabs reports. Connects the connection if it is not open yet.
        """
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsWrite]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Open Table Tab"),
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: [
            "connection_id": MCPToolSchema.connectionId,
            "table_name": MCPToolSchema.string(String(localized: "Table to open")),
            "database_name": MCPToolSchema.database,
            "schema_name": MCPToolSchema.schema
        ],
        required: ["connection_id", "table_name"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "status": MCPToolSchema.string(String(localized: "Always 'opened' on success")),
            "connection_id": MCPToolSchema.string(String(localized: "Connection the tab belongs to")),
            "table_name": MCPToolSchema.string(String(localized: "Table that was opened")),
            "tab_id": MCPToolSchema.string(String(localized: "Tab id, accepted by focus_query_tab")),
            "window_id": MCPToolSchema.string(String(localized: "Window id, as reported by list_recent_tabs"))
        ],
        required: ["status", "connection_id", "table_name", "tab_id"]
    )

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Tools")

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(
            arguments,
            allowed: ["connection_id", "table_name", "database_name", "schema_name"]
        )
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        let tableName = try MCPArgumentDecoder.requireNonEmptyString(arguments, key: "table_name")
        let databaseName = try MCPArgumentDecoder.optionalString(arguments, key: "database_name")
        let schemaName = try MCPArgumentDecoder.optionalString(arguments, key: "schema_name")

        _ = try await ToolConnectionMetadata.resolve(connectionId: connectionId)
        Self.logger.debug("open_table_tab on \(connectionId.uuidString, privacy: .public)")

        await MainActor.run {
            let payload = EditorTabPayload(
                connectionId: connectionId,
                tabType: .table,
                tableName: tableName,
                databaseName: databaseName,
                schemaName: schemaName,
                intent: .openContent
            )
            WindowManager.shared.openTab(payload: payload, autoConnect: true)
            AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
        }

        guard let snapshot = await MCPTabSnapshotProvider.awaitTab(
            connectionId: connectionId,
            tableName: tableName
        ) else {
            throw MCPToolExecutionError.timedOut(
                String(localized: "TablePro did not open that table in time.")
            )
        }

        var fields: [String: JsonValue] = [
            "status": .string("opened"),
            "connection_id": .string(connectionId.uuidString),
            "table_name": .string(tableName),
            "tab_id": .string(snapshot.tabId.uuidString)
        ]
        if let windowId = snapshot.windowId {
            fields["window_id"] = .string(windowId.uuidString)
        }
        return .structured(.object(fields))
    }
}
