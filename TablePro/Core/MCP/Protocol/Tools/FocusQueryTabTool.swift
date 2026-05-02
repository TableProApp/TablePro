import AppKit
import Foundation

public struct FocusQueryTabTool: MCPToolImplementation {
    public static let name = "focus_query_tab"
    public static let description = String(localized: "Focus an already-open tab by id (returned from list_recent_tabs).")
    public static let requiredScopes: Set<MCPScope> = [.toolsRead]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Focus Query Tab"),
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    public static let inputSchema: JsonValue = .object([
        "type": .string("object"),
        "properties": .object([
            "tab_id": .object([
                "type": .string("string"),
                "description": .string("UUID of the tab to focus")
            ])
        ]),
        "required": .array([.string("tab_id")])
    ])

    public init() {}

    public func call(
        arguments: JsonValue,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> MCPToolCallResult {
        let tabId = try MCPArgumentDecoder.requireUuid(arguments, key: "tab_id")

        let resolved: (windowId: UUID?, connectionId: UUID, raised: Bool)? = await MainActor.run {
            for snapshot in MCPTabSnapshotProvider.collectTabSnapshots() where snapshot.tabId == tabId {
                guard let window = snapshot.window else {
                    return (windowId: snapshot.windowId, connectionId: snapshot.connectionId, raised: false)
                }
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                return (windowId: snapshot.windowId, connectionId: snapshot.connectionId, raised: true)
            }
            return nil
        }

        guard let resolved else {
            throw MCPProtocolError.invalidParams(detail: "tab not found")
        }
        guard resolved.raised else {
            throw MCPProtocolError.invalidParams(detail: "tab not found")
        }

        var dict: [String: JsonValue] = [
            "status": .string("focused"),
            "tab_id": .string(tabId.uuidString),
            "connection_id": .string(resolved.connectionId.uuidString)
        ]
        if let windowId = resolved.windowId {
            dict["window_id"] = .string(windowId.uuidString)
        }

        return .structured(.object(dict))
    }
}
