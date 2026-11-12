import AppKit
import Foundation
import TableProMCP

public struct FocusQueryTabTool: MCPToolImplementation {
    public static let name = "focus_query_tab"
    public static let title: String? = String(localized: "Focus Tab")
    public static let description = String(
        localized: """
        Bring an open tab to the front, using a tab id from list_recent_tabs. TablePro asks the user about \
        the tab's connection first, as it does for any call that names a connection.
        """
    )
    public static let requiredScopes: Set<MCPScope> = [.toolsWrite]
    public static let annotations = MCPToolAnnotations(
        title: String(localized: "Focus Tab"),
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )

    public static let inputSchema = MCPToolSchema.object(
        properties: ["tab_id": MCPToolSchema.string(String(localized: "Tab id from list_recent_tabs"))],
        required: ["tab_id"]
    )

    public static let outputSchema: JsonValue? = MCPToolSchema.object(
        properties: [
            "status": MCPToolSchema.string(String(localized: "Always 'focused' on success")),
            "tab_id": MCPToolSchema.string(String(localized: "Tab that was raised")),
            "connection_id": MCPToolSchema.string(String(localized: "Connection the tab belongs to")),
            "window_id": MCPToolSchema.string(String(localized: "Window that came forward"))
        ],
        required: ["status", "tab_id", "connection_id"]
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
        try MCPArgumentDecoder.rejectUnknownKeys(arguments, allowed: ["tab_id"])
        let tabId = try MCPArgumentDecoder.requireUuid(arguments, key: "tab_id")

        let snapshots = await MCPTabSnapshotProvider.readableSnapshots(
            context: context,
            services: services,
            collect: collectSnapshots
        )
        guard let snapshot = snapshots.first(where: { $0.tabId == tabId }) else {
            throw MCPToolExecutionError.notFound(
                String(localized: "No open tab this client may reach has that id.")
            )
        }

        // The call names a tab, not a connection, so ToolsCallHandler had nothing to ask about.
        try await services.authPolicy.resolveAndAuthorize(
            principal: context.principal,
            tool: Self.name,
            connectionId: snapshot.connectionId
        )

        let raised = await MainActor.run { () -> Bool in
            guard Self.focus(tabId: tabId, among: WindowManager.shared.coordinators(for: snapshot.connectionId)) else {
                return false
            }
            AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
            return true
        }
        guard raised else {
            throw MCPToolExecutionError.notFound(
                String(localized: "That tab no longer has a window.")
            )
        }

        var fields: [String: JsonValue] = [
            "status": .string("focused"),
            "tab_id": .string(tabId.uuidString),
            "connection_id": .string(snapshot.connectionId.uuidString)
        ]
        if let windowId = snapshot.windowId {
            fields["window_id"] = .string(windowId.uuidString)
        }
        return .structured(.object(fields))
    }

    @MainActor
    static func focus(tabId: UUID, among coordinators: [MainContentCoordinator]) -> Bool {
        guard let owner = coordinators.first(where: { coordinator in
            coordinator.tabManager.tabs.contains { $0.id == tabId }
        }) else { return false }
        return owner.selectTabAndFocusWindow(tabId)
    }
}
