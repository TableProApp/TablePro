import AppKit
import Foundation
import os

public struct OpenConnectionWindowTool: MCPToolImplementation {
    public static let name = "open_connection_window"
    public static let title: String? = String(localized: "Open Connection Window")
    public static let description = String(
        localized: """
        Open or focus a TablePro window for a saved connection. Returns once the window has a tab, with \
        the window id that list_recent_tabs reports.
        """
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsWrite]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Open Connection Window"),
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: ["connection_id": MCPToolSchema.connectionId],
        required: ["connection_id"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "status": MCPToolSchema.string(String(localized: "Always 'opened' on success")),
            "connection_id": MCPToolSchema.string(String(localized: "Connection the window shows")),
            "tab_id": MCPToolSchema.string(String(localized: "Tab that came forward")),
            "window_id": MCPToolSchema.string(String(localized: "Window id, as reported by list_recent_tabs")),
            "is_connected": MCPToolSchema.boolean(String(localized: "Whether the session is open"))
        ],
        required: ["status", "connection_id", "tab_id", "is_connected"]
    )

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Tools")

    public init() {}

    public func perform(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: ["connection_id"])
        let connectionId = try MCPArgumentDecoder.requireUuid(arguments, key: "connection_id")
        _ = try await ToolConnectionMetadata.resolve(connectionId: connectionId)
        Self.logger.debug("open_connection_window on \(connectionId.uuidString, privacy: .public)")

        await MainActor.run {
            let payload = EditorTabPayload(
                connectionId: connectionId,
                tabType: .query,
                intent: .restoreOrDefault
            )
            WindowManager.shared.openTab(payload: payload, autoConnect: true)
            NSApp.activate(ignoringOtherApps: true)
        }

        guard let snapshot = await MCPTabSnapshotProvider.awaitTab(
            connectionId: connectionId,
            tableName: nil
        ) else {
            throw MCPToolExecutionError.timedOut(
                String(localized: "TablePro did not open a window for that connection in time.")
            )
        }

        let isConnected = await MainActor.run {
            DatabaseManager.shared.activeSessions[connectionId]?.status.isConnected ?? false
        }

        var fields: [String: JsonValue] = [
            "status": .string("opened"),
            "connection_id": .string(connectionId.uuidString),
            "tab_id": .string(snapshot.tabId.uuidString),
            "is_connected": .bool(isConnected)
        ]
        if let windowId = snapshot.windowId {
            fields["window_id"] = .string(windowId.uuidString)
        }
        return .structured(.object(fields))
    }
}
